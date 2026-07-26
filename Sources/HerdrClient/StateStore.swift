import Foundation

/// The rollup status shown in the UI. Superset of a pane's authored state:
/// `done` is *derived* here (a pane that finished and hasn't been viewed),
/// since the pane authority never emits `done`.
public enum RollupStatus: String, Sendable, CaseIterable {
    case blocked
    case working
    case done
    case idle
    case unknown

    /// Precedence for rolling up a set of panes: higher wins. Also the sort order
    /// for the agent list (blocked floats to the top).
    public var precedence: Int {
        switch self {
        case .blocked: return 4
        case .working: return 3
        case .done: return 2
        case .idle: return 1
        case .unknown: return 0
        }
    }

    static func rollup(_ statuses: [RollupStatus]) -> RollupStatus {
        statuses.max(by: { $0.precedence < $1.precedence }) ?? .unknown
    }
}

public struct StateTransitionResult: Sendable, Equatable {
    public let newlyBlockedPaneIDs: [String]
    public let newlyFinishedPaneIDs: [String]

    public init(newlyBlockedPaneIDs: [String] = [],
                newlyFinishedPaneIDs: [String] = []) {
        self.newlyBlockedPaneIDs = newlyBlockedPaneIDs.sorted()
        self.newlyFinishedPaneIDs = newlyFinishedPaneIDs.sorted()
    }
}

/// Single observable source of truth for the UI: panes/agents keyed by id, with
/// per-tab and per-workspace rollups. Hydrated once from `session.snapshot`,
/// then kept live by events. `@MainActor` so SwiftUI can bind directly.
@MainActor
@Observable
public final class StateStore {
    public typealias Clock = @Sendable () -> Date

    // MARK: Live state

    /// Deduped panes keyed by `pane_id`.
    public private(set) var panes: [String: PaneInfo] = [:]
    public private(set) var workspaces: [String: WorkspaceInfo] = [:]
    public private(set) var tabs: [String: TabInfo] = [:]
    public private(set) var focusedPaneID: String?

    /// Panes that transitioned working→idle and have NOT been acknowledged/viewed.
    /// These read as `.done` in the rollup until `acknowledge(_:)` or focus clears them.
    public private(set) var finishedUnseen: Set<String> = []

    /// Soft signal: panes that emitted `output_matched` (may need attention even
    /// if strict `blocked` didn't fire).
    public private(set) var outputMatched: Set<String> = []

    /// Soft signal: when each currently-working pane started working, for a
    /// "maybe stuck" heuristic. Cleared when the pane leaves `working`.
    public private(set) var workingSince: [String: Date] = [:]

    /// When each currently-blocked pane began waiting for the user. Kept
    /// separately from prompt read freshness: refreshing the same prompt must
    /// not reset the elapsed blocked time.
    public private(set) var blockedSince: [String: Date] = [:]

    /// Monotonic counter bumped on every applied change — lets tests/observers
    /// detect "something changed" without diffing.
    public private(set) var revision: Int = 0

    @ObservationIgnored private let now: Clock

    public init(now: @escaping Clock = Date.init) {
        self.now = now
    }

    // MARK: Hydration

    /// Replace pane/tab/workspace state from a fresh snapshot. Idempotent and
    /// reconnect-safe: re-hydrating preserves the `finishedUnseen`/`outputMatched`
    /// sets for panes that still exist, and drops them for panes that vanished.
    public func hydrate(_ snapshot: Snapshot) {
        var newPanes: [String: PaneInfo] = [:]
        for p in snapshot.uniquePanes { newPanes[p.paneID] = p }

        var newWorkspaces: [String: WorkspaceInfo] = [:]
        for w in snapshot.workspaces { newWorkspaces[w.workspaceID] = w }
        var newTabs: [String: TabInfo] = [:]
        for t in snapshot.tabs { newTabs[t.tabID] = t }

        let liveIDs = Set(newPanes.keys)
        finishedUnseen.formIntersection(liveIDs)
        outputMatched.formIntersection(liveIDs)
        for id in workingSince.keys where !liveIDs.contains(id) { workingSince[id] = nil }
        for id in blockedSince.keys where !liveIDs.contains(id) { blockedSince[id] = nil }

        // Preserve timestamps for unchanged states across hydration, while
        // clearing the opposite clock if the fresh snapshot changed status.
        for (id, pane) in newPanes {
            switch pane.agentStatus {
            case .working:
                blockedSince[id] = nil
                if workingSince[id] == nil { workingSince[id] = now() }
            case .blocked:
                workingSince[id] = nil
                if blockedSince[id] == nil { blockedSince[id] = now() }
            case .idle, .done, .unknown:
                workingSince[id] = nil
                blockedSince[id] = nil
            }
        }

        panes = newPanes
        workspaces = newWorkspaces
        tabs = newTabs
        focusedPaneID = snapshot.focusedPaneID
        bump()
    }

