import AppKit
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
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        sourceURL: URL? = ScreenSaverInstaller.locateSourceSaver(),
        installedURL: URL = ScreenSaverInstaller.defaultInstalledURL(),
        fileExists: @escaping (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        },
        bundleVersion: @escaping (URL) -> String? = {
            let bundle = Bundle(url: $0)
            let version = bundle?.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let build = bundle?.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String
            let components = [version, build].compactMap { $0 }
            return components.isEmpty ? nil : components.joined(separator: "+")
        },
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.sourceURL = sourceURL
        self.installedURL = installedURL
        self.fileExists = fileExists
        self.bundleVersion = bundleVersion
        self.openURL = openURL
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
        message = "Approve the macOS installation prompt, then choose Notch Agent in Screen Saver settings."
        beginRefreshPolling()
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
                if state == .installed || state == .updateAvailable { return }
            }
        }
    }
}
