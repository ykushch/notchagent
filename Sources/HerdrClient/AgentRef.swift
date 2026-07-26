import Foundation

/// A globally unique reference to one agent pane.
///
/// A bare `pane_id` is only unique within a single herdr server: `w1:p1` exists on
/// the default session, on every named session, and on every remote host. Once the
/// notch aggregates more than one session, anything that identifies a pane — a
/// selection, a SwiftUI row identity, a dictionary key — has to carry the session
/// too, or two unrelated agents silently become the same row.
public struct AgentRef: Hashable, Sendable, Identifiable, Codable {
    public let sessionID: String
    public let paneID: String

    public init(sessionID: String, paneID: String) {
        self.sessionID = sessionID
        self.paneID = paneID
    }

    public var id: String { "\(sessionID)/\(paneID)" }
}

extension AgentRef: CustomStringConvertible {
    public var description: String { id }
}
