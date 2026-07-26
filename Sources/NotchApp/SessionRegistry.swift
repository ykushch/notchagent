import Foundation
import HerdrClient
import Observation

/// A session plus the socket we actually dial for it.
///
/// The two differ for remote sessions: `descriptor.serverSocketPath` is a path on
/// the remote filesystem, while `socketPath` is the local end of its SSH forward.
struct ResolvedSession: Sendable, Equatable {
    let descriptor: SessionDescriptor
    let socketPath: String

    var id: String { descriptor.id }

    /// A local session dials the socket herdr reported directly.
    init(local descriptor: SessionDescriptor) {
        self.descriptor = descriptor
        self.socketPath = descriptor.serverSocketPath
    }

    init(descriptor: SessionDescriptor, socketPath: String) {
        self.descriptor = descriptor
        self.socketPath = socketPath
    }
}

/// A remote herdr the user wants tracked.
struct RemoteHostConfiguration: Sendable, Hashable, Codable, Identifiable {
    /// Any ssh destination: `workbox`, `you@host`, a `Host` alias.
    let target: String
    /// A single named session, or nil to track every running session on the host.
    let sessionName: String?

    var id: String { sessionName.map { "\(target)/\($0)" } ?? target }

    init(target: String, sessionName: String? = nil) {
        self.target = target
        self.sessionName = sessionName
    }
}

/// Owns one `SessionRuntime` per herdr server the notch is tracking, plus an
/// `SSHTunnel` per remote session.
///
/// herdr sessions come and go — a named session can be started or stopped at any
/// time — so the desired set is re-derived periodically rather than fixed at
/// launch. Runtimes are keyed by session id and reused across reconciles: a
/// session that is still present keeps its store, drafts, and in-flight reads.
@Observable
@MainActor
final class SessionRegistry {
    /// Ordered for stable UI: default session first, then locals by name, then
    /// remotes. Sorting here rather than at each read keeps row order from
    /// jittering as discovery re-runs.
    private(set) var runtimes: [SessionRuntime] = []

    /// Live tunnel state per remote session id, so the UI can say "tunnel down"
    /// rather than the misleading "herdr isn't running".
    private(set) var tunnelStates: [String: SSHTunnel.State] = [:]

    /// Why the last discovery failed, if it did. Kept separate from a session's
    /// own connection error: not being able to *look* is a different problem from
    /// a session being unreachable.
    private(set) var discoveryError: String?

    @ObservationIgnored private var runtimesByID: [String: SessionRuntime] = [:]
    @ObservationIgnored private var tunnels: [String: SSHTunnel] = [:]
    /// Remote sessions discovered over ssh, whether or not their tunnel is up yet.
    @ObservationIgnored private var knownRemoteSessions: [String: ResolvedSession] = [:]
    @ObservationIgnored private var localSessions: [ResolvedSession] = []
    @ObservationIgnored private var localDiscoveryError: String?
    @ObservationIgnored private var remoteDiscoveryError: String?
    @ObservationIgnored private weak var host: (any SessionRuntimeHost)?
    @ObservationIgnored private var isStarted = false

    /// How a tunnel is built for a remote session. Injectable so the remote path
    /// can be driven end to end against a stand-in `ssh`.
    @ObservationIgnored
    var makeTunnel: @Sendable (SSHTunnel.Configuration) -> SSHTunnel = {
        SSHTunnel(configuration: $0)
    }

    // MARK: Lifecycle

    func start(host: any SessionRuntimeHost) {
        self.host = host
        isStarted = true
        for runtime in runtimes { runtime.start(host: host) }
    }

    func stop() {
        isStarted = false
        for runtime in runtimes { runtime.stop() }
        let tunnels = Array(self.tunnels.values)
        self.tunnels = [:]
        tunnelStates = [:]
        Task { for tunnel in tunnels { await tunnel.stop() } }
    }

    // MARK: Lookup

    func runtime(for sessionID: String) -> SessionRuntime? { runtimesByID[sessionID] }

    func runtime(for ref: AgentRef) -> SessionRuntime? { runtimesByID[ref.sessionID] }

    var isEmpty: Bool { runtimes.isEmpty }

    /// A remote session whose tunnel is not up yet isn't broken — it's still
    /// dialling. The UI uses this to avoid crying "unreachable" during connect.
    func tunnelState(for sessionID: String) -> SSHTunnel.State? { tunnelStates[sessionID] }

