import Foundation
import Testing
@testable import NotchApp

/// Counts feed requests and hands back canned bytes, so nothing here touches
/// the network.
private final class FetchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URL] = []
    private let result: Result<Data, Error>

    init(_ result: Result<Data, Error>) { self.result = result }

    var requests: [URL] { lock.withLock { _requests } }
    var callCount: Int { requests.count }

    var fetch: UpdateChecker.Fetch {
        { [self] url in
            lock.withLock { _requests.append(url) }
            return try result.get()
        }
    }
}

private struct FeedUnreachable: Error {}

/// File scope so the injected `now` closure can capture it without crossing an
/// actor boundary.
private let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
@Suite("UpdateChecker")
struct UpdateCheckerTests {
    static func manifestJSON(version: String, minimum: String = "14.0") -> Data {
        Data("""
        {
          "schemaVersion": 1,
          "version": "\(version)",
          "publishedAt": "2026-07-24T12:00:00Z",
          "minimumSystemVersion": "\(minimum)",
          "downloadURL": "https://github.com/ykushch/notchagent/releases/download/v\(version)/NotchApp-\(version).zip",
          "sha256": "\(String(repeating: "a", count: 64))",
          "releaseNotesURL": "https://github.com/ykushch/notchagent/releases/tag/v\(version)"
        }
        """.utf8)
    }

    /// Fresh `UserDefaults` per test so persisted skips never leak between them.
    fileprivate static func makeSettings() -> (Settings, () -> Void) {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (Settings(defaults: defaults), { defaults.removePersistentDomain(forName: suiteName) })
    }

    fileprivate static func makeChecker(
        settings: Settings,
        recorder: FetchRecorder,
        currentVersion: String? = "1.2.0",
        origin: InstallOrigin = .manual,
        systemVersion: String = "14.6",
        environment: [String: String] = [:]
    ) -> UpdateChecker {
        UpdateChecker(
            settings: settings,
            currentVersion: currentVersion.flatMap(AppVersion.init),
            origin: origin,
            systemVersion: AppVersion(systemVersion)!,
            environment: environment,
            fetch: recorder.fetch,
            now: { checkedAt })
    }

    @Test("A newer version becomes an available update")
    func newerVersionIsAvailable() async {
        let (settings, cleanup) = Self.makeSettings()
        defer { cleanup() }
        let recorder = FetchRecorder(.success(Self.manifestJSON(version: "1.3.0")))
        let checker = Self.makeChecker(settings: settings, recorder: recorder)

        await checker.check(userInitiated: true)

        #expect(checker.pendingUpdate?.version == AppVersion("1.3.0")!)
        #expect(checker.advice?.primaryLinkActionTitle == "Download NotchApp-1.3.0.zip")
        #expect(settings.lastUpdateCheckAt == checkedAt)
        #expect(recorder.requests == [UpdateChecker.defaultFeedURL])
    }

    @Test("The same or an older version is not an update", arguments: ["1.2.0", "1.2", "1.1.9"])
    func notNewerIsUpToDate(version: String) async {
        let (settings, cleanup) = Self.makeSettings()
        defer { cleanup() }
        let recorder = FetchRecorder(.success(Self.manifestJSON(version: version)))
        let checker = Self.makeChecker(settings: settings, recorder: recorder)

        await checker.check(userInitiated: true)

        #expect(checker.state == .upToDate(checkedAt))
        #expect(checker.pendingUpdate == nil)
    }

    @Test("An update the running macOS cannot install is withheld")
    func minimumSystemVersionGate() async {
        let (settings, cleanup) = Self.makeSettings()
        defer { cleanup() }
        let recorder = FetchRecorder(.success(Self.manifestJSON(version: "1.3.0", minimum: "15.0")))
        let checker = Self.makeChecker(settings: settings, recorder: recorder, systemVersion: "14.6")

        await checker.check(userInitiated: true)

        #expect(checker.pendingUpdate == nil)
    }

    @Test("Skipping a version silences it, but not the one after it")
    func skippedVersions() async {
        let (settings, cleanup) = Self.makeSettings()
        defer { cleanup() }
        let recorder = FetchRecorder(.success(Self.manifestJSON(version: "1.3.0")))
        let checker = Self.makeChecker(settings: settings, recorder: recorder)

        await checker.check(userInitiated: true)
        checker.skipPendingUpdate()

        #expect(settings.skippedUpdateVersion == "1.3.0")
        #expect(checker.pendingUpdate == nil)

        // Re-checking the same version stays quiet…
        await checker.check(userInitiated: true)
        #expect(checker.pendingUpdate == nil)

        // …but a later release still surfaces.
        let later = FetchRecorder(.success(Self.manifestJSON(version: "1.4.0")))
        let nextChecker = Self.makeChecker(settings: settings, recorder: later)
        await nextChecker.check(userInitiated: true)
        #expect(nextChecker.pendingUpdate?.version == AppVersion("1.4.0")!)
    }

