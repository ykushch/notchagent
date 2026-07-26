import Foundation
import Observation

enum UpdateState: Sendable, Equatable {
    case idle
    case checking
    case upToDate(Date)
    case available(UpdateManifest)
    /// Only ever set by a check the user asked for. Automatic checks that fail
    /// record `lastFailure` and stay quiet.
    case failed(String)
}

/// Polls the published `appcast.json` and reports whether a newer release
/// exists. It never downloads or installs anything — releases are ad-hoc
/// signed, so replacing the bundle would drop the Accessibility grant the app
/// needs for hotkeys and agent actions. The user is told what to run instead.
@Observable
@MainActor
final class UpdateChecker {
    typealias Fetch = @Sendable (URL) async throws -> Data

    static let defaultFeedURL = URL(
        string: "https://github.com/ykushch/notchagent/releases/latest/download/appcast.json")!
    static let feedURLEnvironmentKey = "NOTCHAGENT_APPCAST_URL"
    static let checkInterval: Duration = .seconds(24 * 60 * 60)
    static let launchDelay: Duration = .seconds(10)
    /// The manifest is a few hundred bytes; anything larger is not our feed.
    static let maximumFeedBytes = 64 * 1024

    private(set) var state: UpdateState = .idle
    private(set) var lastFailure: String?

    private let settings: Settings
    private let currentVersion: AppVersion?
    private let origin: InstallOrigin
    private let systemVersion: AppVersion
    private let feedURL: URL
    /// An explicit `NOTCHAGENT_APPCAST_URL` is a developer opt-in, so it also
    /// lifts the development-build suppression — otherwise the documented way
    /// to exercise this flow locally would never fire.
    private let feedOverridden: Bool
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var loop: Task<Void, Never>?

    init(
        settings: Settings,
        currentVersion: AppVersion? = AppVersion.current(),
        origin: InstallOrigin = .resolve(),
        systemVersion: AppVersion = .currentSystem(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fetch: Fetch? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settings = settings
        self.currentVersion = currentVersion
        self.origin = origin
        self.systemVersion = systemVersion
        let override = environment[Self.feedURLEnvironmentKey]
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
        feedURL = override ?? Self.defaultFeedURL
        feedOverridden = override != nil
        self.fetch = fetch ?? Self.networkFetch()
        self.now = now
    }

    // MARK: - Derived state

    var pendingUpdate: UpdateManifest? {
        guard case .available(let manifest) = state else { return nil }
        return manifest
    }

    var advice: UpdateAdvice.Guidance? {
        pendingUpdate.map {
            UpdateAdvice.guidance(for: origin, manifest: $0, currentVersion: currentVersion)
        }
    }

    /// A development build has nothing to be behind, and an unversioned bundle
    /// has nothing to compare against.
    var isSupported: Bool {
        currentVersion != nil && (origin != .development || feedOverridden)
    }

    var currentVersionText: String { currentVersion.map(\.rawValue) ?? "development build" }

    /// One shared line of status text, so the menu and Settings never disagree.
    var statusText: String {
        guard isSupported else { return "Update checks are off for development builds." }
        switch state {
        case .idle:
            return settings.lastUpdateCheckAt.map { "Last checked \(Self.relative($0))" }
                ?? "Not checked yet"
        case .checking:
            return "Checking…"
        case .upToDate(let date):
            return "Up to date · checked \(Self.relative(date))"
        case .available(let manifest):
            return "Version \(manifest.version) is available"
        case .failed(let message):
            return message
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Lifecycle

    func start() {
        guard loop == nil, isSupported else { return }
        loop = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.launchDelay) } catch { return }
            while !Task.isCancelled {
                guard let self else { return }
                if self.settings.automaticUpdateChecks {
                    await self.check(userInitiated: false)
                }
                do { try await Task.sleep(for: Self.checkInterval) } catch { return }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: - Actions

    /// The menu's "Check for Updates…" — runs even when automatic checks are
    /// off, and reports failures instead of swallowing them.
    func checkNow() {
        Task { @MainActor [weak self] in await self?.check(userInitiated: true) }
    }

    /// Dismissing the notice means "don't tell me about this one again". A
    /// later, higher version still surfaces.
    func skipPendingUpdate() {
        guard let manifest = pendingUpdate else { return }
        settings.skippedUpdateVersion = manifest.version.rawValue
        state = .upToDate(now())
    }

    // MARK: - Checking

    func check(userInitiated: Bool) async {
        guard isSupported else { return }
        let previous = state
        state = .checking
        do {
            let data = try await fetch(feedURL)
            guard data.count <= Self.maximumFeedBytes else { throw FeedError.tooLarge }
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            settings.lastUpdateCheckAt = now()
            lastFailure = nil
            state = evaluate(manifest)
        } catch {
            let message = Self.describe(error)
            lastFailure = message
            // An automatic check that fails is a non-event: the user did not
            // ask, so restore what was on screen rather than raising an alarm.
            state = userInitiated ? .failed(message) : previous
        }
    }

    private func evaluate(_ manifest: UpdateManifest) -> UpdateState {
        let checkedAt = now()
        guard let currentVersion, manifest.version > currentVersion else {
            return .upToDate(checkedAt)
        }
        if let minimum = manifest.minimumSystemVersion, minimum > systemVersion {
            return .upToDate(checkedAt)
        }
        if let skipped = settings.skippedUpdateVersion.flatMap(AppVersion.init),
           manifest.version <= skipped {
            return .upToDate(checkedAt)
        }
        return .available(manifest)
    }

    // MARK: - Transport

    enum FeedError: Error, Equatable {
        case badStatus(Int)
        case tooLarge
        case notHTTP
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case FeedError.badStatus(let code): "Update feed returned HTTP \(code)."
        case FeedError.tooLarge: "Update feed was unexpectedly large."
        case FeedError.notHTTP: "Update feed returned an unexpected response."
        case is DecodingError, is UpdateManifest.ValidationError: "Update feed could not be read."
        default: (error as NSError).localizedDescription
        }
    }

    /// One unauthenticated GET to GitHub. No query parameters, no identifiers,
    /// no cookies, ephemeral storage — nothing about the user leaves the
    /// machine beyond the request itself.
    static func networkFetch() -> Fetch {
        { url in
            if url.isFileURL { return try Data(contentsOf: url) }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil

            let session = URLSession(
                configuration: configuration,
                delegate: GitHubRedirectGuard(),
                delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FeedError.notHTTP }
            guard http.statusCode == 200 else { throw FeedError.badStatus(http.statusCode) }
            return data
        }
    }
}

/// `releases/latest/download/…` redirects to GitHub's asset host. Following it
/// is expected; following it somewhere else is not, so anything off the
/// allowlist stops the chain rather than being fetched.
private final class GitHubRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let host = request.url?.host?.lowercased(),
              request.url?.scheme?.lowercased() == "https",
              UpdateManifest.allowedHosts.contains(host)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