    /// Anything the user should see about a session that has no runtime yet.
    var pendingTunnelMessages: [String] {
        tunnelStates.compactMap { _, state in
            if case let .failed(reason) = state { return reason }
            return nil
        }.sorted()
    }

    // MARK: Reconciliation

    /// Bring the live runtimes in line with `sessions`.
    ///
    /// Runtimes for sessions that are still wanted are kept as-is — recreating one
    /// would drop the user's drafts and re-read every pane for nothing.
    func apply(_ sessions: [ResolvedSession]) {
        let wanted = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (id, runtime) in runtimesByID where wanted[id] == nil {
            runtime.stop()
            runtimesByID[id] = nil
        }

        for (id, session) in wanted {
            guard let runtime = runtimesByID[id],
                  runtime.socketPath != session.socketPath else { continue }
            // Discovery is authoritative. Reusing this runtime would leave every
            // request dialing the old socket forever.
            runtime.stop()
            runtimesByID[id] = nil
        }

        for session in wanted.values where runtimesByID[session.id] == nil {
            let runtime = SessionRuntime(
                descriptor: session.descriptor, socketPath: session.socketPath)
            runtimesByID[session.id] = runtime
            if isStarted, let host { runtime.start(host: host) }
        }

        runtimes = runtimesByID.values.sorted(by: Self.displayOrder)
        refreshEventSubscriptionPolicies()
    }

    /// Selection and registry-size changes can move runtimes between foreground
    /// and background. Let each live runtime update only its event stream.
    func refreshEventSubscriptionPolicies() {
        for runtime in runtimes { runtime.refreshEventSubscriptionPolicy() }
    }

    /// Default session first, then local sessions by name, then remotes grouped by
    /// host. Deterministic so the attention list doesn't reshuffle on rediscovery.
    private static func displayOrder(_ left: SessionRuntime, _ right: SessionRuntime) -> Bool {
        let l = left.descriptor, r = right.descriptor
        if l.isRemote != r.isRemote { return !l.isRemote }
        if !l.isRemote, l.isDefault != r.isDefault { return l.isDefault }
        return l.id < r.id
    }

    /// Everything currently worth running: all local sessions, plus the remote
    /// ones whose tunnel has come up.
    private func applyCurrentSessions() {
        let remotes = knownRemoteSessions.values.filter {
            tunnelStates[$0.id]?.isUp == true
        }
        apply(localSessions + remotes)
    }

    // MARK: Discovery

    /// Re-derive the tracked sessions from herdr.
    ///
    /// A discovery failure deliberately leaves the existing runtimes alone: the
    /// `herdr` CLI or the network being briefly unavailable is not evidence that
    /// the sessions we are already polling have gone away.
    func refresh(
        remoteHosts: [RemoteHostConfiguration] = [],
        directory: SessionDirectory = SessionDirectory()
    ) async {
        guard !Task.isCancelled else { return }
        let localResult = await Self.discoverLocal(directory: directory)
        guard !Task.isCancelled else { return }
        switch localResult {
        case let .success(sessions):
            localSessions = sessions
            localDiscoveryError = nil
        case let .failure(error):
            localDiscoveryError = Self.describe(error)
        }

        var remoteFailures: [String] = []
        let configurationsByTarget = Dictionary(grouping: remoteHosts, by: \.target)
        var discoveredRemote = knownRemoteSessions.filter { id, session in
            guard let target = session.descriptor.kind.sshTarget,
                  let configurations = configurationsByTarget[target] else { return false }
            let name = session.descriptor.kind.name
            let remainsConfigured = configurations.contains {
                $0.sessionName == nil || $0.sessionName == name
            }
            return remainsConfigured && tunnels[id] != nil
        }
        for (target, configurations) in configurationsByTarget {
            let result = await Self.discoverRemote(
                target: target, configurations: configurations, directory: directory
            )
            guard !Task.isCancelled else { return }
            switch result {
            case let .success(sessions):
                // A successful listing is authoritative for this host. Remove its
                // old entries before adding the sessions that still match the
                // user's configuration.
                discoveredRemote = discoveredRemote.filter {
                    $0.value.descriptor.kind.sshTarget != target
                }
                for session in sessions { discoveredRemote[session.id] = session }
            case let .failure(error):
                // Keep the last known sessions and their live tunnels. A temporary
                // inability to list a host is not evidence that its sessions ended.
                remoteFailures.append(Self.describe(error))
            }
        }
        // Always reconcile, including an empty configuration: removing the final
        // remote host must stop its tunnels rather than leaving it tracked forever.
        reconcileTunnels(for: discoveredRemote)

        remoteDiscoveryError = remoteFailures.isEmpty
            ? nil : remoteFailures.sorted().joined(separator: "\n")
        publishDiscoveryError()
        applyCurrentSessions()
    }