    @Test("An automatic failure stays silent and preserves what was on screen")
    func automaticFailureIsSilent() async {
        let (settings, cleanup) = Self.makeSettings()
        defer { cleanup() }
        let available = FetchRecorder(.success(Self.manifestJSON(version: "1.3.0")))
        let checker = Self.makeChecker(settings: settings, recorder: available)
        await checker.check(userInitiated: true)
        #expect(checker.pendingUpdate != nil)

        let failing = FetchRecorder(.failure(FeedUnreachable()))
        let offline = Self.makeChecker(settings: settings, recorder: failing)
        await offline.check(userInitiated: false)

        #expect(offline.state == .idle)
        #expect(offline.lastFailure != nil)
    }

    @Test("A check the user asked for reports its failure")
    func userInitiatedFailureIsReported() async {
        let (settings, cleanup) = Self.makeSettings()
        defer { cleanup() }
        let recorder = FetchRecorder(.failure(FeedUnreachable()))
        let checker = Self.makeChecker(settings: settings, recorder: recorder)

        await checker.check(userInitiated: true)

        guard case .failed = checker.state else {
            Issue.record("expected a reported failure, got \(checker.state)")
            return
        }
        #expect(settings.lastUpdateCheckAt == nil)
    }

    @Test("Unreadable feed bytes are a failure, never a fabricated update")
    func garbageFeed() async {
        let (settings, cleanup) = Self.makeSettings()
        defer { cleanup() }
        let recorder = FetchRecorder(.success(Data("<html>404</html>".utf8)))
        let checker = Self.makeChecker(settings: settings, recorder: recorder)

        await checker.check(userInitiated: true)

        #expect(checker.pendingUpdate == nil)
        #expect(checker.lastFailure == "Update feed could not be read.")
    }

    @Test("Development builds and unversioned bundles never reach the network")
    func unsupportedBuildsDoNotFetch() async {
        let (settings, cleanup) = Self.makeSettings()
        defer { cleanup() }

        let devRecorder = FetchRecorder(.success(Self.manifestJSON(version: "1.3.0")))
        let dev = Self.makeChecker(settings: settings, recorder: devRecorder, origin: .development)
        #expect(!dev.isSupported)
        await dev.check(userInitiated: true)
        #expect(devRecorder.callCount == 0)
        #expect(dev.state == .idle)

        let bareRecorder = FetchRecorder(.success(Self.manifestJSON(version: "1.3.0")))
        let bare = Self.makeChecker(settings: settings, recorder: bareRecorder, currentVersion: nil)
        #expect(!bare.isSupported)
        await bare.check(userInitiated: true)
        #expect(bareRecorder.callCount == 0)
    }

    @Test("An explicit feed override is a developer opt-in that lifts the dev suppression")
    func feedOverride() async {
        let (settings, cleanup) = Self.makeSettings()
        defer { cleanup() }
        let recorder = FetchRecorder(.success(Self.manifestJSON(version: "1.3.0")))
        let checker = Self.makeChecker(
            settings: settings,
            recorder: recorder,
            origin: .development,
            environment: [UpdateChecker.feedURLEnvironmentKey: "file:///tmp/appcast.json"])

        #expect(checker.isSupported)
        await checker.check(userInitiated: true)

        #expect(recorder.requests == [URL(string: "file:///tmp/appcast.json")!])
        #expect(checker.pendingUpdate?.version == AppVersion("1.3.0")!)
    }

    @Test("An oversized feed is rejected before decoding")
    func oversizedFeed() async {
        let (settings, cleanup) = Self.makeSettings()
        defer { cleanup() }
        let recorder = FetchRecorder(.success(
            Data(repeating: 0x20, count: UpdateChecker.maximumFeedBytes + 1)))
        let checker = Self.makeChecker(settings: settings, recorder: recorder)

        await checker.check(userInitiated: true)

        #expect(checker.pendingUpdate == nil)
        #expect(checker.lastFailure == "Update feed was unexpectedly large.")
    }
}
