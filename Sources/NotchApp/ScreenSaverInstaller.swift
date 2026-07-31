import AppKit
import Darwin
import Foundation
import Observation

enum ScreenSaverInstallationState: Equatable {
    case sourceUnavailable
    case notInstalled
    case installed
    case updateAvailable

    var statusText: String {
        switch self {
        case .sourceUnavailable: "Build required"
        case .notInstalled: "Not installed"
        case .installed: "Installed"
        case .updateAvailable: "Update available"
        }
    }

    var actionTitle: String {
        switch self {
        case .sourceUnavailable: "Install…"
        case .notInstalled: "Install…"
        case .installed: "Reinstall…"
        case .updateAvailable: "Update…"
        }
    }
}

/// Opens the generated `.saver` with macOS's standard installer. Selection is
/// intentionally left to System Settings because macOS has no public consumer
/// API for silently changing the active screen saver.
@MainActor
@Observable
final class ScreenSaverInstaller {
    private(set) var state: ScreenSaverInstallationState = .sourceUnavailable
    private(set) var message: String?

    @ObservationIgnored private let sourceURL: URL?
    @ObservationIgnored private let installedURL: URL
    @ObservationIgnored private let fileExists: (URL) -> Bool
    @ObservationIgnored private let bundleVersion: (URL) -> String?
    @ObservationIgnored private let openURL: (URL) -> Bool
    @ObservationIgnored private let reloadHosts: @MainActor () -> Int
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        sourceURL: URL? = ScreenSaverInstaller.locateSourceSaver(),
        installedURL: URL = ScreenSaverInstaller.defaultInstalledURL(),
        fileExists: @escaping (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        },
        bundleVersion: @escaping (URL) -> String? = ScreenSaverInstaller.readBundleVersion,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        reloadHosts: @escaping @MainActor () -> Int = ScreenSaverInstaller.reloadLegacyHosts
    ) {
        self.sourceURL = sourceURL
        self.installedURL = installedURL
        self.fileExists = fileExists
        self.bundleVersion = bundleVersion
        self.openURL = openURL
        self.reloadHosts = reloadHosts
        refresh()
    }

    func refresh() {
        state = Self.resolveState(
            sourceExists: sourceURL.map(fileExists) ?? false,
            installedExists: fileExists(installedURL),
            sourceVersion: sourceURL.flatMap(bundleVersion),
            installedVersion: bundleVersion(installedURL))
    }

    func install() {
        guard let sourceURL, fileExists(sourceURL) else {
            message = "Build NotchAgent.app (or run scripts/build-screensaver.sh) first."
            refresh()
            return
        }
        guard openURL(sourceURL) else {
            message = "macOS could not open the screen-saver installer."
            return
        }
        message = "Approve the macOS installation prompt, then click Reload Installed Saver so macOS uses the new build."
        beginRefreshPolling()
    }

    var canReloadInstalledSaver: Bool {
        state == .installed || state == .updateAvailable
    }

    func reloadInstalledSaver() {
        refresh()
        guard canReloadInstalledSaver else {
            message = "Finish installing the latest saver before reloading it."
            return
        }
        let count = reloadHosts()
        message = count == 0
            ? "No cached saver host was running. macOS will load the installed build next time."
            : "Reloaded the installed saver. macOS will start a fresh host when it is previewed or activated."
    }

    func openSystemSettings() {
        let wallpaperSettings = URL(
            string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!
        let didOpen = openURL(wallpaperSettings)
            || openURL(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        if !didOpen {
            message = "Open System Settings → Wallpaper → Screen Saver."
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    static func resolveState(
        sourceExists: Bool,
        installedExists: Bool,
        sourceVersion: String?,
        installedVersion: String?
    ) -> ScreenSaverInstallationState {
        guard sourceExists else { return .sourceUnavailable }
        guard installedExists else { return .notInstalled }
        if let sourceVersion, let installedVersion,
           sourceVersion != installedVersion {
            return .updateAvailable
        }
        return .installed
    }

    /// Reads Info.plist directly so an app that stays running across a saver
    /// reinstall does not reuse Foundation's cached Bundle metadata.
    nonisolated static func readBundleVersion(at saverURL: URL) -> String? {
        let infoURL = saverURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let object = try? PropertyListSerialization.propertyList(
                from: data, format: nil),
              let info = object as? [String: Any] else {
            return nil
        }
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        let components = [version, build].compactMap { $0 }
        return components.isEmpty ? nil : components.joined(separator: "+")
    }

    static func shouldContinueInstallPolling(
        state: ScreenSaverInstallationState
    ) -> Bool {
        state != .installed
    }

    static func defaultInstalledURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers", isDirectory: true)
            .appendingPathComponent("NotchAgent.saver", isDirectory: true)
    }

    static func locateSourceSaver(
        bundle: Bundle = .main,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [
            bundle.resourceURL?.appendingPathComponent(
                "NotchAgent.saver", isDirectory: true),
            currentDirectoryURL.appendingPathComponent(
                "build/NotchAgent.saver", isDirectory: true),
        ].compactMap { $0 }
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func reloadLegacyHosts() -> Int {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.ScreenSaver.Engine.legacyScreenSaver"
        ).reduce(into: 0) { count, application in
            if Darwin.kill(application.processIdentifier, SIGTERM) == 0 {
                count += 1
            }
        }
    }

    private func beginRefreshPolling() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            for _ in 0..<12 {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                refresh()
                if !Self.shouldContinueInstallPolling(state: state) { return }
            }
        }
    }
}
