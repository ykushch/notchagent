import AppKit
import Foundation
import HerdrClient
import Observation

/// The owner of a `SessionRuntime` — `NotchViewModel`.
///
/// The runtime deliberately does not play sounds or move the notch itself. With
/// more than one session live, a background session finishing must not be able to
/// stomp the card the user is reading, so every presentation decision stays with
/// the single owner that can see all sessions at once.
@MainActor
protocol SessionRuntimeHost: AnyObject {
    /// Drives the poll cadence whenever a status surface is prominently visible.
    var hasVisibleLiveSurface: Bool { get }
    /// Whether this session is represented by the expanded UI and deserves the
    /// responsive snapshot cadence.
    func isVisibleSession(_ runtime: SessionRuntime) -> Bool
    /// Whether this session owns focused detail and earns expensive per-pane
    /// status subscriptions.
    func usesPerPaneStatusSubscriptions(_ runtime: SessionRuntime) -> Bool
    /// Whether the current presentation wants a resolved selected pane kept on
    /// screen rather than reaped.
    var preservesResolvedSelection: Bool { get }
    /// Called after the runtime has reconciled a poll or an event.
    func sessionRuntime(
        _ runtime: SessionRuntime,
        didObserve transitions: SessionRuntime.Transitions) async
    /// Called when discovery removes a whole server, so presentation side-effects
    /// tied to its globally-scoped pane identities can be cleaned up.
    func sessionRuntimeWasRemoved(sessionID: String)
}

extension SessionRuntimeHost {
    func sessionRuntimeWasRemoved(sessionID: String) {}
}

/// Everything needed to talk to ONE herdr server.
///
/// `session.snapshot`, pane ids, and interaction state are all scoped to a single
/// server — `w1:p1` names a different pane on every host — so the transport, store,
/// and coordinator stay per-session and pane-keyed. Aggregation across sessions
/// happens above this, in `NotchViewModel`.
///
/// Switching sessions builds a new runtime rather than re-pointing an existing one.
/// That is why the rebuild that used to be duplicated verbatim between
/// `NotchViewModel.init` and `NotchViewModel.reconnect(pinnedSession:)` is now just
/// `init`.
@Observable
@MainActor
final class SessionRuntime {
    /// Connection state for the robustness UX (spec 10d): drives a "herdr not
    /// running" empty state vs. a live view.
    enum Connection: Sendable, Equatable { case connecting, connected, unavailable }

    /// What changed on this session in one poll or event, for the host's
    /// side-effects.
    struct Transitions: Sendable, Equatable {
        var newlyBlockedPaneIDs: [String] = []
        var newlyFinishedPaneIDs: [String] = []
        /// The pane that was selected before reconciliation, so the host can tell
        /// whether reconciliation cleared it.
        var selectedPaneIDBefore: String?

        var isEmpty: Bool {
            newlyBlockedPaneIDs.isEmpty && newlyFinishedPaneIDs.isEmpty
        }
    }

    // MARK: Identity

    let descriptor: SessionDescriptor
    let endpoint: HerdrEndpoint
    var socketPath: String { endpoint.description }
    var sessionID: String { descriptor.id }

    // MARK: Live state

    let store = StateStore()

    /// Source of truth for this session: selection, interactions, drafts, errors,
    /// revisions, reads, and response phases are all pane-keyed in here.
    let interactions: InteractionCoordinator
    /// Selected non-blocked pane state: bounded working output and idle prompt
    /// drafts. Kept separate from fingerprint-bound blocked interactions.
    let activity: PaneActivityCoordinator

    private(set) var agentModesByPane: [String: AgentMode] = [:]
    var connection: Connection = .connecting
    /// A session-wide failure (unreachable server), as opposed to the per-pane
    /// errors the coordinator holds.
    var error: String?

    // MARK: Dependencies

