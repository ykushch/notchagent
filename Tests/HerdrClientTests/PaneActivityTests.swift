import Foundation
import Testing
@testable import HerdrClient

private enum ActivityTestError: Error { case failed }

private actor ActivityOutputProvider: RecentOutputProviding {
    private var values: [String]
    private let failingCalls: Set<Int>
    private var calls: [String] = []

    init(values: [String], failingCalls: Set<Int> = []) {
        self.values = values
        self.failingCalls = failingCalls
    }

    func recentOutput(paneID: String) async throws -> String {
        calls.append(paneID)
        if failingCalls.contains(calls.count) { throw ActivityTestError.failed }
        if values.count > 1 { return values.removeFirst() }
        return values.first ?? ""
    }

    func callCount(for paneID: String) -> Int { calls.count { $0 == paneID } }
}

private actor ActivityPromptSender: IdlePromptSending {
    private let error: (any Error & Sendable)?
    private var values: [(String, String)] = []

    init(error: (any Error & Sendable)? = nil) { self.error = error }

    func sendPrompt(paneID: String, text: String) async throws {
        if let error { throw error }
        values.append((paneID, text))
    }

    func sent() -> [(String, String)] { values }
}

private actor ActivityRequestClient: RequestSending {
    var paneStatus: AgentStatus
    private var calls: [(String, JSONValue)] = []

    init(paneStatus: AgentStatus) { self.paneStatus = paneStatus }

    func request(_ method: String, params: JSONValue,
                 id: String) async throws -> JSONValue {
        calls.append((method, params))
        if method == "pane.get" {
            let pane = PaneInfo(
                paneID: "w1:p1", terminalID: "term", workspaceID: "w1",
                tabID: "w1:t1", focused: false, agentStatus: paneStatus,
                revision: 7, agent: "codex")
            return .object(["pane": try pane.asJSONValue()])
        }
        return .object(["ok": .bool(true)])
    }

    func recordedCalls() -> [(String, JSONValue)] { calls }
}

@Suite("Pane activity provider and safety boundary")
struct PaneActivityProviderTests {
    @Test("recent output is a bounded plain-text tail")
    func recentOutputShape() async throws {
        let client = ActivityReadClient(text: "\n\u{001B}[31mone\u{001B}[0m\ntwo\nthree\n")
        let output = try await ScreenRecentOutputProvider(
            client: client, requestLineLimit: 22, displayLineLimit: 2,
            characterLimit: 100).recentOutput(paneID: "w1:p1")

        #expect(output == "two\nthree")
        let calls = await client.recordedCalls()
        #expect(calls.count == 1)
        #expect(calls[0].0 == "pane.read")
        #expect(calls[0].1["source"]?.stringValue == "recent_unwrapped")
        #expect(calls[0].1["lines"]?.intValue == 22)
        #expect(calls[0].1["strip_ansi"]?.boolValue == true)
    }

    @Test("character limiting retains the newest output")
    func characterLimitKeepsTail() {
        #expect(RecentOutputExtractor.extract(
            from: "oldest\nmiddle\nnewest", lineLimit: 10, characterLimit: 8)
            == "…\nnewest")
    }

    @Test("safe idle sender checks pane status before writing")
    func safeIdleSend() async throws {
        let client = ActivityRequestClient(paneStatus: .idle)
        try await SafeIdlePromptSender(client: client).sendPrompt(
            paneID: "w1:p1", text: "Implement the fix")

        let calls = await client.recordedCalls()
        #expect(calls.map(\.0) == ["pane.get", "pane.send_text", "pane.send_keys"])
        #expect(calls[1].1["text"]?.stringValue == "Implement the fix")
    }

    @Test("safe idle sender refuses a pane that started working")
    func changedStatusRefusesSend() async {
        let client = ActivityRequestClient(paneStatus: .working)

        await #expect(throws: IdlePromptSenderError.self) {
            try await SafeIdlePromptSender(client: client).sendPrompt(
                paneID: "w1:p1", text: "Do not inject this")
        }
        #expect(await client.recordedCalls().map(\.0) == ["pane.get"])
    }
}

private actor ActivityReadClient: RequestSending {
    let text: String
    private var calls: [(String, JSONValue)] = []

    init(text: String) { self.text = text }

    func request(_ method: String, params: JSONValue,
                 id: String) async throws -> JSONValue {
        calls.append((method, params))
        return .object(["read": .object([
            "pane_id": .string("w1:p1"),
            "source": .string("recent_unwrapped"),
            "text": .string(text),
        ])])
    }

    func recordedCalls() -> [(String, JSONValue)] { calls }
}

@Suite("Pane activity coordinator", .serialized)
@MainActor
struct PaneActivityCoordinatorTests {
    @Test("only selected working output is read, by revision and fallback")
    func selectedRevisionLifecycle() async {
        let output = ActivityOutputProvider(values: ["first", "second", "fallback"])
        let coordinator = PaneActivityCoordinator(
            outputProvider: output, promptSender: ActivityPromptSender(),
            fallbackPollInterval: 4)

        _ = await coordinator.reconcile(
            panes: [working("w1:p1", revision: 1), working("w1:p2", revision: 1)],
            selectedPaneID: "w1:p1")
        #expect(coordinator.state(for: "w1:p1")?.recentOutput == "first")
        #expect(await output.callCount(for: "w1:p1") == 1)
        #expect(await output.callCount(for: "w1:p2") == 0)

        _ = await coordinator.reconcile(
            panes: [working("w1:p1", revision: 2), working("w1:p2", revision: 1)],
            selectedPaneID: "w1:p1")
        #expect(coordinator.state(for: "w1:p1")?.recentOutput == "second")

        _ = await coordinator.reconcile(
            panes: [working("w1:p1", revision: 2)], selectedPaneID: "w1:p1")
        _ = await coordinator.reconcile(
            panes: [working("w1:p1", revision: 2)], selectedPaneID: "w1:p1")
        #expect(coordinator.state(for: "w1:p1")?.recentOutput == "fallback")
        #expect(await output.callCount(for: "w1:p1") == 3)
    }