    /// Reconcile a fresh snapshot into the live store WITHOUT wiping derived
    /// state, applying each pane's status through the same transition logic as
    /// live events. This is the reliable status path: herdr's snapshot always
    /// carries correct `agent_status`, whereas `pane_agent_status_changed` events
    /// can be sparse/absent on some builds. Returns the pane_ids that transitioned
    /// INTO `blocked` (so the UI can auto-expand + play a sound), matching `apply`.
    @discardableResult
    public func reconcile(_ snapshot: Snapshot) -> [String] {
        reconcileTransitions(snapshot).newlyBlockedPaneIDs
    }

    /// Detailed snapshot transition evidence used by UI side effects. Keeping
    /// this alongside the compatibility `reconcile` result prevents polling and
    /// events from developing different definitions of "finished".
    @discardableResult
    public func reconcileTransitions(_ snapshot: Snapshot) -> StateTransitionResult {
        let finishedBefore = finishedUnseen
        var didChange = false
        // Topology first: add new panes, drop vanished ones, refresh tab/workspace.
        let fresh = snapshot.uniquePanes
        let freshIDs = Set(fresh.map(\.paneID))
        for gone in Set(panes.keys).subtracting(freshIDs) {
            remove(gone)
            didChange = true
        }
        var newTabs: [String: TabInfo] = [:]
        for t in snapshot.tabs { newTabs[t.tabID] = t }
        if tabs != newTabs {
            tabs = newTabs
            didChange = true
        }
        var newWorkspaces: [String: WorkspaceInfo] = [:]
        for w in snapshot.workspaces { newWorkspaces[w.workspaceID] = w }
        if workspaces != newWorkspaces {
            workspaces = newWorkspaces
            didChange = true
        }
        if focusedPaneID != snapshot.focusedPaneID {
            focusedPaneID = snapshot.focusedPaneID
            didChange = true
        }

        var newlyBlocked: [String] = []
        for pane in fresh {
            let previousPane = panes[pane.paneID]
            let previous = previousPane?.agentStatus
            // Store the full fresh record (keeps cwd/agent/label fresh too).
            if previousPane != pane {
                panes[pane.paneID] = pane
                didChange = true
            }
            if previous != pane.agentStatus {
                applyTransition(paneID: pane.paneID, from: previous, to: pane.agentStatus)
                if pane.agentStatus == .blocked && previous != .blocked {
                    newlyBlocked.append(pane.paneID)
                }
            } else if pane.agentStatus == .working && workingSince[pane.paneID] == nil {
                workingSince[pane.paneID] = now()
                didChange = true
            } else if pane.agentStatus == .blocked && blockedSince[pane.paneID] == nil {
                blockedSince[pane.paneID] = now()
                didChange = true
            }
        }
        if didChange { bump() }
        return StateTransitionResult(
            newlyBlockedPaneIDs: newlyBlocked,
            newlyFinishedPaneIDs: Array(finishedUnseen.subtracting(finishedBefore)))
    }

    // MARK: Event application

    /// Apply one pushed event envelope. Safe to call with any event; unknown
    /// events are ignored. Returns true if a pane transitioned INTO `blocked`
    /// (the UI uses this to auto-expand).
    @discardableResult
    public func apply(_ event: EventEnvelope) -> Bool {
        !applyTransitions(event).newlyBlockedPaneIDs.isEmpty
    }

    @discardableResult
    public func applyTransitions(_ event: EventEnvelope) -> StateTransitionResult {
        let finishedBefore = finishedUnseen
        let didBlock = applyEvent(event)
        return StateTransitionResult(
            newlyBlockedPaneIDs: didBlock ? event.paneID.map { [$0] } ?? [] : [],
            newlyFinishedPaneIDs: Array(finishedUnseen.subtracting(finishedBefore)))
    }