    @ObservationIgnored private let client: HerdrClient
    @ObservationIgnored private let actions: Actions
    @ObservationIgnored private let completionProvider: ScreenCompletionSummaryProvider
    @ObservationIgnored private let modeProvider: ScreenAgentModeProvider
    @ObservationIgnored private let nativeRegistry: OpenCodePaneRegistry
    @ObservationIgnored private weak var host: (any SessionRuntimeHost)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Captured by the current event stream. Exposed internally for policy tests.
    @ObservationIgnored private(set) var eventIncludesPerPaneStatus: Bool?

    init(descriptor: SessionDescriptor, client: HerdrClient) {
        self.descriptor = descriptor
        self.client = client
        self.endpoint = client.endpoint
        let actions = Actions(client: client)
        let screenProvider = ScreenInteractionProvider(client: client)
        let registry = OpenCodePaneRegistry()
        let nativeClient = OpenCodeHTTPClient()
        let nativeProvider = OpenCodeNativeInteractionProvider(
            registry: registry, client: nativeClient)
        let provider = RoutedInteractionProvider(
            registry: registry, native: nativeProvider, fallback: screenProvider)
        self.actions = actions
        self.nativeRegistry = registry
        self.completionProvider = ScreenCompletionSummaryProvider(client: client)
        self.modeProvider = ScreenAgentModeProvider(client: client)
        self.interactions = InteractionCoordinator(
            reader: provider,
            responder: RoutedInteractionResponder(
                registry: registry,
                native: OpenCodeNativeInteractionResponder(
                    registry: registry, client: nativeClient),
                fallback: InteractionResponder(
                    provider: screenProvider, actions: actions)))
        self.activity = PaneActivityCoordinator(
            outputProvider: ScreenRecentOutputProvider(client: client),
            promptSender: SafeIdlePromptSender(client: client))
    }

    /// `endpoint` is explicit on purpose. A remote descriptor's
    /// `serverSocketPath` lives on the *remote* filesystem; what we connect to is
    /// the local end of its SSH forward, which only the caller knows.
    convenience init(descriptor: SessionDescriptor, endpoint: HerdrEndpoint) {
        self.init(descriptor: descriptor, client: HerdrClient(endpoint: endpoint))
    }

    // MARK: Lifecycle

