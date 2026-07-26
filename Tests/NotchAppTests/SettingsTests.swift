import Foundation
import HerdrClient
import Testing
@testable import NotchApp

@MainActor
@Suite("Settings")
struct SettingsTests {
    @Test("Compact indicator defaults to reveal on hover and persists")
    func compactIndicatorPersistence() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = Settings(defaults: defaults)
        #expect(initial.compactIndicatorMode == .revealOnHover)

        initial.compactIndicatorMode = .alwaysShow
        #expect(Settings(defaults: defaults).compactIndicatorMode == .alwaysShow)
    }

    @Test("Unknown compact indicator values fall back safely")
    func unknownCompactIndicator() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("future-mode", forKey: "compactIndicatorMode")

        #expect(Settings(defaults: defaults).compactIndicatorMode == .revealOnHover)
    }

    @Test("Preferred terminal defaults to automatic and persists")
    func preferredTerminalPersistence() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = Settings(defaults: defaults)
        #expect(initial.preferredTerminal == .automatic)

        initial.preferredTerminal = .iTerm2
        #expect(Settings(defaults: defaults).preferredTerminal == .iTerm2)
    }

    @Test("Custom terminal produces a preferred activation profile")
    func customTerminalProfile() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        settings.preferredTerminal = .custom
        settings.customTerminalAppName = "My Terminal"
        settings.customTerminalBundleID = "dev.example.terminal"

        #expect(settings.terminalProfiles == [TerminalProfile(
            id: "custom",
            displayName: "My Terminal",
            appName: "My Terminal",
            bundleIdentifiers: ["dev.example.terminal"])])
    }

    @Test("Remote hosts default to empty and round-trip through defaults")
    func remoteHostPersistence() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = Settings(defaults: defaults)
        #expect(initial.remoteHosts.isEmpty)

        initial.remoteHosts = [
            RemoteHostConfiguration(target: "workbox"),
            RemoteHostConfiguration(target: "buildbox", sessionName: "agents"),
        ]
        let reloaded = Settings(defaults: defaults)
        #expect(reloaded.remoteHosts.map(\.id) == ["workbox", "buildbox/agents"])
        #expect(reloaded.remoteHosts.first?.sessionName == nil)
    }

    @Test("Corrupt remote host data falls back to empty instead of crashing")
    func corruptRemoteHostData() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not json".utf8), forKey: "remoteHosts")

        #expect(Settings(defaults: defaults).remoteHosts.isEmpty)
    }

    @Test("No pin means track every session; a pin still resolves to a socket")
    func resolvedSocketPathPinning() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        // nil is what enables multi-session discovery.
        #expect(settings.resolvedSocketPath() == nil)

        settings.sessionName = "work"
        #expect(settings.resolvedSocketPath() == SocketPath.forSession("work"))
        #expect(settings.resolvedSession()?.descriptor.kind.name == "work")
        #expect(settings.resolvedSession()?.descriptor.attachCommand == "herdr --session work")

        // The regression that motivated the fix: the default session's socket is
        // NOT under sessions/, so a name-derived path was wrong for it.
        settings.sessionName = "default"
        #expect(settings.resolvedSocketPath() == SocketPath.defaultPath)
        #expect(settings.resolvedSocketPath()?.contains("/sessions/") == false)

        settings.socketPathOverride = "/tmp/explicit.sock"
        #expect(settings.resolvedSocketPath() == "/tmp/explicit.sock")
    }

    @Test("Legacy Ghostty display setting maps to preferred terminal display")
    func legacyGhosttyDisplaySetting() {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("ghosttyDisplay", forKey: "displayPlacement")

        #expect(Settings(defaults: defaults).displayPlacement == .terminalDisplay)
    }
}
