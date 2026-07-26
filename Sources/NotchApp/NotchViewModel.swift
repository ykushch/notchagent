import AppKit
import Foundation
import HerdrClient
import Observation

struct NotchDisplaySnapshot: Sendable {
    let items: [InteractionAttentionDisplayModel]
    let selectedItem: InteractionAttentionDisplayModel?
}

struct JumpNotice: Sendable, Equatable {
    let text: String
    let attachCommand: String?
}

/// Observable view-model backing the notch UI (specs 08/09).
///
/// Single source of truth for what the SwiftUI content shows. Owns a
/// `SessionRegistry` — one `SessionRuntime` per herdr server — and turns what the
/// runtimes report into presentation: sounds, auto-expand, and the selected card.
/// Every decision that can move the notch lives here rather than in a runtime, so
/// a background session finishing can never stomp the card the user is reading.
///
/// Panes are addressed by `AgentRef`, never by bare pane id: `w1:p1` exists on
/// every session and every host.
@Observable
@MainActor
final class NotchViewModel {
    // MARK: Presentation

    var presentation: NotchPresentation = .compact
    var isExpanded: Bool { presentation.isExpanded }

    // MARK: Live state

    let registry = SessionRegistry()

    /// Local discovery is cheap; remote discovery opens an SSH command channel and
    /// therefore runs much less often.
    private static let localDiscoveryInterval: UInt64 = 10_000_000_000
    private static let localRefreshesPerRemoteRefresh = 6

    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    /// Set when the app was configured with an explicit socket, which pins the
    /// notch to exactly that server instead of discovering sessions.
    @ObservationIgnored private var pinnedSession: ResolvedSession?

    /// Selection is derived from the runtimes rather than mirrored, so it cannot
    /// drift from the coordinators that actually drive refresh priority.
    var selected: AgentRef? {
        for runtime in registry.runtimes {
            if let paneID = runtime.interactions.selectedPaneID {
                return AgentRef(sessionID: runtime.sessionID, paneID: paneID)
            }
        }
        return nil
    }

    var selectedRuntime: SessionRuntime? { selected.flatMap { registry.runtime(for: $0) } }

    var selectedInteractionState: PaneInteractionState? {
        selectedRuntime?.interactions.selectedState
    }
    var selectedInteraction: PendingInteraction? {
        selectedInteractionState?.interaction
    }
    var selectedInteractionSizingIdentity: String? {
        guard let selected else { return nil }
        let fingerprint = selectedInteraction?.fingerprint.rawValue ?? "none"
        return "\(selected.id):\(fingerprint)"
    }

    var attentionItems: [InteractionAttentionDisplayModel] {
        attentionItems(at: Date())
    }

    func attentionItems(at now: Date) -> [InteractionAttentionDisplayModel] {
        let selected = selected
        let showSessionBadges = registry.runtimes.count > 1
        var rows: [(rank: Int?, model: InteractionAttentionDisplayModel)] = []
        for runtime in registry.runtimes {
            let store = runtime.store
            let interactions = runtime.interactions
            let attentionRank = Dictionary(uniqueKeysWithValues:
                interactions.attentionOrder.enumerated().map { ($0.element, $0.offset) })
            for pane in runtime.displayablePanes {
                let workspaceLabel = store.workspaces[pane.workspaceID]?.label
                let spaceTitle = PaneDisplayIdentity.spaceTitle(
                    pane: pane, workspaceLabel: workspaceLabel)
                let tab = store.tabs[pane.tabID]
                let status = store.derivedStatus(forPane: pane.paneID)
                let activeSince = status == .working
                    ? store.workingSince[pane.paneID]
                    : status == .blocked ? store.blockedSince[pane.paneID] : nil
                let model = InteractionAttentionDisplayModel(
                    paneID: pane.paneID,
                    sessionID: runtime.sessionID,
                    sessionLabel: showSessionBadges ? runtime.descriptor.label : nil,
                    isRemote: runtime.descriptor.isRemote,
                    taskTitle: PaneDisplayIdentity.taskTitle(
                        pane: pane, workspaceLabel: workspaceLabel),
                    agentName: pane.displayAgent ?? pane.agent ?? "agent",
                    modelName: PaneDisplayIdentity.modelBadge(pane: pane),
                    workspaceLabel: spaceTitle,
                    tabTitle: PaneDisplayIdentity.tabTitle(
                        label: tab?.label, number: tab?.number),
                    status: status,
                    state: interactions.state(for: pane.paneID),
                    completionSummary: interactions.completionSummary(for: pane.paneID),
                    activeSince: activeSince, now: now,
                    isSelected: selected?.paneID == pane.paneID
                        && selected?.sessionID == runtime.sessionID)
                rows.append((attentionRank[pane.paneID], model))
            }
        }
        // Panes the coordinator has ranked float to the top in that order; the rest
        // sort by urgency, then by ref so ordering stays stable across sessions.
        return rows.sorted { left, right in
            if let leftRank = left.rank, let rightRank = right.rank {
                if leftRank != rightRank { return leftRank < rightRank }
                return left.model.id < right.model.id
            }
            if left.rank != nil { return true }
            if right.rank != nil { return false }
            if left.model.status.precedence != right.model.status.precedence {
                return left.model.status.precedence > right.model.status.precedence
            }
            return left.model.id < right.model.id
        }.map(\.model)
    }

