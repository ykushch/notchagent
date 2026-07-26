import Foundation
import Testing
@testable import HerdrClient

@Suite("Session-scoped agent references")
struct AgentRefTests {
    /// The bug this whole re-keying exists to prevent: every herdr server names
    /// its first pane `w1:p1`, so a list keyed on pane id alone collapses
    /// unrelated agents on different sessions into a single row.
    @Test("rows for the same pane id on different sessions stay distinct")
    func panesCollideAcrossSessionsButRowsDoNot() {
        func row(sessionID: String, label: String?) -> InteractionAttentionDisplayModel {
            InteractionAttentionDisplayModel(
                paneID: "w1:p1", sessionID: sessionID, sessionLabel: label,
                isRemote: sessionID.hasPrefix("ssh:"),
                taskTitle: "Fix auth", agentName: "claude",
                workspaceLabel: "project", status: .blocked, state: nil,
                isSelected: false)
        }
        let local = row(sessionID: "local:default", label: "default")
        let named = row(sessionID: "local:work", label: "work")
        let remote = row(sessionID: "ssh:workbox/default", label: "workbox")

        // Same pane id everywhere...
        #expect([local, named, remote].allSatisfy { $0.paneID == "w1:p1" })
        // ...but three distinct ForEach identities.
        #expect(Set([local.id, named.id, remote.id]).count == 3)
        #expect(local.id == "local:default/w1:p1")
        #expect(remote.id == "ssh:workbox/default/w1:p1")
        #expect(remote.isRemote)
        #expect(!named.isRemote)
    }

    @Test("a ref carries the session that owns the pane")
    func refRoundTrips() {
        let ref = AgentRef(sessionID: "ssh:workbox/agents", paneID: "w1:p2")
        #expect(ref.id == "ssh:workbox/agents/w1:p2")
        #expect(ref.sessionID == "ssh:workbox/agents")
        #expect(ref.paneID == "w1:p2")
        #expect(ref == AgentRef(sessionID: "ssh:workbox/agents", paneID: "w1:p2"))
        #expect(ref != AgentRef(sessionID: "local:default", paneID: "w1:p2"))
    }

    @Test("the pill picks the selected row by ref, not by pane id")
    func pillDisambiguatesByRef() {
        func row(sessionID: String, workspace: String) -> InteractionAttentionDisplayModel {
            InteractionAttentionDisplayModel(
                paneID: "w1:p1", sessionID: sessionID,
                taskTitle: "t", agentName: "claude",
                workspaceLabel: workspace, status: .blocked, state: nil,
                isSelected: false)
        }
        let local = row(sessionID: "local:default", workspace: "local-project")
        let remote = row(sessionID: "ssh:workbox/default", workspace: "remote-project")

        // Both panes are "w1:p1"; only the ref distinguishes them.
        #expect(AttentionRollupDisplay.pillTaskTitle(
            items: [local, remote], selected: remote.ref) == "remote-project")
        #expect(AttentionRollupDisplay.pillTaskTitle(
            items: [local, remote], selected: local.ref) == "local-project")
    }

    @Test("the session badge is surfaced to accessibility")
    func accessibilityMentionsSession() {
        let row = InteractionAttentionDisplayModel(
            paneID: "w1:p1", sessionID: "ssh:workbox/default", sessionLabel: "workbox",
            isRemote: true, taskTitle: "t", agentName: "claude",
            workspaceLabel: "project", status: .blocked, state: nil, isSelected: false)
        #expect(row.accessibilityLabel.contains("session workbox"))

        // A single default session gets no badge, and says nothing extra.
        let plain = InteractionAttentionDisplayModel(
            paneID: "w1:p1", taskTitle: "t", agentName: "claude",
            workspaceLabel: "project", status: .blocked, state: nil, isSelected: false)
        #expect(!plain.accessibilityLabel.contains("session"))
        #expect(plain.id == "local:default/w1:p1")
    }
}