    private func applyEvent(_ event: EventEnvelope) -> Bool {
        switch event.event {
        case "pane_agent_status_changed":
            return applyStatusChange(event)
        case "pane_created", "pane_focused", "pane_moved":
            if let pane = event.pane { upsert(pane) }
            if event.event == "pane_focused", let id = event.paneID {
                focusedPaneID = id
                // Viewing a finished pane clears its done badge.
                clearFinished(id)
            }
            bump()
            return false
        case "pane_agent_detected":
            // Upsert if the event carried a full pane body; if it only carried a
            // pane_id for a pane we don't know yet, we can't synthesize a record
            // without required fields — the next snapshot/status event will fill it.
            if let pane = event.pane { upsert(pane) }
            bump()
            return false
        case "pane_exited", "pane_closed":
            if let id = event.paneID { remove(id) }
            bump()
            return false
        case "pane_output_matched":
            if let id = event.paneID { outputMatched.insert(id) }
            bump()
            return false
        default:
            return false
        }
    }

    private func applyStatusChange(_ event: EventEnvelope) -> Bool {
        guard let id = event.paneID, let status = event.agentStatus else { return false }
        let previous = panes[id]?.agentStatus

        // Update the stored pane's status (create a shell if we don't have it yet).
        if var pane = panes[id] {
            pane = pane.with(agentStatus: status)
            panes[id] = pane
        }

        applyTransition(paneID: id, from: previous, to: status)
        bump()
        return status == .blocked && previous != .blocked
    }

    /// Update derived state (finishedUnseen / workingSince / outputMatched) for a
    /// single pane's status transition. Shared by live events and snapshot
    /// reconciliation so both compute `done`/`blocked` identically.
    private func applyTransition(paneID id: String, from previous: AgentStatus?, to status: AgentStatus) {
        switch status {
        case .working:
            finishedUnseen.remove(id)
            outputMatched.remove(id)
            blockedSince[id] = nil
            if workingSince[id] == nil { workingSince[id] = now() }
        case .blocked:
            finishedUnseen.remove(id)
            workingSince[id] = nil
            if blockedSince[id] == nil { blockedSince[id] = now() }
        case .idle:
            workingSince[id] = nil
            blockedSince[id] = nil
            // working → idle means the agent finished a task: mark done-unseen
            // (unless the user is already looking at it).
            if previous == .working && focusedPaneID != id {
                finishedUnseen.insert(id)
            }
        case .done:
            // Rollup-level status: treat as finished-unseen.
            workingSince[id] = nil
            blockedSince[id] = nil
            if focusedPaneID != id { finishedUnseen.insert(id) }
        case .unknown:
            workingSince[id] = nil
            blockedSince[id] = nil
        }
    }

    // MARK: Acknowledgement

    /// Mark a finished pane as viewed, clearing its `done` badge.
    public func acknowledge(_ paneID: String) {
        clearFinished(paneID)
    }

    private func clearFinished(_ paneID: String) {
        if finishedUnseen.remove(paneID) != nil { bump() }
    }

    // MARK: Derived status & rollups

    /// The UI-facing status for a single pane, including derived `done`.
    public func derivedStatus(forPane paneID: String) -> RollupStatus {
        guard let pane = panes[paneID] else { return .unknown }
        switch pane.agentStatus {
        case .blocked: return .blocked
        case .working: return .working
        case .done: return .done
        case .idle, .unknown:
            if finishedUnseen.contains(paneID) { return .done }
            return pane.agentStatus == .idle ? .idle : .unknown
        }
    }

    public func rollup(forTab tabID: String) -> RollupStatus {
        let statuses = panes.values
            .filter { $0.tabID == tabID }
            .map { derivedStatus(forPane: $0.paneID) }
        return RollupStatus.rollup(statuses)
    }

    public func rollup(forWorkspace workspaceID: String) -> RollupStatus {
        let statuses = panes.values
            .filter { $0.workspaceID == workspaceID }
            .map { derivedStatus(forPane: $0.paneID) }
        return RollupStatus.rollup(statuses)
    }

    /// Worst status across all panes — drives the collapsed pill color.
    public var overallStatus: RollupStatus {
        RollupStatus.rollup(panes.keys.map { derivedStatus(forPane: $0) })
    }

