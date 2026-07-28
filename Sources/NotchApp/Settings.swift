import AppKit
import HerdrClient
import Observation

enum HotkeyModifier: String, CaseIterable, Identifiable {
    case controlOption, control, option, commandOption, commandControl, command
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .controlOption: "Control + Option"
        case .control: "Control"
        case .option: "Option"
        case .commandOption: "Command + Option"
        case .commandControl: "Command + Control"
        case .command: "Command"
        }
    }
    var symbols: String {
        switch self {
        case .controlOption: "⌃⌥"
        case .control: "⌃"
        case .option: "⌥"
        case .commandOption: "⌘⌥"
        case .commandControl: "⌘⌃"
        case .command: "⌘"
        }
    }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .controlOption: [.control, .option]
        case .control: .control
        case .option: .option
        case .commandOption: [.command, .option]
        case .commandControl: [.command, .control]
        case .command: .command
        }
    }
}

enum DisplayPlacement: String, CaseIterable, Identifiable {
    case notchDisplay
    case activeDisplay
    case terminalDisplay = "ghosttyDisplay"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notchDisplay: "Notch display"
        case .activeDisplay: "Active display"
        case .terminalDisplay: "Display with terminal"
        }
    }
}

enum PreferredTerminal: String, CaseIterable, Identifiable {
    case automatic
    case ghostty
    case terminal
    case iTerm2
    case kitty
    case wezTerm
    case alacritty
    case warp
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Auto-detect running terminal"
        case .ghostty: "Ghostty"
        case .terminal: "Terminal"
        case .iTerm2: "iTerm2"
        case .kitty: "kitty"
        case .wezTerm: "WezTerm"
        case .alacritty: "Alacritty"
        case .warp: "Warp"
        case .custom: "Custom application"
        }
    }
}

enum CompactIndicatorMode: String, CaseIterable, Identifiable {
    case revealOnHover
    case alwaysShow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .revealOnHover: "Reveal on hover"
        case .alwaysShow: "Always show"
        }
    }
}

