import HerdrClient
import ScreenSaveKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: Settings
    @Bindable var model: NotchViewModel
    @Bindable var updates: UpdateChecker
    let onSessionChange: () -> Void
    let onRemoteHostsChange: () -> Void
    let onPreviewScreenSave: () -> Void
    let screenSaverAutomation: SystemScreenSaverAutomation
    let screenSaverHotKeyRegistrar: ScreenSaverHotKeyRegistrar
    let availableSessions: [String]
    /// Live registry, so each row can show what the session is actually doing
    /// rather than just what was configured.
    let registry: SessionRegistry?

    @State private var newRemoteTarget = ""
    @State private var newRemoteSession = ""
    @State private var discoveredSessions: [String]?
    @State private var screenSaverInstaller = ScreenSaverInstaller()

    var body: some View {
        Form {
            SessionsSection(
                settings: settings,
                registry: registry,
                onSessionChange: onSessionChange,
                onRemoteHostsChange: onRemoteHostsChange,
                availableSessions: discoveredSessions ?? availableSessions,
                newRemoteTarget: $newRemoteTarget,
                newRemoteSession: $newRemoteSession)

            Section("Behavior") {
                Toggle("Auto-expand when done", isOn: $settings.autoExpandOnDone)
                Toggle("Enable sounds", isOn: $settings.soundEnabled)
                Toggle("Respect Do Not Disturb", isOn: $settings.respectDND)
                Picker("Compact indicator", selection: $settings.compactIndicatorMode) {
                    ForEach(CompactIndicatorMode.allCases) { Text($0.displayName).tag($0) }
                }
                Text("Reveal on hover keeps a minimal status line visible until you point at it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Display & keyboard") {
                Picker("Pill display", selection: $settings.displayPlacement) {
                    ForEach(DisplayPlacement.allCases) { Text($0.displayName).tag($0) }
                }
                Text(displayPlacementHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Enable agent global shortcuts", isOn: $settings.agentGlobalHotkeysEnabled)
                if settings.agentGlobalHotkeysEnabled {
                    Picker("Agent shortcut modifier", selection: $settings.hotkeyModifier) {
                        ForEach(HotkeyModifier.allCases) {
                            Text("\($0.displayName) (\($0.symbols))").tag($0)
                        }
                    }
                }
                Text("Screen-saver shortcut registration is independent of agent shortcuts and Accessibility access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScreenSaverSettingsSection(
                settings: settings,
                installer: screenSaverInstaller,
                screenSaverAutomation: screenSaverAutomation,
                screenSaverHotKeyRegistrar: screenSaverHotKeyRegistrar,
                onPreview: onPreviewScreenSave)

            Section("Jump") {
                Picker("Terminal app", selection: $settings.preferredTerminal) {
                    ForEach(PreferredTerminal.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.preferredTerminal == .custom {
                    TextField("Application name", text: $settings.customTerminalAppName)
                    TextField("Bundle identifier (optional)", text: $settings.customTerminalBundleID)
                }
                Text("Auto-detect uses a running terminal only when the choice is unambiguous.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                if settings.agentGlobalHotkeysEnabled {
                    Toggle(
                        "Ask for Accessibility access at launch",
                        isOn: $settings.askForAccessibilityOnLaunch)
                    HStack {
                        LabeledContent(
                            "Agent shortcut access",
                            value: model.accessibilityMissing ? "Accessibility needed" : "Ready")
                        Spacer()
                        if model.accessibilityMissing {
                            Button("Open Accessibility Settings…", action: openAccessibilitySettings)
                        }
                    }
                    Text("Accessibility is used only for optional agent approve, deny, navigation, and reply shortcuts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Agent global shortcuts are off. The screen-saver shortcut remains available without Accessibility access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                LabeledContent("Version", value: updates.currentVersionText)
                Toggle("Check for updates automatically", isOn: $settings.automaticUpdateChecks)
                HStack {
                    Text(updates.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now", action: updates.checkNow)
                        .disabled(!updates.isSupported || updates.state == .checking)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 500, height: 800)
        .task {
            screenSaverInstaller.refresh()
            // Present Settings immediately, then ask the CLI off the main actor.
            // A failed lookup leaves the cached registry-derived list in place.
            if let sessions = await Self.discoverLocalSessionNames() {
                discoveredSessions = sessions
            }
        }
    }

    private nonisolated static func discoverLocalSessionNames() async -> [String]? {
        await Task.detached(priority: .utility) {
            guard let sessions = try? SessionDirectory().localSessions() else { return nil }
            return sessions.filter { !$0.isDefault && $0.isRunning }
                .map(\.kind.name)
                .sorted()
        }.value
    }

    private func openAccessibilitySettings() {
        HotkeyMonitor.promptForAccessibility()
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private var displayPlacementHelp: String {
        switch settings.displayPlacement {
        case .notchDisplay:
            "Uses the built-in notch when available. On non-notch Macs, the pill floats at the top center."
        case .activeDisplay:
            "Follows the display with keyboard focus. Display changes settle for a moment before the pill moves."
        case .terminalDisplay:
            "Uses the display containing the preferred terminal, falling back to the active display."
        }
    }
}

private struct ScreenSaverSettingsSection: View {
    @Bindable var settings: Settings
    @Bindable var installer: ScreenSaverInstaller
    @Bindable var screenSaverAutomation: SystemScreenSaverAutomation
    @Bindable var screenSaverHotKeyRegistrar: ScreenSaverHotKeyRegistrar
    let onPreview: () -> Void
    @State private var isRecordingShortcut = false
    @State private var shortcutMessage: String?

    var body: some View {
        Section("Screen Saver") {
            LabeledContent("Notch Agent", value: installer.state.statusText)
            Picker("Style", selection: $settings.screenSaveStyle) {
                ForEach(ScreenSaveStyleID.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            if settings.screenSaveStyle == .currentWallpaper {
                Text("Uses a privacy-safe cached still of the current wallpaper on each display. Apple’s animated wallpaper motion is not reproduced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Keyboard shortcut")
                Spacer()
                ShortcutRecorderView(
                    shortcut: $settings.screenSaverShortcut,
                    isRecording: $isRecordingShortcut,
                    onRecorded: { shortcut in
                        guard !settings.agentGlobalHotkeysEnabled
                                || !shortcut.conflictsWithAgentHotkeys(modifier: settings.hotkeyModifier) else {
                            shortcutMessage = "That shortcut is already used for an agent action."
                            return
                        }
                        settings.screenSaverShortcut = shortcut
                        shortcutMessage = nil
                    },
                    onCleared: {
                        settings.screenSaverShortcut = nil
                        shortcutMessage = nil
                    },
                    onInvalid: { shortcutMessage = $0 })
                    .frame(width: 150, height: 28)
            }
            if settings.screenSaverShortcut != nil {
                HStack {
                    Button("Clear Shortcut") {
                        settings.screenSaverShortcut = nil
                        shortcutMessage = nil
                    }
                    Spacer()
                    Text("Starts the currently selected macOS screen saver.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if settings.agentGlobalHotkeysEnabled,
               settings.screenSaverShortcut?.conflictsWithAgentHotkeys(modifier: settings.hotkeyModifier) == true {
                Text("This shortcut conflicts with an agent action. Choose another shortcut or change the general hotkey modifier.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                LabeledContent("Automation", value: screenSaverAutomation.state.statusText)
                Spacer()
                Button("Enable…", action: screenSaverAutomation.requestPermission)
                    .disabled(screenSaverAutomation.state == .authorized)
                if screenSaverAutomation.state == .denied {
                    Button("Open Settings…", action: screenSaverAutomation.openAutomationSettings)
                }
            }
            HStack {
                LabeledContent(
                    "Shortcut registration",
                    value: screenSaverHotKeyRegistrar.state.statusText)
            }
            if let message = screenSaverHotKeyRegistrar.state.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let shortcutMessage {
                Text(shortcutMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let message = screenSaverAutomation.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Test Screen Saver") {
                _ = screenSaverAutomation.start()
            }
            .disabled(settings.screenSaverShortcut == nil)
            HStack {
                Button("Preview", action: onPreview)
                Button(installer.state.actionTitle, action: installer.install)
                    .disabled(installer.state == .sourceUnavailable)
                Spacer()
                Button("Open Screen Saver Settings…", action: installer.openSystemSettings)
            }
            HStack {
                Button("Reload Installed Saver", action: installer.reloadInstalledSaver)
                    .disabled(!installer.canReloadInstalledSaver)
                Spacer()
                Text("Use after Install, Update, or Reinstall")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("The standard saver shows live status only; prompts, terminal output, and response controls stay in NotchAgent. Keep NotchAgent running for live updates.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = installer.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Sessions the notch is tracking, plus the remote hosts to reach for more.
///
/// By default every running local session is tracked, so this is mostly a live
/// status readout — the editable parts are the remote hosts and the advanced
/// single-socket pin.
private struct SessionsSection: View {
    @Bindable var settings: Settings
    let registry: SessionRegistry?
    let onSessionChange: () -> Void
    let onRemoteHostsChange: () -> Void
    let availableSessions: [String]
    @Binding var newRemoteTarget: String
    @Binding var newRemoteSession: String

    private var isPinned: Bool {
        !(settings.socketPathOverride ?? "").isEmpty || !(settings.sessionName ?? "").isEmpty
    }

    var body: some View {
        Section("Sessions") {
            if let registry, !registry.runtimes.isEmpty {
                ForEach(registry.runtimes, id: \.sessionID) { runtime in
                    LabeledContent {
                        Text(statusText(for: runtime))
                            .font(.caption)
                            .foregroundStyle(statusColor(for: runtime))
                    } label: {
                        Label(
                            runtime.descriptor.label,
                            systemImage: runtime.descriptor.isRemote
                                ? "network" : "rectangle.on.rectangle")
                    }
                }
            } else {
                Text("No herdr sessions found. Start one with `herdr`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = registry?.discoveryError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if isPinned {
                Text("Pinned to a single socket below — other sessions are not tracked.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        Section("Remote hosts") {
            ForEach(settings.remoteHosts) { host in
                let status = tunnelStatus(for: host)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Label(host.id, systemImage: "network")
                        Spacer()
                        Label(status.title, systemImage: status.symbol)
                            .font(.caption)
                            .foregroundStyle(status.color)
                        Button("Remove", systemImage: "minus.circle") {
                            remove(host)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove \(host.id)")
                        .accessibilityLabel("Remove \(host.id)")
                    }
                    if let detail = status.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Add remote host")
                    .font(.subheadline.weight(.medium))
                HStack(alignment: .bottom, spacing: 10) {
                    RemoteHostField(
                        title: "SSH target",
                        placeholder: "workbox",
                        text: $newRemoteTarget)
                    RemoteHostField(
                        title: "Session",
                        placeholder: "All sessions",
                        text: $newRemoteSession)
                        .frame(width: 140)
                    Button("Add", systemImage: "plus", action: addRemote)
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(!SSHTarget.isValid(
                            newRemoteTarget.trimmingCharacters(in: .whitespaces)))
                }
                .onSubmit(addRemote)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "key")
                    .foregroundStyle(.secondary)
                Text("Uses key-only SSH authentication. If your key has a passphrase, "
                     + "load it with `ssh-add` first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Advanced") {
            Picker("Pin to session", selection: Binding(
                get: { settings.sessionName ?? "" },
                set: { settings.sessionName = $0.isEmpty ? nil : $0; onSessionChange() })) {
                Text("Track all sessions").tag("")
                ForEach(availableSessions, id: \.self) { Text($0).tag($0) }
            }
            LabeledContent("Socket override") {
                TextField("Auto-discover", text: Binding(
                    get: { settings.socketPathOverride ?? "" },
                    set: { settings.socketPathOverride = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit(onSessionChange)
            }
        }
    }

    private struct RemoteHostField: View {
        let title: String
        let placeholder: String
        @Binding var text: String

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $text, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(title)
            }
        }
    }

    private struct RemoteHostStatus {
        let title: String
        let symbol: String
        let color: Color
        let detail: String?
    }

    private func tunnelStatus(for host: RemoteHostConfiguration) -> RemoteHostStatus {
        guard let registry else {
            return RemoteHostStatus(
                title: "Not connected",
                symbol: "circle",
                color: .secondary,
                detail: nil)
        }
        let states = registry.tunnelStates.filter { $0.key.hasPrefix("ssh:\(host.target)/") }
        if states.isEmpty {
            return RemoteHostStatus(
                title: "Not connected",
                symbol: "circle",
                color: .secondary,
                detail: nil)
        }
        if states.values.contains(where: { $0.isUp }) {
            return RemoteHostStatus(
                title: "Connected",
                symbol: "checkmark.circle.fill",
                color: .green,
                detail: nil)
        }
        if let failure = states.values.compactMap({ state -> String? in
            if case let .failed(reason) = state { return reason } else { return nil }
        }).first {
            return RemoteHostStatus(
                title: "Connection failed",
                symbol: "exclamationmark.triangle.fill",
                color: .orange,
                detail: failure)
        }
        return RemoteHostStatus(
            title: "Connecting",
            symbol: "clock",
            color: .secondary,
            detail: nil)
    }

    private func addRemote() {
        let target = newRemoteTarget.trimmingCharacters(in: .whitespaces)
        guard SSHTarget.isValid(target) else { return }
        let name = newRemoteSession.trimmingCharacters(in: .whitespaces)
        let host = RemoteHostConfiguration(
            target: target, sessionName: name.isEmpty ? nil : name)
        guard !settings.remoteHosts.contains(host) else { return }
        settings.remoteHosts.append(host)
        onRemoteHostsChange()
        newRemoteTarget = ""
        newRemoteSession = ""
    }

    private func remove(_ host: RemoteHostConfiguration) {
        settings.remoteHosts.removeAll { $0 == host }
        onRemoteHostsChange()
    }

    private func statusText(for runtime: SessionRuntime) -> String {
        // A tunnel that hasn't come up yet is not the same as an unreachable
        // herdr, and the difference decides where the user goes looking.
        if let state = registry?.tunnelState(for: runtime.sessionID) {
            switch state {
            case .connecting, .idle: return "connecting…"
            case .failed: return "tunnel down"
            case .up: break
            }
        }
        switch runtime.connection {
        case .connecting: return "connecting…"
        case .unavailable: return "unreachable"
        case .connected:
            let agents = runtime.agentCount
            return agents == 1 ? "1 agent" : "\(agents) agents"
        }
    }

    private func statusColor(for runtime: SessionRuntime) -> Color {
        if let tunnelState = registry?.tunnelState(for: runtime.sessionID),
           case .failed = tunnelState {
            return .orange
        }
        return runtime.connection == .unavailable ? .orange : .secondary
    }
}