    func displaySnapshot(at now: Date) -> NotchDisplaySnapshot {
        let items = attentionItems(at: now)
        return NotchDisplaySnapshot(
            items: items,
            selectedItem: selected.flatMap { ref in items.first { $0.ref == ref } })
    }

    /// Rollup status of the currently-selected pane, for the card header.
    var selectedStatus: RollupStatus? {
        guard let selected, let runtime = registry.runtime(for: selected) else { return nil }
        return runtime.store.derivedStatus(forPane: selected.paneID)
    }

    var selectedAgentSupportsModeCycling: Bool {
        guard let selected, let runtime = registry.runtime(for: selected) else { return false }
        return runtime.supportsModeCycling(paneID: selected.paneID)
    }

    var selectedAgentMode: AgentMode? {
        guard let selected, let runtime = registry.runtime(for: selected) else { return nil }
        return runtime.agentModesByPane[selected.paneID]
    }

    var canCycleSelectedAgentMode: Bool {
        selectedAgentSupportsModeCycling && connection == .connected && !isActing
    }

    /// Per-pane draft projection. Switching panes never overwrites another draft.
    var replyText: String {
        get {
            guard let selected, let runtime = registry.runtime(for: selected) else { return "" }
            return runtime.interactions.draftText(for: selected.paneID)
        }
        set {
            guard let selected, let runtime = registry.runtime(for: selected) else { return }
            _ = runtime.interactions.setDraftText(newValue, paneID: selected.paneID)
            markUserEngaged()
        }
    }

    var lastError: String? {
        get {
            if let state = selectedInteractionState, let error = state.error { return error }
            if let runtime = selectedRuntime { return runtime.error }
            // No selection: report the first session that is actually unhappy, so a
            // single unreachable session doesn't stay silent. A failed SSH tunnel
            // is reported ahead of a session error because it is the actionable
            // cause — "herdr isn't running" would send the user looking in the
            // wrong place entirely.
            return registry.pendingTunnelMessages.first
                ?? registry.runtimes.compactMap(\.error).first
                ?? registry.discoveryError
        }
        set {
            if let selected, let runtime = registry.runtime(for: selected) {
                runtime.setError(newValue, paneID: selected.paneID)
            } else {
                registry.runtimes.first?.error = newValue
            }
        }
    }

    /// True once the accessibility permission needed for global hotkeys is known
    /// to be missing (spec 09 surfaces a hint instead of silently failing).
    var accessibilityMissing: Bool = false
    private(set) var jumpNotice: JumpNotice?
    /// Confirms the brew command landed on the pasteboard, same idea as the
    /// jump notice's "Attach command copied."
    private(set) var updateCommandCopied = false

    typealias Connection = SessionRuntime.Connection

