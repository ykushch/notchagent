import HerdrClient
import Testing
@testable import NotchApp

@Suite("Diagnostics presentation")
struct DiagnosticsPresentationTests {
    @Test("ordinary unknown terminal panes are not failed agent detections")
    func ignoresOrdinaryPanes() {
        let shell = pane(id: "w1:p2", agent: nil)
        let unresolvedAgent = pane(id: "w1:p1", agent: "claude")

        #expect(!HerdrDiagnosticPanePolicy.shouldOfferExplanation(
            pane: shell, derivedStatus: .unknown))
        #expect(HerdrDiagnosticPanePolicy.shouldOfferExplanation(
            pane: unresolvedAgent, derivedStatus: .unknown))
        #expect(!HerdrDiagnosticPanePolicy.shouldOfferExplanation(
            pane: unresolvedAgent, derivedStatus: .idle))
    }

    @Test("agent count uses correct singular and plural labels")
    func countLabels() {
        #expect(AgentCountLabel.text(0) == "0 agents")
        #expect(AgentCountLabel.text(1) == "1 agent")
        #expect(AgentCountLabel.text(2) == "2 agents")
        #expect(AgentCountLabel.attentionText(1) == "1 needs input")
        #expect(AgentCountLabel.attentionText(2) == "2 need input")
    }

    private func pane(id: String, agent: String?) -> PaneInfo {
        PaneInfo(
            paneID: id,
            terminalID: "term-\(id)",
            workspaceID: "w1",
            tabID: "w1:t1",
            focused: false,
            agentStatus: .unknown,
            revision: 0,
            agent: agent)
    }
}
