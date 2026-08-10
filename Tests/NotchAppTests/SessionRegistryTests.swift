import Foundation
import HerdrClient
import Testing
@testable import NotchApp

private func local(_ name: String, socket: String? = nil) -> ResolvedSession {
    ResolvedSession(local: SessionDescriptor(
        kind: .local(name: name),
        serverSocketPath: socket ?? "/tmp/herdr-\(name).sock",
        isDefault: name == SessionDescriptor.defaultSessionName,
        isRunning: true))
}

private func remote(_ target: String, _ name: String = "default") -> ResolvedSession {
    ResolvedSession(
        descriptor: SessionDescriptor(
            kind: .remote(target: target, name: name),
            serverSocketPath: "/home/you/.config/herdr/herdr.sock",
            isRunning: true),
        endpoint: .loopbackTCP(port: 47_891))
}

private final class RegistryCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (String, [String]) -> CommandOutput
    private var recordedCalls: [(String, [String])] = []

    init(handler: @escaping @Sendable (String, [String]) -> CommandOutput) {
        self.handler = handler
    }

    func run(executable: String, arguments: [String]) throws -> CommandOutput {
        lock.lock()
        recordedCalls.append((executable, arguments))
        lock.unlock()
        return handler(executable, arguments)
    }

    var calls: [(String, [String])] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }
}