    /// Panes currently `blocked` (the ones that need the user).
    public var blockedPanes: [PaneInfo] {
        panes.values.filter { $0.agentStatus == .blocked }
            .sorted { $0.paneID < $1.paneID }
    }

    /// Soft-signal: panes working longer than `threshold` seconds (maybe stuck).
    public func possiblyStuckPanes(threshold: TimeInterval, now: Date = Date()) -> [String] {
        workingSince.compactMap { id, since in
            now.timeIntervalSince(since) >= threshold ? id : nil
        }.sorted()
    }

    // MARK: Subscription derivation (for the client's reconnect closure)

    /// The subscription set for the current panes: per-pane status changes plus
    /// the global lifecycle events. Passed to `HerdrClient.events` so it's
    /// re-derived on every (re)connect and after new panes appear.
    ///
    /// IMPORTANT: herdr validates the **whole** subscribe batch — one malformed
    /// entry makes it reject *everything* with `invalid_request`, so no events
    /// flow at all. Only include subscription types whose required fields we
    /// supply here:
    /// - `pane.agent_status_changed` requires `pane_id` (per-pane).
    /// - `pane.created` / `pane.exited` / `pane.agent_detected` need only `type`.
    /// - `pane.output_matched` is intentionally OMITTED: herdr requires it to be
    ///   per-pane AND to carry a `source` field, which we don't model. It's only a
    ///   soft "maybe stuck" signal; subscribing to it wrong previously broke the
    ///   entire event stream (the pill never updated). Add it back only as a
    ///   per-pane sub with a valid `source` if/when we consume it.
    /// - Parameter includePerPaneStatus: whether to subscribe to each pane's
    ///   status. Pass `false` for a background or remote session — see below.
    ///
    /// **Per-pane status subscriptions are not free.** herdr's subscribe loop runs
    /// every 100ms, and `ActiveAgentStatusChangedSubscription` falls back to a
    /// `pane_get` for its pane whenever the event hub is quiet — so N subscribed
    /// panes cost herdr N reads ten times a second, per connected client. The
    /// global lifecycle subscriptions below are plain event-hub reads and cost
    /// nothing extra.
    ///
    /// Dropping the per-pane entries therefore makes a background session nearly
    /// free while losing only latency, never correctness: status still arrives on
    /// the snapshot poll, which is the primary path anyway.
    public func currentSubscriptions(includePerPaneStatus: Bool = true) -> [Subscription] {
        var subs = includePerPaneStatus
            ? panes.keys.sorted().map {
                Subscription(type: "pane.agent_status_changed", paneID: $0)
            }
            : []
        subs.append(Subscription(type: "pane.agent_detected"))
        subs.append(Subscription(type: "pane.created"))
        subs.append(Subscription(type: "pane.exited"))
        return subs
    }

    // MARK: Internals

    private func upsert(_ pane: PaneInfo) {
        panes[pane.paneID] = pane
        switch pane.agentStatus {
        case .working:
            blockedSince[pane.paneID] = nil
            if workingSince[pane.paneID] == nil { workingSince[pane.paneID] = now() }
        case .blocked:
            workingSince[pane.paneID] = nil
            if blockedSince[pane.paneID] == nil { blockedSince[pane.paneID] = now() }
        case .idle, .done, .unknown:
            workingSince[pane.paneID] = nil
            blockedSince[pane.paneID] = nil
        }
    }

    private func remove(_ paneID: String) {
        panes[paneID] = nil
        finishedUnseen.remove(paneID)
        outputMatched.remove(paneID)
        workingSince[paneID] = nil
        blockedSince[paneID] = nil
    }

    private func bump() { revision += 1 }
}

extension PaneInfo {
    /// Return a copy with a new agent status (events carry status without a full body).
    func with(agentStatus: AgentStatus) -> PaneInfo {
        PaneInfo(paneID: paneID, terminalID: terminalID, workspaceID: workspaceID,
                 tabID: tabID, focused: focused, agentStatus: agentStatus, revision: revision,
                 agent: agent, displayAgent: displayAgent, customStatus: customStatus,
                 label: label, title: title, cwd: cwd, foregroundCwd: foregroundCwd,
                 scroll: scroll)
    }
}
