import Foundation

/// Pure cadence policy for the snapshot path. Events remain the instant
/// accelerator, while polling speeds up only when the UI or an agent is active.
///
/// Snapshot polling is the *cheap* path, not a workaround. herdr drives its own
/// event stream from a 100ms server loop, and a per-pane
/// `pane.agent_status_changed` subscription falls back to a `pane_get` for that
/// pane on every tick. One `session.snapshot` covers every pane in a session in a
/// single round-trip, so polling costs herdr strictly less than subscribing does.
public enum SnapshotPollingPolicy {
    /// How much a session matters right now. Every session shown in the expanded
    /// overview deserves the fast cadence, while a remote poll still costs a
    /// network round-trip on top.
    public struct SessionContext: Sendable, Equatable {
        /// The session is visible in the expanded overview or owns focused detail.
        public let isVisible: Bool
        /// Reached through an SSH tunnel, so each poll crosses the network.
        public let isRemote: Bool

        public init(isVisible: Bool = true, isRemote: Bool = false) {
            self.isVisible = isVisible
            self.isRemote = isRemote
        }

        public static let visibleLocal = SessionContext()
    }

    public static func nanoseconds(
        isExpanded: Bool,
        hasBlockedPanes: Bool,
        hasWorkingPanes: Bool,
        isUnavailable: Bool,
        context: SessionContext = .visibleLocal
    ) -> UInt64 {
        let base = baseNanoseconds(
            isExpanded: isExpanded && context.isVisible,
            hasBlockedPanes: hasBlockedPanes,
            hasWorkingPanes: hasWorkingPanes,
            isUnavailable: isUnavailable)
        return base * multiplier(context)
    }

    private static func baseNanoseconds(
        isExpanded: Bool,
        hasBlockedPanes: Bool,
        hasWorkingPanes: Bool,
        isUnavailable: Bool
    ) -> UInt64 {
        if isUnavailable { return 1_000_000_000 }
        if isExpanded || hasBlockedPanes { return 650_000_000 }
        if hasWorkingPanes { return 1_200_000_000 }
        return 2_500_000_000
    }

    /// A background session still needs to notice a *new* block promptly — that is
    /// the whole point of tracking it — so it is slowed, never parked. Remote
    /// sessions are slowed further because their cost is a network round-trip
    /// rather than a local socket write.
    private static func multiplier(_ context: SessionContext) -> UInt64 {
        switch (context.isVisible, context.isRemote) {
        case (true, false): 1
        case (true, true): 2
        case (false, false): 2
        case (false, true): 3
        }
    }
}