private final class TunnelConfigurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SSHTunnel.Configuration] = []

    func make(_ configuration: SSHTunnel.Configuration) -> SSHTunnel {
        lock.lock()
        recorded.append(configuration)
        lock.unlock()
        return SSHTunnel(
            configuration: configuration,
            sshPath: nil,
            backoff: BackoffPolicy(base: 60, max: 60))
    }

    var configurations: [SSHTunnel.Configuration] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private func discoveryDirectory(
    remoteJSON: String = #"{"sessions":[]}"#,
    remoteStatus: Int32 = 0,
    runner: RegistryCommandRunner? = nil
) -> (SessionDirectory, RegistryCommandRunner) {
    let commandRunner = runner ?? RegistryCommandRunner { executable, _ in
        let isRemote = executable == "/fake/ssh"
        return CommandOutput(
            status: isRemote ? remoteStatus : 0,
            standardOutput: Data((isRemote ? remoteJSON : #"{"sessions":[]}"#).utf8),
            standardError: isRemote && remoteStatus != 0
                ? Data("temporary SSH failure".utf8) : Data())
    }
    return (
        SessionDirectory(
            runner: commandRunner, herdrPath: "/fake/herdr", sshPath: "/fake/ssh"),
        commandRunner
    )
}

@MainActor
private final class SubscriptionPolicyHost: SessionRuntimeHost {
    var hasVisibleLiveSurface = false
    var preservesResolvedSelection = false
    var foregroundSessionID: String?

    func isVisibleSession(_ runtime: SessionRuntime) -> Bool {
        runtime.sessionID == foregroundSessionID
    }

    func usesPerPaneStatusSubscriptions(_ runtime: SessionRuntime) -> Bool {
        runtime.sessionID == foregroundSessionID
    }

    func sessionRuntime(
        _ runtime: SessionRuntime,
        didObserve transitions: SessionRuntime.Transitions
    ) async {}
}

@Suite("Session registry")
@MainActor
struct SessionRegistryTests {
    /// `apply` only builds runtimes; nothing dials a socket until `start`, so
    /// these run without a herdr server.
    @Test("creates one runtime per session, keyed by session id")
    func createsRuntimePerSession() {
        let registry = SessionRegistry()
        registry.apply([local("default"), local("work")])

        #expect(registry.runtimes.count == 2)
        #expect(registry.runtime(for: "local:default") != nil)
        #expect(registry.runtime(for: "local:work") != nil)
        #expect(registry.runtime(for: "local:missing") == nil)
    }

    @Test("a session that is still wanted keeps its existing runtime")
    func reusesRuntimesAcrossReconciles() {
        let registry = SessionRegistry()
        registry.apply([local("default"), local("work")])
        let before = registry.runtime(for: "local:default")

        registry.apply([local("default"), local("side-project")])

        // Rebuilding would throw away drafts and re-read every pane for nothing.
        #expect(registry.runtime(for: "local:default") === before)
        #expect(registry.runtime(for: "local:work") == nil)
        #expect(registry.runtime(for: "local:side-project") != nil)
    }

    @Test("a changed authoritative socket replaces the stale runtime")
    func replacesRuntimeWhenSocketChanges() {
        let registry = SessionRegistry()
        registry.apply([local("work", socket: "/tmp/old.sock")])
        let before = registry.runtime(for: "local:work")

        registry.apply([local("work", socket: "/tmp/new.sock")])

        let after = registry.runtime(for: "local:work")
        #expect(after !== before)
        #expect(after?.socketPath == "/tmp/new.sock")
    }

    @Test("a remote session dials the local end of its tunnel, not the remote path")
    func remoteRuntimeUsesForwardedSocket() {
        let registry = SessionRegistry()
        let session = remote("workbox")
        registry.apply([session])

        let runtime = registry.runtime(for: "ssh:workbox/default")
        // The descriptor keeps the remote path (that's what ssh -L forwards TO)…
        #expect(runtime?.descriptor.serverSocketPath == "/home/you/.config/herdr/herdr.sock")
        // …while the resolved session says where we actually connect.
        #expect(session.endpoint == .loopbackTCP(port: 47_891))
        #expect(runtime?.descriptor.isRemote == true)
    }

    @Test("display order is stable: default, then named, then remotes")
    func displayOrderIsStable() {
        let registry = SessionRegistry()
        registry.apply([remote("workbox"), local("work"), local("default"), local("aaa")])
        #expect(registry.runtimes.map(\.sessionID)
            == ["local:default", "local:aaa", "local:work", "ssh:workbox/default"])

        // Rediscovery in a different order must not reshuffle the rows.
        registry.apply([local("aaa"), local("default"), remote("workbox"), local("work")])
        #expect(registry.runtimes.map(\.sessionID)
            == ["local:default", "local:aaa", "local:work", "ssh:workbox/default"])
    }

    @Test("applying an empty set drops every runtime")
    func appliesEmptySet() {
        let registry = SessionRegistry()
        registry.apply([local("default")])
        #expect(!registry.isEmpty)
        registry.apply([])
        #expect(registry.isEmpty)
        #expect(registry.runtime(for: "local:default") == nil)
    }

    @Test("duplicate ids collapse to a single runtime")
    func duplicateIDsCollapse() {
        let registry = SessionRegistry()
        // herdr's snapshot can repeat records; discovery should not be able to
        // produce two runtimes racing on the same socket.
        registry.apply([local("default"), local("default", socket: "/tmp/other.sock")])
        #expect(registry.runtimes.count == 1)
    }

    @Test("removing the final remote host tears down its tracked tunnel")
    func removingFinalRemoteHost() async {
        let registry = SessionRegistry()
        let remoteJSON = """
            {"sessions":[{"name":"default","default":true,"running":true,
            "socket_path":"/home/you/.config/herdr/herdr.sock"}]}
            """
        let (withRemote, _) = discoveryDirectory(remoteJSON: remoteJSON)
        await registry.refresh(
            remoteHosts: [RemoteHostConfiguration(target: "workbox")],
            directory: withRemote)
        #expect(registry.tunnelStates["ssh:workbox/default"] != nil)

        let (localOnly, _) = discoveryDirectory()
        await registry.refresh(remoteHosts: [], directory: localOnly)
        #expect(registry.tunnelStates["ssh:workbox/default"] == nil)
        registry.stop()
    }

    @Test("temporary remote discovery failure preserves the known tunnel")
    func failedRemoteDiscoveryPreservesTunnel() async {
        let registry = SessionRegistry()
        let remoteJSON = """
            {"sessions":[{"name":"default","default":true,"running":true,
            "socket_path":"/home/you/.config/herdr/herdr.sock"}]}
            """
        let (success, _) = discoveryDirectory(remoteJSON: remoteJSON)
        let configuration = RemoteHostConfiguration(target: "workbox")
        await registry.refresh(remoteHosts: [configuration], directory: success)
        #expect(registry.tunnelStates["ssh:workbox/default"] != nil)

        let (failure, _) = discoveryDirectory(remoteStatus: 255)
        await registry.refresh(remoteHosts: [configuration], directory: failure)
        #expect(registry.tunnelStates["ssh:workbox/default"] != nil)
        #expect(registry.discoveryError?.contains("temporary SSH failure") == true)
        registry.stop()
    }

    @Test("successful discovery removes a remote session confirmed absent")
    func successfulDiscoveryRemovesMissingSession() async {
        let registry = SessionRegistry()
        let remoteJSON = """
            {"sessions":[{"name":"default","default":true,"running":true,
            "socket_path":"/home/you/.config/herdr/herdr.sock"}]}
            """
        let configuration = RemoteHostConfiguration(target: "workbox")
        let (present, _) = discoveryDirectory(remoteJSON: remoteJSON)
        await registry.refresh(remoteHosts: [configuration], directory: present)
        #expect(registry.tunnelStates["ssh:workbox/default"] != nil)

        let (absent, _) = discoveryDirectory()
        await registry.refresh(remoteHosts: [configuration], directory: absent)
        #expect(registry.tunnelStates["ssh:workbox/default"] == nil)
        registry.stop()
    }

    @Test("multiple filters for one host use one SSH discovery command")
    func groupsConfigurationsByTarget() async {
        let remoteJSON = """
            {"sessions":[
            {"name":"default","running":true,"socket_path":"/remote/default.sock"},
            {"name":"agents","running":true,"socket_path":"/remote/agents.sock"}]}
            """
        let (directory, runner) = discoveryDirectory(remoteJSON: remoteJSON)
        let registry = SessionRegistry()
        await registry.refresh(remoteHosts: [
            RemoteHostConfiguration(target: "workbox", sessionName: "default"),
            RemoteHostConfiguration(target: "workbox", sessionName: "agents"),
        ], directory: directory)

        #expect(runner.calls.filter { $0.0 == "/fake/ssh" }.count == 1)
        #expect(Set(registry.tunnelStates.keys)
            == ["ssh:workbox/default", "ssh:workbox/agents"])
        registry.stop()
    }

    @Test("remote sessions get distinct stable loopback ports")
    func remotePortsAreDistinctAndStable() async {
        let remoteJSON = """
            {"sessions":[
            {"name":"default","running":true,"socket_path":"/remote/default.sock"},
            {"name":"agents","running":true,"socket_path":"/remote/agents.sock"}]}
            """
        let (directory, _) = discoveryDirectory(remoteJSON: remoteJSON)
        let registry = SessionRegistry()
        let recorder = TunnelConfigurationRecorder()
        registry.makeTunnel = { recorder.make($0) }
        let hosts = [RemoteHostConfiguration(target: "workbox")]

        await registry.refresh(remoteHosts: hosts, directory: directory)
        let first = recorder.configurations
        #expect(first.count == 2)
        #expect(Set(first.map(\.localPort)).count == 2)

        await registry.refresh(remoteHosts: hosts, directory: directory)
        // Rediscovery reuses both endpoint assignments and live tunnel objects.
        #expect(recorder.configurations == first)
        registry.stop()
    }

    @Test("local-only refresh preserves remotes without opening SSH")
    func localRefreshDoesNotRediscoverRemote() async {
        let remoteJSON = """
            {"sessions":[{"name":"default","running":true,
            "socket_path":"/remote/default.sock"}]}
            """
        let registry = SessionRegistry()
        let (initial, _) = discoveryDirectory(remoteJSON: remoteJSON)
        await registry.refresh(
            remoteHosts: [RemoteHostConfiguration(target: "workbox")],
            directory: initial)
        #expect(registry.tunnelStates["ssh:workbox/default"] != nil)

        let (localOnly, runner) = discoveryDirectory()
        await registry.refreshLocalSessions(directory: localOnly)

        #expect(runner.calls.filter { $0.0 == "/fake/ssh" }.isEmpty)
        #expect(registry.tunnelStates["ssh:workbox/default"] != nil)
        registry.stop()
    }

    @Test("switching foreground restarts each event stream with the right policy")
    func foregroundPolicyFollowsSelection() {
        let registry = SessionRegistry()
        let host = SubscriptionPolicyHost()
        registry.start(host: host)
        registry.apply([local("default"), local("work")])

        host.foregroundSessionID = "local:default"
        registry.refreshEventSubscriptionPolicies()
        #expect(registry.runtime(for: "local:default")?.eventIncludesPerPaneStatus == true)
        #expect(registry.runtime(for: "local:work")?.eventIncludesPerPaneStatus == false)

        host.foregroundSessionID = "local:work"
        registry.refreshEventSubscriptionPolicies()
        #expect(registry.runtime(for: "local:default")?.eventIncludesPerPaneStatus == false)
        #expect(registry.runtime(for: "local:work")?.eventIncludesPerPaneStatus == true)
        registry.stop()
    }

    @Test("expanded overview keeps every session visible without per-pane subscriptions")
    func overviewPollingPolicy() {
        let model = NotchViewModel()
        model.registry.apply([local("default"), local("work")])
        model.presentation = .overview

        for runtime in model.registry.runtimes {
            #expect(model.isVisibleSession(runtime))
            #expect(!model.usesPerPaneStatusSubscriptions(runtime))
        }
    }

    @Test("screen save keeps every session on the visible polling cadence")
    func screenSavePollingPolicy() {
        let model = NotchViewModel()
        model.registry.apply([local("default"), local("work")])
        #expect(!model.hasVisibleLiveSurface)

        model.setScreenSaveVisible(true)

        #expect(model.hasVisibleLiveSurface)
        for runtime in model.registry.runtimes {
            #expect(model.isVisibleSession(runtime))
            // A read-only ambient board does not justify herdr's expensive
            // ten-times-per-second per-pane subscriptions.
            #expect(!model.usesPerPaneStatusSubscriptions(runtime))
        }
    }
}