    /// Refresh local sessions without opening any SSH connections or changing the
    /// last known remote set.
    func refreshLocalSessions(directory: SessionDirectory = SessionDirectory()) async {
        switch await Self.discoverLocal(directory: directory) {
        case let .success(sessions):
            localSessions = sessions
            localDiscoveryError = nil
        case let .failure(error):
            localDiscoveryError = Self.describe(error)
        }
        publishDiscoveryError()
        applyCurrentSessions()
    }

    private func publishDiscoveryError() {
        let failures = [localDiscoveryError, remoteDiscoveryError].compactMap { $0 }
        discoveryError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// `SessionDirectory` spawns a process and blocks on it, which must never
    /// happen on the UI thread.
    private nonisolated static func discoverLocal(
        directory: SessionDirectory
    ) async -> Result<[ResolvedSession], any Error> {
        await Task.detached(priority: .utility) {
            do {
                // A stopped session has no server to connect to; polling it would
                // just produce a permanent "couldn't reach herdr" row.
                return .success(try directory.localSessions()
                    .filter(\.isRunning).map(ResolvedSession.init(local:)))
            } catch {
                return .failure(error)
            }
        }.value
    }

    private nonisolated static func discoverRemote(
        target: String,
        configurations: [RemoteHostConfiguration],
        directory: SessionDirectory
    ) async -> Result<[ResolvedSession], any Error> {
        await Task.detached(priority: .utility) {
            do {
                let tracksEverySession = configurations.contains { $0.sessionName == nil }
                let selectedNames = Set(configurations.compactMap(\.sessionName))
                let sessions = try directory.remoteSessions(target: target)
                    .filter(\.isRunning)
                    .filter { tracksEverySession || selectedNames.contains($0.kind.name) }
                return .success(sessions.map { descriptor in
                    ResolvedSession(
                        descriptor: descriptor,
                        socketPath: SSHTunnel.localSocketPath(forSessionID: descriptor.id))
                })
            } catch {
                return .failure(error)
            }
        }.value
    }

    // MARK: Tunnels

    /// Start a tunnel for each newly discovered remote session, and tear down the
    /// ones whose session has gone away.
    private func reconcileTunnels(for discovered: [String: ResolvedSession]) {
        for (id, tunnel) in tunnels where discovered[id] == nil {
            tunnels[id] = nil
            tunnelStates[id] = nil
            knownRemoteSessions[id] = nil
            Task { await tunnel.stop() }
        }

        for (id, session) in discovered {
            if let existing = tunnels[id],
               let previous = knownRemoteSessions[id],
               previous != session {
                // The authoritative remote socket changed. Keeping this tunnel
                // would continue forwarding the stale path under the same id.
                tunnels[id] = nil
                tunnelStates[id] = nil
                knownRemoteSessions[id] = nil
                Task { await existing.stop() }
            }
            knownRemoteSessions[id] = session
            guard tunnels[id] == nil,
                  let target = session.descriptor.kind.sshTarget else { continue }
            let tunnel = makeTunnel(SSHTunnel.Configuration(
                target: target,
                remoteSocketPath: session.descriptor.serverSocketPath,
                localSocketPath: session.socketPath))
            tunnels[id] = tunnel
            tunnelStates[id] = .connecting
            Task {
                // The tunnel's callback fires off-actor; hop back before touching
                // any registry state.
                await tunnel.start { [weak self] _ in
                    Task { @MainActor in
                        // Callback tasks are not FIFO-guaranteed. Read the actor's
                        // current state so a delayed `.connecting` callback cannot
                        // overwrite a later `.up`.
                        let currentState = await tunnel.state
                        self?.tunnelDidChangeState(
                            sessionID: id, tunnel: tunnel, state: currentState)
                    }
                }
            }
        }
    }

    /// A tunnel coming up is what makes its session eligible to run; a tunnel
    /// going down takes the session's runtime with it, so the poll loop stops
    /// hammering a dead socket.
    private func tunnelDidChangeState(
        sessionID: String, tunnel: SSHTunnel, state: SSHTunnel.State
    ) {
        guard tunnels[sessionID] === tunnel else { return }
        tunnelStates[sessionID] = state
        applyCurrentSessions()
    }
}