    /// The best state across sessions: connected if any session is live. One
    /// unreachable named session must not blank out a working notch.
    var connection: Connection {
        let states = registry.runtimes.map(\.connection)
        if states.contains(.connected) { return .connected }
        if states.contains(.connecting) || states.isEmpty { return .connecting }
        return .unavailable
    }

    /// Optional sound engine + settings (injected by the app). The store is the
    /// source of truth; these are side-effects on state transitions.
    @ObservationIgnored var soundEngine: SoundEngine?
    @ObservationIgnored var settings: Settings?
    /// Update state lives in its own observable object; reading through this
    /// reference inside a view body still tracks the checker's own changes.
    @ObservationIgnored var updateChecker: UpdateChecker?

    /// The configured hotkey modifier symbols (e.g. "^⌥") for UI hints. Falls back
    /// to "^⌥" if settings aren't wired yet.
    var hotkeySymbols: String { settings?.hotkeyModifier.symbols ?? "^⌥" }

    // MARK: Derived summary for the collapsed pill

    /// Worst status across all agents in all sessions — drives the pill color.
    var overallStatus: RollupStatus {
        registry.runtimes.map(\.store.overallStatus)
            .max(by: { $0.precedence < $1.precedence }) ?? .unknown
    }

    /// Count of agents needing attention (blocked) for the pill badge.
    var attentionCount: Int {
        registry.runtimes.reduce(0) { $0 + $1.blockedPaneCount }
    }

    /// Total agent count (panes with a known agent) for the pill.
    var agentCount: Int {
        registry.runtimes.reduce(0) { $0 + $1.agentCount }
    }

    var hasAttention: Bool { attentionCount > 0 || overallStatus == .blocked }
    var hasWorkingPanes: Bool { registry.runtimes.contains { $0.hasWorkingPanes } }

    /// Project/session title for the selected blocked pane, otherwise the most
    /// urgent blocked pane. Nil preserves the compact count-only idle pill.
    var pillTaskTitle: String? {
        guard hasAttention else { return nil }
        return AttentionRollupDisplay.pillTaskTitle(items: attentionItems, selected: selected)
    }

    var isActing: Bool { selectedRuntime?.isActing == true }

    // MARK: Init

    /// A resolved session pins the notch to one server. Passing nil lets the app
    /// discover and track every running local session.
    init(pinnedSession: ResolvedSession? = nil) {
        self.pinnedSession = pinnedSession
    }

    /// Re-point at a new socket (session switch, spec 10c) and restart the loops.
    func reconnect(pinnedSession: ResolvedSession?) {
        stop()
        self.pinnedSession = pinnedSession
        registry.apply([])
        start()
    }

    // MARK: Lifecycle

    func start() {
        registry.start(host: self)
        if let pinnedSession {
            registry.apply([pinnedSession])
            return
        }
        startDiscoveryLoop()
    }

    /// Apply Settings changes promptly instead of waiting for the slower remote
    /// discovery cadence. Cancellation guards in the registry prevent an older
    /// lookup from reconciling after this new configuration.
    func remoteHostsDidChange() {
        guard pinnedSession == nil else { return }
        discoveryTask?.cancel()
        startDiscoveryLoop()
    }

    private func startDiscoveryLoop() {
        discoveryTask = Task { @MainActor in
            while !Task.isCancelled {
                await registry.refresh(remoteHosts: settings?.remoteHosts ?? [])
                for _ in 1..<Self.localRefreshesPerRemoteRefresh {
                    try? await Task.sleep(nanoseconds: Self.localDiscoveryInterval)
                    guard !Task.isCancelled else { return }
                    await registry.refreshLocalSessions()
                }
                try? await Task.sleep(nanoseconds: Self.localDiscoveryInterval)
            }
        }
    }

    func stop() {
        discoveryTask?.cancel()
        discoveryTask = nil
        registry.stop()
    }

    // MARK: Selection

    /// Read + classify a blocked pane and surface it in an auto-expanded card.
    func surfaceBlockedPane(_ ref: AgentRef) async {
        await select(ref)
        presentation = .focused(NotchFocusContext(
            origin: .automatic, hasUserEngaged: false))
        registry.refreshEventSubscriptionPolicies()
    }

