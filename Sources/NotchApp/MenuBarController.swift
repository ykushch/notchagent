import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let settings: Settings
    private let updates: UpdateChecker
    private let onSessionChange: () -> Void
    private let onRemoteHostsChange: () -> Void
    private let onToggleNotch: () -> Void
    /// Live session state, so Settings can show what each session is doing.
    private weak var registry: SessionRegistry?

    init(
        settings: Settings,
        updates: UpdateChecker,
        registry: SessionRegistry?,
        onSessionChange: @escaping () -> Void,
        onRemoteHostsChange: @escaping () -> Void,
        onToggleNotch: @escaping () -> Void
    ) {
        self.settings = settings
        self.updates = updates
        self.registry = registry
        self.onSessionChange = onSessionChange
        self.onRemoteHostsChange = onRemoteHostsChange
        self.onToggleNotch = onToggleNotch
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        rebuild(menu)
        item.menu = menu
        statusItem = item
        refreshIcon()
        observeUpdateState()
    }

    func remove() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    // MARK: - Menu contents

    /// Rebuilt on every open (see `menuNeedsUpdate`) because the update items
    /// come and go with the checker's state.
    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        if let advice = updates.advice {
            let headline = NSMenuItem(title: advice.headline, action: nil, keyEquivalent: "")
            headline.isEnabled = false
            headline.toolTip = advice.accessibilityReminder
            menu.addItem(headline)

            if let command = advice.command, let title = advice.commandActionTitle {
                let copy = NSMenuItem(title: title, action: #selector(copyUpgradeCommand), keyEquivalent: "")
                copy.target = self
                copy.toolTip = command
                menu.addItem(copy)
            }
            let primary = NSMenuItem(
                title: advice.primaryLinkActionTitle,
                action: #selector(openPrimaryUpdateLink),
                keyEquivalent: "")
            primary.target = self
            menu.addItem(primary)

            if advice.primaryLink != advice.releaseNotesURL {
                let notes = NSMenuItem(title: "Release Notes…", action: #selector(openReleaseNotes), keyEquivalent: "")
                notes.target = self
                menu.addItem(notes)
            }

            let skip = NSMenuItem(title: "Skip This Version", action: #selector(skipUpdate), keyEquivalent: "")
            skip.target = self
            menu.addItem(skip)
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: "Show / Hide Notch", action: #selector(toggleNotch), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self; menu.addItem(settingsItem)
        let accessibility = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: "")
        accessibility.target = self; menu.addItem(accessibility)
        menu.addItem(.separator())

        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        check.isEnabled = updates.isSupported && updates.state != .checking
        menu.addItem(check)
        let status = NSMenuItem(title: updates.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let provenance = NSMenuItem(title: Self.buildProvenanceTitle(), action: nil, keyEquivalent: "")
        provenance.isEnabled = false
        provenance.toolTip = Self.buildSourcePath()
        menu.addItem(provenance)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Notch Agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Re-arms itself after each change, the standard `withObservationTracking`
    /// pattern: one notification per change, so the icon badge follows state.
    private func observeUpdateState() {
        withObservationTracking { [weak self] in
            _ = self?.updates.pendingUpdate
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshIcon()
                self.observeUpdateState()
            }
        }
    }

    private func refreshIcon() {
        statusItem?.button?.image = MenuBarIcon.image(showsUpdateBadge: updates.pendingUpdate != nil)
    }

    // MARK: - Actions

    @objc private func toggleNotch() { onToggleNotch() }

    @objc private func checkForUpdates() { updates.checkNow() }

    @objc private func skipUpdate() { updates.skipPendingUpdate() }

    @objc private func copyUpgradeCommand() {
        guard let command = updates.advice?.command else { return }
        UpdateActions.copy(command)
    }

    @objc private func openPrimaryUpdateLink() {
        guard let link = updates.advice?.primaryLink else { return }
        UpdateActions.open(link)
    }

    @objc private func openReleaseNotes() {
        guard let url = updates.advice?.releaseNotesURL else { return }
        UpdateActions.open(url)
    }

    @objc private func openAccessibility() {
        HotkeyMonitor.promptForAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSettings() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = SettingsView(
            settings: settings,
            updates: updates,
            onSessionChange: onSessionChange,
            onRemoteHostsChange: onRemoteHostsChange,
            availableSessions: registry?.runtimes
                .filter { !$0.descriptor.isRemote && !$0.descriptor.isDefault }
                .map(\.descriptor.kind.name)
                .sorted() ?? [],
            registry: registry)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Notch Agent Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private static func buildProvenanceTitle(bundle: Bundle = .main) -> String {
        let revision = bundle.object(forInfoDictionaryKey: "NotchAgentGitRevision") as? String
            ?? "development"
        let dirty = bundle.object(forInfoDictionaryKey: "NotchAgentGitDirty") as? Bool
            ?? false
        let version = AppVersion.current(bundle: bundle).map { "\($0) · " } ?? ""
        return "\(version)Build \(revision)\(dirty ? "-dirty" : "")"
    }

    private static func buildSourcePath(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "NotchAgentSourcePath") as? String
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }
}