@Suite("Session runtime identity")
@MainActor
struct SessionRuntimeIdentityTests {
    @Test("runtimes for the same pane id on different sessions are separate")
    func sameePaneIDDifferentSessions() {
        let registry = SessionRegistry()
        registry.apply([local("default"), remote("workbox")])

        let localRef = AgentRef(sessionID: "local:default", paneID: "w1:p1")
        let remoteRef = AgentRef(sessionID: "ssh:workbox/default", paneID: "w1:p1")

        let localRuntime = registry.runtime(for: localRef)
        let remoteRuntime = registry.runtime(for: remoteRef)
        #expect(localRuntime != nil)
        #expect(remoteRuntime != nil)
        // Routing an action on one ref must never reach the other session.
        #expect(localRuntime !== remoteRuntime)
    }

    @Test("interrupt availability is scoped by full agent reference")
    func interruptAvailabilityUsesSessionAndPane() {
        let model = NotchViewModel()
        model.registry.apply([local("default"), remote("workbox")])

        let localRef = AgentRef(sessionID: "local:default", paneID: "w1:p1")
        let remoteRef = AgentRef(sessionID: "ssh:workbox/default", paneID: "w1:p1")
        let localRuntime = model.registry.runtime(for: localRef)!
        let remoteRuntime = model.registry.runtime(for: remoteRef)!
        localRuntime.connection = .connected
        remoteRuntime.connection = .connected
        localRuntime.store.hydrate(Snapshot(panes: [pane(status: .working)]))
        remoteRuntime.store.hydrate(Snapshot(panes: [pane(status: .idle)]))

        #expect(model.canInterrupt(localRef))
        #expect(!model.canInterrupt(remoteRef))
    }

    @Test("an unreachable remote names the host so the error is actionable")
    func unreachableMessageNamesHost() {
        let localMessage = SessionRuntime.unreachableMessage(
            SessionDescriptor(kind: .local(name: "default"), serverSocketPath: "/tmp/a.sock"))
        let remoteMessage = SessionRuntime.unreachableMessage(
            SessionDescriptor(
                kind: .remote(target: "workbox", name: "default"),
                serverSocketPath: "/home/you/.config/herdr/herdr.sock"))
        #expect(localMessage == "Couldn't reach herdr — is it running?")
        #expect(remoteMessage.contains("workbox"))
    }

    private func pane(status: AgentStatus) -> PaneInfo {
        PaneInfo(
            paneID: "w1:p1", terminalID: "term", workspaceID: "w1",
            tabID: "w1:t1", focused: false, agentStatus: status,
            revision: 1, agent: "codex")
    }
}
