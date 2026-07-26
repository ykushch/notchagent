import Foundation

enum NotchExpansionOrigin: Sendable, Equatable {
    case automatic
    case manual
}

struct NotchFocusContext: Sendable, Equatable {
    var origin: NotchExpansionOrigin
    var hasUserEngaged: Bool

    var preservesResolvedSelection: Bool {
        origin == .manual || hasUserEngaged
    }
}

/// Logical presentation requested by the application. The window controller
/// mirrors this into a transient render state so it can prepare the transparent
/// canvas before SwiftUI begins the visible morph.
enum NotchPresentation: Sendable, Equatable {
    case compact
    case overview
    case focused(NotchFocusContext)

    var isExpanded: Bool { self != .compact }
    var isFocused: Bool {
        if case .focused = self { return true }
        return false
    }
    var preservesResolvedSelection: Bool {
        guard case .focused(let context) = self else { return false }
        return context.preservesResolvedSelection
    }
    /// Automatic attention changes may open detail only from the compact state.
    /// Overview and focused detail reflect an explicit user context and stay put.
    var allowsAutomaticFocus: Bool {
        if case .compact = self { return true }
        return false
    }
    /// Auto-expand-on-done may reveal overview unless that would discard detail
    /// the user opened or interacted with.
    var allowsAutomaticOverview: Bool {
        !preservesResolvedSelection
    }

    mutating func markUserEngaged() {
        guard case .focused(var context) = self else { return }
        context.hasUserEngaged = true
        self = .focused(context)
    }

    /// Destination after a focused pane disappears or resolves and the
    /// coordinator no longer preserves it.
    var fallbackAfterFocusedPaneEnds: NotchPresentation {
        guard case .focused(let context) = self else { return self }
        return context.hasUserEngaged || context.origin == .manual ? .overview : .compact
    }
}