    /// Begin driving this session from herdr.
    ///
    /// **Primary path: snapshot polling.** Not because events are unreliable —
    /// herdr backstops every per-pane status subscription with its own `pane_get`
    /// — but because that backstop is exactly what makes subscriptions expensive:
    /// herdr re-reads each subscribed pane on a 100ms server loop, whereas one
    /// `session.snapshot` covers every pane in this session in a single round-trip.
    ///
    /// **Accelerator path: events.** We still consume the stream so updates land
    /// instantly when they do fire, and so new panes are noticed promptly. Both
    /// paths funnel through the store, which dedupes and diffs, so they can't
    /// double-count.
    func start(host: any SessionRuntimeHost) {
        self.host = host
        guard pollTask == nil, eventTask == nil else { return }
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                await self.pollOnce()
                let cadence = SnapshotPollingPolicy.nanoseconds(
                    isExpanded: self.host?.hasVisibleLiveSurface ?? false,
                    hasBlockedPanes: self.blockedPaneCount > 0,
                    hasWorkingPanes: self.hasWorkingPanes,
                    isUnavailable: self.connection == .unavailable,
                    context: self.pollingContext)
                try? await Task.sleep(nanoseconds: cadence)
            }
        }
        startEventTask(includePerPaneStatus: wantsPerPaneStatusSubscriptions)
    }

    /// Rebuild only the event stream when this runtime moves between foreground
    /// and background. Polling, stores, interactions, and drafts stay untouched.
    func refreshEventSubscriptionPolicy() {
        guard eventTask != nil else { return }
        let desired = wantsPerPaneStatusSubscriptions
        guard eventIncludesPerPaneStatus != desired else { return }
        eventTask?.cancel()
        eventTask = nil
        startEventTask(includePerPaneStatus: desired)
    }

    private func startEventTask(includePerPaneStatus: Bool) {
        eventIncludesPerPaneStatus = includePerPaneStatus
        eventTask = Task { @MainActor in
            while !Task.isCancelled {
                // The event loop no longer owns hydration (the poll does); it just
                // opens a stream over the current panes and reacts to what arrives.
                //
                // Only the foreground session subscribes per pane: each such
                // subscription makes herdr re-read that pane ten times a second,
                // which is not a cost worth paying for a session nobody is looking
                // at. Background sessions keep the (free) lifecycle subscriptions
                // and get status from the snapshot poll.
                let subs = self.store.currentSubscriptions(
                    includePerPaneStatus: includePerPaneStatus)
                let watched = Set(self.store.panes.keys)
                let stream = self.client.events(subscriptions: { subs })
                for await raw in stream {
                    guard let event = EventEnvelope(raw) else { continue }
                    await self.handle(event)
                    // A genuinely new pane → break so we resubscribe over the new
                    // set. Confirm against a fresh snapshot (herdr replays
                    // pane_created for closed panes, which would otherwise thrash).
                    if (event.event == "pane_created" || event.event == "pane_agent_detected"),
                       let pane = event.paneID, !watched.contains(pane),
                       await self.liveHasUnwatchedPane(watched: watched) {
                        break
                    }
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 500_000_000)  // brief pause before resubscribe
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        eventTask?.cancel()
        eventTask = nil
        eventIncludesPerPaneStatus = nil
    }

    // MARK: Derived state

    var pollingContext: SnapshotPollingPolicy.SessionContext {
        SnapshotPollingPolicy.SessionContext(
            isVisible: host?.isVisibleSession(self) ?? true,
            isRemote: descriptor.isRemote)
    }

    private var wantsPerPaneStatusSubscriptions: Bool {
        host?.usesPerPaneStatusSubscriptions(self) ?? true
    }

    var blockedPaneCount: Int { store.blockedPanes.count }
    var agentCount: Int { store.panes.values.filter { $0.agent != nil }.count }
    var hasWorkingPanes: Bool {
        store.panes.keys.contains { store.derivedStatus(forPane: $0) == .working }
    }

    /// Panes worth showing: an agent is known, or the pane has a derived status.
    var displayablePanes: [PaneInfo] {
        store.panes.values.filter {
            $0.agent != nil || store.derivedStatus(forPane: $0.paneID) != .unknown
        }
    }

    var isActing: Bool {
        interactions.selectedState?.phase.isBusy == true
            || activity.selectedState?.promptPhase == .sending
    }

    /// Mode cycling is intentionally exposed only for agents whose terminal UI
    /// documents Shift-Tab for this purpose. We do not infer the current mode.
    func supportsModeCycling(paneID: String) -> Bool {
        AgentModeCycling.isSupported(agentID: store.panes[paneID]?.agent)
    }

    // MARK: Reconciliation

    /// One poll: fetch a snapshot and reconcile it. Presentation side-effects are
    /// the host's job — this reports what changed and stops there.
    private func pollOnce() async {
        do {
            let result = try await client.request("session.snapshot")
            let snapValue = result["snapshot"] ?? result
            let snapshot = try snapValue.decode(Snapshot.self)
            if connection != .connected { connection = .connected }
            if error != nil { error = nil }
            let selectedBefore = interactions.selectedPaneID
            let stateTransitions = store.reconcileTransitions(snapshot)
            agentModesByPane = agentModesByPane.filter { store.panes[$0.key] != nil }
            _ = await reconcileInteractions(
                newlyBlocked: stateTransitions.newlyBlockedPaneIDs)
            _ = await reconcileActivity()
            await refreshSelectedAgentMode()
            await captureCompletionSummaries(
                paneIDs: stateTransitions.newlyFinishedPaneIDs)
            await host?.sessionRuntime(self, didObserve: Transitions(
                newlyBlockedPaneIDs: stateTransitions.newlyBlockedPaneIDs,
                newlyFinishedPaneIDs: stateTransitions.newlyFinishedPaneIDs,
                selectedPaneIDBefore: selectedBefore))
        } catch {
            if connection != .unavailable { connection = .unavailable }
            let message = Self.unreachableMessage(descriptor)
            if self.error != message { self.error = message }
            await host?.sessionRuntime(self, didObserve: Transitions(
                selectedPaneIDBefore: interactions.selectedPaneID))
        }
    }

    /// Apply one event to the store and reconcile interactions off the back of it.
    private func handle(_ event: EventEnvelope) async {
        // The client emits this sentinel if herdr rejected the subscribe batch —
        // surface it instead of silently looping (it would otherwise never deliver
        // events). Marks the connection unavailable so the UI shows the error.
        if event.event == "__subscribe_error" {
            connection = .unavailable
            error = "herdr rejected the event subscription: \(event.data["message"]?.stringValue ?? "invalid_request")"
            return
        }
        let selectedBefore = interactions.selectedPaneID
        let stateTransitions = store.applyTransitions(event)
        // Reconcile inline rather than in a detached task: events for one session
        // are then applied in order, and the host is notified once the interaction
        // behind a transition is actually readable — same ordering the poll path
        // has always had.
        _ = await reconcileInteractions(
            newlyBlocked: stateTransitions.newlyBlockedPaneIDs,
            countsTowardFallbackCadence: false)
        _ = await reconcileActivity(countsTowardFallbackCadence: false)
        await captureCompletionSummaries(
            paneIDs: stateTransitions.newlyFinishedPaneIDs)
        await host?.sessionRuntime(self, didObserve: Transitions(
            newlyBlockedPaneIDs: stateTransitions.newlyBlockedPaneIDs,
            newlyFinishedPaneIDs: stateTransitions.newlyFinishedPaneIDs,
            selectedPaneIDBefore: selectedBefore))
    }

    /// Whether a fresh snapshot contains a pane not in `watched` — used to confirm
    /// a genuine new pane before resubscribing (filters out herdr's stale
    /// `pane_created` replays of closed panes).
    private func liveHasUnwatchedPane(watched: Set<String>) async -> Bool {
        guard let result = try? await client.request("session.snapshot") else { return false }
        let snapValue = result["snapshot"] ?? result
        guard let snapshot = try? snapValue.decode(Snapshot.self) else { return false }
        return !Set(snapshot.uniquePanes.map(\.paneID)).subtracting(watched).isEmpty
    }

    @discardableResult
    private func reconcileInteractions(
        newlyBlocked: [String],
        countsTowardFallbackCadence: Bool = true
    ) async -> InteractionReconcileResult {
        let paneValues = Array(store.panes.values)
        await nativeRegistry.replace(panes: paneValues)
        return await interactions.reconcile(
            panes: paneValues.map { pane in
                InteractionPaneSnapshot(
                    paneID: pane.paneID, agentID: pane.agent,
                    revision: pane.revision,
                    isBlocked: store.derivedStatus(forPane: pane.paneID) == .blocked,
                    isWorking: store.derivedStatus(forPane: pane.paneID) == .working)
            },
            newlyBlockedPaneIDs: newlyBlocked,
            preserveSelectedResolvedPane: host?.preservesResolvedSelection ?? false,
            countsTowardFallbackCadence: countsTowardFallbackCadence)
    }

    @discardableResult
    private func reconcileActivity(
        countsTowardFallbackCadence: Bool = true
    ) async -> [String] {
        await activity.reconcile(
            panes: store.panes.values.map { pane in
                PaneActivitySnapshot(
                    paneID: pane.paneID,
                    agentStatus: pane.agentStatus,
                    revision: pane.revision)
            },
            selectedPaneID: interactions.selectedPaneID,
            countsTowardFallbackCadence: countsTowardFallbackCadence)
    }

    /// One bounded tail read per newly-finished transition. Failed or empty
    /// extraction is intentionally not retried on every poll.
    private func captureCompletionSummaries(paneIDs: [String]) async {
        for paneID in paneIDs where store.panes[paneID] != nil {
            guard let summary = try? await completionProvider.completionSummary(
                paneID: paneID) else { continue }
            interactions.cacheCompletionSummary(summary, paneID: paneID)
        }
    }

    // MARK: Selection & agent mode

    func select(paneID: String) async {
        await interactions.select(paneID: paneID)
        _ = await reconcileActivity(countsTowardFallbackCadence: false)
        await refreshAgentMode(paneID: paneID)
    }

    func clearSelection() {
        interactions.clearSelection()
        activity.clearSelection()
    }

    private func refreshSelectedAgentMode() async {
        guard let paneID = interactions.selectedPaneID else { return }
        await refreshAgentMode(paneID: paneID)
    }

    func refreshAgentMode(paneID: String) async {
        guard let pane = store.panes[paneID],
              AgentModeCycling.isSupported(agentID: pane.agent),
              let mode = try? await modeProvider.mode(
                paneID: paneID, agentID: pane.agent) else { return }
        agentModesByPane[paneID] = mode
    }

    // MARK: Actions

    /// The only entry point for structured UI actions. The responder re-reads and
    /// validates stable identity before it can execute any operation.
    func respond(paneID: String, intent: InteractionResponseIntent) async {
        _ = await interactions.respond(paneID: paneID, intent: intent)
    }

    @discardableResult
    func sendIdlePrompt(paneID: String) async -> Bool {
        await activity.sendPrompt(paneID: paneID)
    }

    func retryWorkingOutput() async {
        _ = await activity.refreshSelectedOutput()
    }

    func reply(paneID: String, text: String, submit: Bool = true) async {
        let actions = actions
        await performManualAction(paneID: paneID) {
            _ = try await actions.reply(pane: paneID, text: text, submit: submit)
        }
    }

    func sendRawKeys(paneID: String, keys: [String]) async {
        let actions = actions
        await performManualAction(paneID: paneID) {
            _ = try await actions.sendRawKeys(pane: paneID, keys: keys)
        }
    }

    /// Send one confirmed interrupt to this session's pane. `Actions` performs a
    /// fresh status read before Escape is written; errors are returned to the host
    /// so the working-pane shelf can keep them visible.
    func interrupt(paneID: String) async throws {
        _ = try await actions.interrupt(pane: paneID)
    }

    func cycleAgentMode(paneID: String) async {
        let actions = actions
        await performManualAction(paneID: paneID) {
            _ = try await actions.cycleAgentMode(pane: paneID)
        }
        try? await Task.sleep(nanoseconds: 160_000_000)
        await refreshAgentMode(paneID: paneID)
    }

    /// Focus the pane in herdr, then present its terminal.
    ///
    /// This works unchanged for a remote session: the focus travels over the
    /// forwarded socket exactly as it would over a local one.
    func jump(paneID: String, presenter: any TerminalPresenting) async throws -> ActionResult {
        let info = store.panes[paneID]
        return try await actions.jump(
            pane: paneID,
            workspaceID: info?.workspaceID,
            tabID: info?.tabID,
            presenter: presenter)
    }

    /// Manual/raw terminal actions deliberately remain available for fallback
    /// screens. Structured controls use `respond(paneID:intent:)` instead.
    private func performManualAction(
        paneID: String,
        _ body: @escaping @Sendable () async throws -> Void
    ) async {
        _ = await interactions.performManualAction(paneID: paneID, operation: body)
    }

    func setError(_ message: String?, paneID: String) {
        interactions.setError(message, paneID: paneID)
    }

    static func unreachableMessage(_ descriptor: SessionDescriptor) -> String {
        guard let target = descriptor.kind.sshTarget else {
            return "Couldn't reach herdr — is it running?"
        }
        return "Couldn't reach herdr on \(target) — is it running there?"
    }
}