    /// Selecting anywhere clears the selection everywhere else — exactly one pane
    /// is on the card, and the other coordinators must drop their refresh priority.
    private func select(_ ref: AgentRef) async {
        for runtime in registry.runtimes where runtime.sessionID != ref.sessionID {
            runtime.clearSelection()
        }
        await registry.runtime(for: ref)?.select(paneID: ref.paneID)
        registry.refreshEventSubscriptionPolicies()
    }

    func selectPane(_ ref: AgentRef) {
        if selected == ref, presentation.isFocused {
            showOverview()
            return
        }
        Task { @MainActor in
            await select(ref)
            presentation = .focused(NotchFocusContext(
                origin: .manual, hasUserEngaged: true))
            registry.refreshEventSubscriptionPolicies()
        }
    }

    func selectAdjacentPane(_ delta: Int) {
        let items = attentionItems
        guard !items.isEmpty else { return }
        let current = selected.flatMap { ref in
            items.firstIndex(where: { $0.ref == ref })
        } ?? (delta > 0 ? -1 : 0)
        let next = (current + delta + items.count) % items.count
        let ref = items[next].ref
        Task { @MainActor in
            await select(ref)
            presentation = .focused(NotchFocusContext(
                origin: .manual, hasUserEngaged: true))
            registry.refreshEventSubscriptionPolicies()
        }
    }

    func toggle() { isExpanded ? collapse() : showOverview() }
    func expand() { showOverview() }
    func showOverview() {
        clearAllSelections()
        presentation = .overview
    }
    func collapse() {
        presentation = .compact
        registry.refreshEventSubscriptionPolicies()
    }
    func clearSelection() {
        showOverview()
    }

    private func clearAllSelections() {
        for runtime in registry.runtimes { runtime.clearSelection() }
        registry.refreshEventSubscriptionPolicies()
    }

    private func markUserEngaged() {
        presentation.markUserEngaged()
    }

    private func synchronizePresentationAfterInteractionReconcile(
        runtime: SessionRuntime, selectedBefore: String?
    ) {
        guard let selectedBefore, selected == nil else { return }
        guard runtime.store.panes[selectedBefore] == nil || presentation.isFocused else { return }
        presentation = presentation.fallbackAfterFocusedPaneEnds
    }

    private func handleSelectedPaneResolutionIfNeeded() {
        guard let selected, let runtime = registry.runtime(for: selected),
              runtime.store.derivedStatus(forPane: selected.paneID) != .blocked,
              case .focused(let context) = presentation,
              context.origin == .automatic
        else { return }
        runtime.clearSelection()
        presentation = context.hasUserEngaged ? .overview : .compact
    }

    // MARK: Actions

