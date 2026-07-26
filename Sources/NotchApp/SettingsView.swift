import HerdrClient
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: Settings
    @Bindable var updates: UpdateChecker
    let onSessionChange: () -> Void
    let onRemoteHostsChange: () -> Void
    let availableSessions: [String]
    /// Live registry, so each row can show what the session is actually doing
    /// rather than just what was configured.
    let registry: SessionRegistry?

    @State private var newRemoteTarget = ""
    @State private var newRemoteSession = ""
    @State private var discoveredSessions: [String]?

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
            Toggle("Auto-expand when done", isOn: $settings.autoExpandOnDone)
            Toggle("Enable sounds", isOn: $settings.soundEnabled)
            Toggle("Respect Do Not Disturb", isOn: $settings.respectDND)
            Picker("Hotkey modifier", selection: $settings.hotkeyModifier) {
                ForEach(HotkeyModifier.allCases) { Text("\($0.displayName) (\($0.symbols))").tag($0) }
            }
            Picker("Pill display", selection: $settings.displayPlacement) {
                ForEach(DisplayPlacement.allCases) { Text($0.displayName).tag($0) }
            }
            Text(displayPlacementHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Picker("Compact indicator", selection: $settings.compactIndicatorMode) {
                ForEach(CompactIndicatorMode.allCases) { Text($0.displayName).tag($0) }
            }
            Text("Reveal on hover keeps a minimal status line visible until you point at it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
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
        .frame(width: 460, height: 720)
        .task {
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
                LabeledContent {
                    HStack {
                        Text(tunnelText(for: host)).font(.caption).foregroundStyle(.secondary)
                        Button("Remove") { remove(host) }
                    }
                } label: {
                    Label(host.id, systemImage: "network")
                }
            }
            HStack {
                TextField("ssh target (e.g. workbox)", text: $newRemoteTarget)
                TextField("session (optional)", text: $newRemoteSession)
                    .frame(width: 120)
                Button("Add", action: addRemote)
                    .disabled(!SSHTarget.isValid(
                        newRemoteTarget.trimmingCharacters(in: .whitespaces)))
            }
            Text("NotchAgent forwards the remote herdr socket over SSH. Key-only auth: "
                 + "load your key with `ssh-add` first — it can't prompt for a passphrase.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Advanced") {
            Picker("Pin to session", selection: Binding(
                get: { settings.sessionName ?? "" },
                set: { settings.sessionName = $0.isEmpty ? nil : $0; onSessionChange() })) {
                Text("Track all sessions").tag("")
                ForEach(availableSessions, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Text("Socket override")
                TextField("Auto-discover", text: Binding(
                    get: { settings.socketPathOverride ?? "" },
                    set: { settings.socketPathOverride = $0.isEmpty ? nil : $0 }))
                    .onSubmit(onSessionChange)
            }
        }
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

    private func tunnelText(for host: RemoteHostConfiguration) -> String {
        guard let registry else { return "" }
        let states = registry.tunnelStates.filter { $0.key.hasPrefix("ssh:\(host.target)/") }
        if states.isEmpty { return "not connected" }
        if states.values.contains(where: { $0.isUp }) { return "connected" }
        if let failure = states.values.compactMap({ state -> String? in
            if case let .failed(reason) = state { return reason } else { return nil }
        }).first {
            return failure
        }
        return "connecting…"
    }
}