    @Test("failed refresh preserves the last good output")
    func failedRefreshPreservesOutput() async {
        let output = ActivityOutputProvider(
            values: ["last good value"], failingCalls: [2])
        let coordinator = PaneActivityCoordinator(
            outputProvider: output, promptSender: ActivityPromptSender())

        _ = await coordinator.reconcile(
            panes: [working("w1:p1", revision: 1)], selectedPaneID: "w1:p1")
        _ = await coordinator.reconcile(
            panes: [working("w1:p1", revision: 2)], selectedPaneID: "w1:p1")
        _ = await coordinator.reconcile(
            panes: [working("w1:p1", revision: 2)], selectedPaneID: "w1:p1")

        #expect(coordinator.state(for: "w1:p1")?.recentOutput == "last good value")
        #expect(coordinator.state(for: "w1:p1")?.outputError != nil)
        #expect(coordinator.state(for: "w1:p1")?.outputPhase == .idle)
        #expect(await output.callCount(for: "w1:p1") == 2)
    }

    @Test("idle drafts are pane-scoped and clear only after success")
    func promptDraftLifecycle() async {
        let sender = ActivityPromptSender()
        let coordinator = PaneActivityCoordinator(
            outputProvider: ActivityOutputProvider(values: []), promptSender: sender)
        let panes = [idle("w1:p1"), idle("w1:p2")]
        _ = await coordinator.reconcile(panes: panes, selectedPaneID: "w1:p1")
        coordinator.setPromptDraft(" first task ", paneID: "w1:p1")
        coordinator.setPromptDraft("second task", paneID: "w1:p2")

        #expect(await coordinator.sendPrompt(paneID: "w1:p1"))
        #expect(coordinator.promptDraft(for: "w1:p1").isEmpty)
        #expect(coordinator.promptDraft(for: "w1:p2") == "second task")
        let sent = await sender.sent()
        #expect(sent.count == 1)
        #expect(sent[0].0 == "w1:p1")
        #expect(sent[0].1 == "first task")
    }

    @Test("failed prompt preserves its draft and reports the error")
    func promptFailure() async {
        let coordinator = PaneActivityCoordinator(
            outputProvider: ActivityOutputProvider(values: []),
            promptSender: ActivityPromptSender(error: ActivityTestError.failed))
        _ = await coordinator.reconcile(
            panes: [idle("w1:p1")], selectedPaneID: "w1:p1")
        coordinator.setPromptDraft("keep me", paneID: "w1:p1")

        #expect(!(await coordinator.sendPrompt(paneID: "w1:p1")))
        #expect(coordinator.promptDraft(for: "w1:p1") == "keep me")
        #expect(coordinator.state(for: "w1:p1")?.promptError != nil)
        #expect(coordinator.state(for: "w1:p1")?.promptPhase == .idle)
    }

    @Test("a locally observed status change refuses prompt submission")
    func promptStatusChanged() async {
        let sender = ActivityPromptSender()
        let coordinator = PaneActivityCoordinator(
            outputProvider: ActivityOutputProvider(values: ["working"]),
            promptSender: sender)
        _ = await coordinator.reconcile(
            panes: [idle("w1:p1")], selectedPaneID: "w1:p1")
        coordinator.setPromptDraft("keep this", paneID: "w1:p1")
        _ = await coordinator.reconcile(
            panes: [working("w1:p1", revision: 2)], selectedPaneID: "w1:p1")

        #expect(!(await coordinator.sendPrompt(paneID: "w1:p1")))
        #expect(coordinator.promptDraft(for: "w1:p1") == "keep this")
        #expect(coordinator.state(for: "w1:p1")?.promptError != nil)
        #expect(await sender.sent().isEmpty)
    }

    @Test("exited panes discard bounded activity state")
    func exitCleanup() async {
        let coordinator = PaneActivityCoordinator(
            outputProvider: ActivityOutputProvider(values: []),
            promptSender: ActivityPromptSender())
        _ = await coordinator.reconcile(
            panes: [idle("w1:p1")], selectedPaneID: "w1:p1")
        coordinator.setPromptDraft("temporary", paneID: "w1:p1")

        _ = await coordinator.reconcile(panes: [], selectedPaneID: nil)
        #expect(coordinator.state(for: "w1:p1") == nil)
    }

    private func working(_ paneID: String, revision: UInt64) -> PaneActivitySnapshot {
        PaneActivitySnapshot(
            paneID: paneID, agentStatus: .working, revision: revision)
    }

    private func idle(_ paneID: String) -> PaneActivitySnapshot {
        PaneActivitySnapshot(paneID: paneID, agentStatus: .idle, revision: 1)
    }
}