    func approveSelected() {
        respondToSelectedInteraction(.approve)
    }
    func denySelected() {
        guard let interaction = selectedInteraction else { return }
        respondToSelectedInteraction(interaction.kind == .approval ? .deny : .cancel)
    }
    func answerSelected(index: Int) {
        respondToSelectedInteraction(
            selectedInteraction?.presentation.selectedChoicePreview == nil
                ? .selectChoice(index) : .previewChoice(index))
    }
    func replySelected() {
        guard let selected else { return }
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let interaction = selectedInteraction,
           interaction.kind != .unknown, interaction.kind != .freeText {
            guard interaction.presentation.mechanism == .textEntry else {
                lastError = "Open this interaction's text field before submitting text."
                return
            }
            respondToSelectedInteraction(.submitText(text))
            return
        }
        runManualAction { await $0.reply(paneID: selected.paneID, text: text) }
    }
    func confirmSelectedDraftReuse() {
        guard let selected, let runtime = registry.runtime(for: selected) else { return }
        markUserEngaged()
        _ = runtime.interactions.confirmDraftReuse(paneID: selected.paneID)
    }
    func discardSelectedDraft() {
        guard let selected, let runtime = registry.runtime(for: selected) else { return }
        markUserEngaged()
        runtime.interactions.discardDraft(paneID: selected.paneID)
    }
    /// Explicit manual typing for partially supported normalized interactions.
    /// It does not press Enter; the user remains in control of submission.
    func typeTextWithoutSubmitSelected() {
        guard let selected else { return }
        let text = replyText
        guard !text.isEmpty else { return }
        runManualAction { await $0.reply(paneID: selected.paneID, text: text, submit: false) }
    }
    func sendManualTextSelected() {
        guard let selected else { return }
        let text = replyText
        guard !text.isEmpty else { return }
        runManualAction { await $0.reply(paneID: selected.paneID, text: text) }
    }
    func submitTextOption(index: Int, text: String) {
        guard !text.isEmpty else { return }
        respondToSelectedInteraction(.submitChoiceText(index, text))
    }
    func navigateToStep(_ index: Int) {
        respondToSelectedInteraction(.navigateToStep(index))
    }
    func navigateStep(_ delta: Int) {
        guard selectedInteraction?.capabilities.contains(.navigateSteps) == true else { return }
        respondToSelectedInteraction(delta < 0 ? .navigatePrevious : .navigateNext)
    }
    func sendArrowToSelected(_ key: String) { sendRawKeysSelected([key]) }
    func cycleSelectedAgentMode() {
        guard canCycleSelectedAgentMode, let selected,
              let runtime = registry.runtime(for: selected) else { return }
        markUserEngaged()
        Task { @MainActor in
            await runtime.cycleAgentMode(paneID: selected.paneID)
        }
    }
    func sendRawKeysSelected(_ keys: [String]) {
        guard let selected else { return }
        runManualAction { await $0.sendRawKeys(paneID: selected.paneID, keys: keys) }
    }

    /// The only entry point for structured UI actions. The responder re-reads
    /// and validates stable identity before it can execute any operation.
    func respondToSelectedInteraction(_ intent: InteractionResponseIntent) {
        guard let selected, let runtime = registry.runtime(for: selected) else { return }
        markUserEngaged()
        Task { @MainActor in
            await runtime.respond(paneID: selected.paneID, intent: intent)
        }
    }

    /// Routes a manual action to the runtime that owns the current selection —
    /// never to a runtime that merely has a pane with the same id.
    private func runManualAction(
        _ body: @escaping @MainActor (SessionRuntime) async -> Void
    ) {
        guard let selected, let runtime = registry.runtime(for: selected) else { return }
        markUserEngaged()
        Task { @MainActor in await body(runtime) }
    }

    // MARK: Jump

    func jumpSelected() { if let selected { jump(selected) } }
    func jump(_ ref: AgentRef) {
        guard let runtime = registry.runtime(for: ref) else { return }
        if ref == selected { markUserEngaged() }
        let terminalID = runtime.store.panes[ref.paneID]?.terminalID
        let presenter = TerminalActivator(
            selection: settings?.terminalSelection ?? .automatic())
        Task { @MainActor in
            do {
                let result = try await runtime.jump(paneID: ref.paneID, presenter: presenter)
                handleJumpResult(
                    result, terminalID: terminalID, descriptor: runtime.descriptor)
            }
            catch {
                let message = "Couldn't jump to this agent: \(String(describing: error))"
                runtime.setError(message, paneID: ref.paneID)
                jumpNotice = JumpNotice(text: message, attachCommand: nil)
            }
        }
    }

    func copyJumpAttachCommand() {
        guard let command = jumpNotice?.attachCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        jumpNotice = JumpNotice(text: "Attach command copied.", attachCommand: command)
    }

    func dismissJumpNotice() {
        jumpNotice = nil
    }

    private func handleJumpResult(
        _ result: ActionResult, terminalID: String?, descriptor: SessionDescriptor
    ) {
        switch result {
        case .sent:
            break
        case .jumped(.presented):
            jumpNotice = nil
        case .jumped(.unavailable(let failure)):
            jumpNotice = JumpNotice(text: jumpFailureMessage(failure), attachCommand: nil)
        case .needsAttach:
            // The focus reached the server — for a remote session that means the
            // agent is now focused on the far host, and what the user needs is the
            // command that opens it here.
            jumpNotice = JumpNotice(
                text: descriptor.isRemote
                    ? "Focused on \(descriptor.label), but no terminal here is attached to it."
                    : "No Herdr terminal is attached. Attach a terminal to open this agent.",
                attachCommand: descriptor.isRemote
                    ? descriptor.attachCommand
                    : terminalID.map { "herdr terminal attach \($0)" })
        }
    }

