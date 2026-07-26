import Testing
@testable import HerdrClient

@Suite("Adaptive snapshot polling")
struct SnapshotPollingPolicyTests {
    @Test("activity, attention, and recovery select bounded cadences")
    func cadence() {
        #expect(SnapshotPollingPolicy.nanoseconds(
            isExpanded: false, hasBlockedPanes: false,
            hasWorkingPanes: false, isUnavailable: false) == 2_500_000_000)
        #expect(SnapshotPollingPolicy.nanoseconds(
            isExpanded: false, hasBlockedPanes: false,
            hasWorkingPanes: true, isUnavailable: false) == 1_200_000_000)
        #expect(SnapshotPollingPolicy.nanoseconds(
            isExpanded: false, hasBlockedPanes: true,
            hasWorkingPanes: false, isUnavailable: false) == 650_000_000)
        #expect(SnapshotPollingPolicy.nanoseconds(
            isExpanded: true, hasBlockedPanes: false,
            hasWorkingPanes: false, isUnavailable: false) == 650_000_000)
        #expect(SnapshotPollingPolicy.nanoseconds(
            isExpanded: true, hasBlockedPanes: true,
            hasWorkingPanes: true, isUnavailable: true) == 1_000_000_000)
    }

    @Test("background and remote sessions back off, but are never parked")
    func multiSessionCadence() {
        func cadence(_ context: SnapshotPollingPolicy.SessionContext) -> UInt64 {
            SnapshotPollingPolicy.nanoseconds(
                isExpanded: false, hasBlockedPanes: false,
                hasWorkingPanes: false, isUnavailable: false, context: context)
        }
        let foregroundLocal = cadence(.visibleLocal)
        let foregroundRemote = cadence(.init(isVisible: true, isRemote: true))
        let backgroundLocal = cadence(.init(isVisible: false, isRemote: false))
        let backgroundRemote = cadence(.init(isVisible: false, isRemote: true))

        // Cost ordering: local+foreground cheapest to observe, remote+background
        // most expensive (every poll is an SSH round-trip nobody is watching).
        #expect(foregroundLocal < backgroundLocal)
        #expect(foregroundLocal < foregroundRemote)
        #expect(backgroundLocal < backgroundRemote)
        // Still polled: noticing a NEW block on a background session is the entire
        // point of tracking it, so no cadence may be unbounded.
        #expect(backgroundRemote < 10_000_000_000)
    }

    @Test("an expanded notch does not speed up hidden sessions")
    func expansionOnlyHelpsVisibleSessions() {
        let background = SnapshotPollingPolicy.SessionContext(
            isVisible: false, isRemote: false)
        #expect(SnapshotPollingPolicy.nanoseconds(
            isExpanded: true, hasBlockedPanes: false, hasWorkingPanes: false,
            isUnavailable: false, context: background)
            == SnapshotPollingPolicy.nanoseconds(
                isExpanded: false, hasBlockedPanes: false, hasWorkingPanes: false,
                isUnavailable: false, context: background))
    }

    @Test("every visible overview row gets the expanded cadence")
    func expandedOverviewStaysFresh() {
        let local = SnapshotPollingPolicy.nanoseconds(
            isExpanded: true, hasBlockedPanes: false, hasWorkingPanes: false,
            isUnavailable: false, context: .init(isVisible: true, isRemote: false))
        let remote = SnapshotPollingPolicy.nanoseconds(
            isExpanded: true, hasBlockedPanes: false, hasWorkingPanes: false,
            isUnavailable: false, context: .init(isVisible: true, isRemote: true))
        #expect(local == 650_000_000)
        #expect(remote == 1_300_000_000)
    }

    @Test("a blocked pane still gets the fast cadence in the background")
    func blockedBackgroundStaysResponsive() {
        let background = SnapshotPollingPolicy.SessionContext(isVisible: false)
        let blocked = SnapshotPollingPolicy.nanoseconds(
            isExpanded: false, hasBlockedPanes: true, hasWorkingPanes: false,
            isUnavailable: false, context: background)
        let idle = SnapshotPollingPolicy.nanoseconds(
            isExpanded: false, hasBlockedPanes: false, hasWorkingPanes: false,
            isUnavailable: false, context: background)
        #expect(blocked < idle)
    }

    @Test("the default context preserves the single-session cadence exactly")
    func defaultContextIsUnchanged() {
        // Existing behaviour must not shift for anyone tracking one session.
        for (expanded, blocked, working, unavailable) in [
            (false, false, false, false), (false, false, true, false),
            (false, true, false, false), (true, false, false, false),
            (true, true, true, true),
        ] {
            #expect(SnapshotPollingPolicy.nanoseconds(
                isExpanded: expanded, hasBlockedPanes: blocked,
                hasWorkingPanes: working, isUnavailable: unavailable)
                == SnapshotPollingPolicy.nanoseconds(
                    isExpanded: expanded, hasBlockedPanes: blocked,
                    hasWorkingPanes: working, isUnavailable: unavailable,
                    context: .visibleLocal))
        }
    }
}

@Suite("Subscription cost control")
@MainActor
struct SubscriptionTrimmingTests {
    private func storeWithPanes(_ count: Int) -> StateStore {
        let store = StateStore()
        store.hydrate(Snapshot(panes: (1...count).map { index in
            PaneInfo(paneID: "w1:p\(index)", terminalID: "term_\(index)",
                     workspaceID: "w1", tabID: "w1:t1", focused: false,
                     agentStatus: .idle, revision: 0, agent: "claude")
        }))
        return store
    }

    @Test("a foreground session subscribes per pane")
    func foregroundSubscribesPerPane() {
        let subs = storeWithPanes(3).currentSubscriptions()
        let perPane = subs.filter { $0.type == "pane.agent_status_changed" }
        #expect(perPane.count == 3)
        #expect(perPane.allSatisfy { $0.paneID != nil })
    }

    @Test("a background session drops per-pane subscriptions but keeps lifecycle ones")
    func backgroundDropsPerPaneSubscriptions() {
        let subs = storeWithPanes(3).currentSubscriptions(includePerPaneStatus: false)

        // Each per-pane status subscription makes herdr re-read that pane on its
        // 100ms loop; dropping them is the actual saving.
        #expect(!subs.contains { $0.type == "pane.agent_status_changed" })
        // The lifecycle subscriptions are pure event-hub reads and cost nothing,
        // so a background session must keep noticing new and exited panes.
        #expect(Set(subs.map(\.type))
            == ["pane.agent_detected", "pane.created", "pane.exited"])
        #expect(subs.allSatisfy { $0.paneID == nil })
    }

    @Test("output_matched stays out of the batch in both modes")
    func neverSubscribesToOutputMatched() {
        // herdr requires it per-pane WITH a `source`; one bad entry makes it reject
        // the entire batch, so no events flow at all.
        for includePerPaneStatus in [true, false] {
            let subs = storeWithPanes(2)
                .currentSubscriptions(includePerPaneStatus: includePerPaneStatus)
            #expect(!subs.contains { $0.type == "pane.output_matched" })
        }
    }
}