@Observable @MainActor
final class Settings {
    private let defaults: UserDefaults
    var socketPathOverride: String? { didSet { defaults.set(socketPathOverride, forKey: Keys.socketPathOverride) } }
    var sessionName: String? { didSet { defaults.set(sessionName, forKey: Keys.sessionName) } }
    /// Remote herdr hosts to track alongside the local sessions, each reached
    /// through an SSH-forwarded socket.
    var remoteHosts: [RemoteHostConfiguration] {
        didSet { defaults.set(try? JSONEncoder().encode(remoteHosts), forKey: Keys.remoteHosts) }
    }
    var autoExpandOnDone: Bool { didSet { defaults.set(autoExpandOnDone, forKey: Keys.autoExpandOnDone) } }
    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) } }
    var soundPack: String { didSet { defaults.set(soundPack, forKey: Keys.soundPack) } }
    var respectDND: Bool { didSet { defaults.set(respectDND, forKey: Keys.respectDND) } }
    var hotkeyModifier: HotkeyModifier { didSet { defaults.set(hotkeyModifier.rawValue, forKey: Keys.hotkeyModifier) } }
    var displayPlacement: DisplayPlacement { didSet { defaults.set(displayPlacement.rawValue, forKey: Keys.displayPlacement) } }
    var preferredTerminal: PreferredTerminal { didSet { defaults.set(preferredTerminal.rawValue, forKey: Keys.preferredTerminal) } }
    var customTerminalAppName: String { didSet { defaults.set(customTerminalAppName, forKey: Keys.customTerminalAppName) } }
    var customTerminalBundleID: String { didSet { defaults.set(customTerminalBundleID, forKey: Keys.customTerminalBundleID) } }
    var compactIndicatorMode: CompactIndicatorMode { didSet { defaults.set(compactIndicatorMode.rawValue, forKey: Keys.compactIndicatorMode) } }
    var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin); LoginItem.setEnabled(launchAtLogin) } }
    var askForAccessibilityOnLaunch: Bool { didSet { defaults.set(askForAccessibilityOnLaunch, forKey: Keys.askForAccessibilityOnLaunch) } }
    var automaticUpdateChecks: Bool { didSet { defaults.set(automaticUpdateChecks, forKey: Keys.automaticUpdateChecks) } }
    var lastUpdateCheckAt: Date? { didSet { defaults.set(lastUpdateCheckAt, forKey: Keys.lastUpdateCheckAt) } }
    var skippedUpdateVersion: String? { didSet { defaults.set(skippedUpdateVersion, forKey: Keys.skippedUpdateVersion) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        socketPathOverride = defaults.string(forKey: Keys.socketPathOverride)
        sessionName = defaults.string(forKey: Keys.sessionName)
        remoteHosts = (defaults.data(forKey: Keys.remoteHosts)
            .flatMap { try? JSONDecoder().decode([RemoteHostConfiguration].self, from: $0) }) ?? []
        autoExpandOnDone = defaults.object(forKey: Keys.autoExpandOnDone) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        soundPack = defaults.string(forKey: Keys.soundPack) ?? "default"
        respectDND = defaults.object(forKey: Keys.respectDND) as? Bool ?? true
        hotkeyModifier = HotkeyModifier(rawValue: defaults.string(forKey: Keys.hotkeyModifier) ?? "") ?? .controlOption
        displayPlacement = DisplayPlacement(
            rawValue: defaults.string(forKey: Keys.displayPlacement) ?? "") ?? .notchDisplay
        preferredTerminal = PreferredTerminal(
            rawValue: defaults.string(forKey: Keys.preferredTerminal) ?? "") ?? .automatic
        customTerminalAppName = defaults.string(forKey: Keys.customTerminalAppName) ?? ""
        customTerminalBundleID = defaults.string(forKey: Keys.customTerminalBundleID) ?? ""
        compactIndicatorMode = CompactIndicatorMode(
            rawValue: defaults.string(forKey: Keys.compactIndicatorMode) ?? "") ?? .revealOnHover
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        askForAccessibilityOnLaunch =
            defaults.object(forKey: Keys.askForAccessibilityOnLaunch) as? Bool ?? true
        automaticUpdateChecks = defaults.object(forKey: Keys.automaticUpdateChecks) as? Bool ?? true
        lastUpdateCheckAt = defaults.object(forKey: Keys.lastUpdateCheckAt) as? Date
        skippedUpdateVersion = defaults.string(forKey: Keys.skippedUpdateVersion)
    }

    /// A socket to pin the notch to, or nil to discover and track every running
    /// session.
    ///
    /// The name-derived path is a fallback: `SessionDirectory` reports the
    /// authoritative `socket_path`, and notably the default session's socket is
    /// *not* under `sessions/`.
    func resolvedSocketPath() -> String? {
        resolvedSession()?.socketPath
    }

    /// A pinned session with its real identity. Keeping the name here prevents a
    /// named session from being presented later as the local default.
    func resolvedSession() -> ResolvedSession? {
        if let path = socketPathOverride, !path.isEmpty {
            let configuredName = sessionName.flatMap { $0.isEmpty ? nil : $0 }
            let name = path == SocketPath.defaultPath
                ? SessionDescriptor.defaultSessionName
                : configuredName ?? "custom"
            return ResolvedSession(local: SessionDescriptor(
                kind: .local(name: name),
                serverSocketPath: path,
                isDefault: name == SessionDescriptor.defaultSessionName))
        }
        if let sessionName, !sessionName.isEmpty {
            let path = SocketPath.forSession(sessionName)
            return ResolvedSession(local: SessionDescriptor(
                kind: .local(name: sessionName),
                serverSocketPath: path,
                isDefault: sessionName == SessionDescriptor.defaultSessionName))
        }
        return nil
    }

    var terminalSelection: TerminalActivator.Selection {
        switch preferredTerminal {
        case .automatic:
            .automatic()
        case .custom:
            .preferred(TerminalProfile(
                id: "custom",
                displayName: customTerminalAppName.isEmpty ? "Custom terminal" : customTerminalAppName,
                appName: customTerminalAppName,
                bundleIdentifiers: customTerminalBundleID.isEmpty ? [] : [customTerminalBundleID]))
        default:
            .preferred(terminalProfiles[0])
        }
    }

    var terminalProfiles: [TerminalProfile] {
        switch preferredTerminal {
        case .automatic: TerminalProfile.supported
        case .ghostty: [.ghostty]
        case .terminal: [.terminal]
        case .iTerm2: [.iTerm2]
        case .kitty: [.kitty]
        case .wezTerm: [.wezTerm]
        case .alacritty: [.alacritty]
        case .warp: [.warp]
        case .custom:
            [TerminalProfile(
                id: "custom",
                displayName: customTerminalAppName.isEmpty ? "Custom terminal" : customTerminalAppName,
                appName: customTerminalAppName,
                bundleIdentifiers: customTerminalBundleID.isEmpty ? [] : [customTerminalBundleID])]
        }
    }

    private enum Keys {
        static let socketPathOverride = "socketPathOverride"
        static let sessionName = "sessionName"
        static let remoteHosts = "remoteHosts"
        static let autoExpandOnDone = "autoExpandOnDone"
        static let soundEnabled = "soundEnabled"
        static let soundPack = "soundPack"
        static let respectDND = "respectDND"
        static let hotkeyModifier = "hotkeyModifier"
        static let displayPlacement = "displayPlacement"
        static let preferredTerminal = "preferredTerminal"
        static let customTerminalAppName = "customTerminalAppName"
        static let customTerminalBundleID = "customTerminalBundleID"
        static let compactIndicatorMode = "compactIndicatorMode"
        static let launchAtLogin = "launchAtLogin"
        static let askForAccessibilityOnLaunch = "askForAccessibilityOnLaunch"
        static let automaticUpdateChecks = "automaticUpdateChecks"
        static let lastUpdateCheckAt = "lastUpdateCheckAt"
        static let skippedUpdateVersion = "skippedUpdateVersion"
    }
}