    private func jumpFailureMessage(_ failure: TerminalPresentationFailure) -> String {
        switch failure {
        case .noSupportedTerminalRunning:
            "Agent focused in Herdr, but no supported terminal is running. Choose a terminal in Settings."
        case .ambiguous(let appNames):
            "Agent focused in Herdr, but multiple terminals are running (\(appNames.joined(separator: ", "))). Choose one in Settings."
        case .applicationUnavailable(let appName):
            "Agent focused in Herdr, but \(appName) could not be opened. Check the terminal setting."
        }
    }

    // MARK: Updates

    var pendingUpdate: UpdateManifest? { updateChecker?.pendingUpdate }
    var updateAdvice: UpdateAdvice.Guidance? { updateChecker?.advice }

    func copyUpdateCommand() {
        guard let command = updateAdvice?.command else { return }
        UpdateActions.copy(command)
        updateCommandCopied = true
    }

    func openUpdateLink() {
        guard let link = updateAdvice?.primaryLink else { return }
        UpdateActions.open(link)
    }

    func skipPendingUpdate() {
        updateChecker?.skipPendingUpdate()
        updateCommandCopied = false
    }
}

// MARK: - SessionRuntimeHost

extension NotchViewModel: SessionRuntimeHost {
    var isNotchExpanded: Bool { isExpanded }
    var preservesResolvedSelection: Bool { presentation.preservesResolvedSelection }

    /// Every row is visible in overview, while focused detail shows only its
    /// selected session. A single session preserves the original fast cadence.
    func isVisibleSession(_ runtime: SessionRuntime) -> Bool {
        if registry.runtimes.count <= 1 { return true }
        switch presentation {
        case .compact:
            return false
        case .overview:
            return true
        case .focused:
            return selected?.sessionID == runtime.sessionID
        }
    }

    /// Per-pane status subscriptions are much more expensive than snapshots, so
    /// only focused detail earns them in multi-session mode.
    func usesPerPaneStatusSubscriptions(_ runtime: SessionRuntime) -> Bool {
        if registry.runtimes.count <= 1 { return true }
        return presentation.isFocused && selected?.sessionID == runtime.sessionID
    }

    /// Every presentation side-effect for a reconciled session lands here, so the
    /// runtimes stay free of UI policy — and so a background session cannot move
    /// the notch out from under the session the user is looking at.
    func sessionRuntime(
        _ runtime: SessionRuntime,
        didObserve transitions: SessionRuntime.Transitions
    ) async {
        for _ in transitions.newlyBlockedPaneIDs {
            soundEngine?.play(.blocked)
        }
        for _ in transitions.newlyFinishedPaneIDs {
            soundEngine?.play(.done)
        }
        if presentation.allowsAutomaticFocus,
           !transitions.newlyBlockedPaneIDs.isEmpty,
           let target = runtime.interactions.attentionOrder.first {
            await surfaceBlockedPane(
                AgentRef(sessionID: runtime.sessionID, paneID: target))
        }
        if !transitions.newlyFinishedPaneIDs.isEmpty,
           settings?.autoExpandOnDone ?? false,
           presentation.allowsAutomaticOverview {
            showOverview()
        }
        // If an AUTO-surfaced blocked pane resolved (no longer blocked), clear the
        // card. But leave a MANUALLY-opened pane alone — the user opened it
        // deliberately (e.g. to read/jump an idle agent) and it should stay until
        // they close it.
        synchronizePresentationAfterInteractionReconcile(
            runtime: runtime, selectedBefore: transitions.selectedPaneIDBefore)
        handleSelectedPaneResolutionIfNeeded()
        registry.refreshEventSubscriptionPolicies()
    }
}
