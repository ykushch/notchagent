import Foundation
import Testing
@testable import HerdrClient

final class MockClient: RequestSending, @unchecked Sendable {
    struct Call: Sendable { let method: String; let params: JSONValue }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    var errorForMethod: [String: HerdrError] = [:]
    var resultForMethod: [String: JSONValue] = [:]
    func request(_ method: String, params: JSONValue, id: String) async throws -> JSONValue {
        lock.withLock { calls.append(Call(method: method, params: params)) }
        if let error = errorForMethod[method] { throw error }
        return resultForMethod[method] ?? .object(["ok": .bool(true)])
    }
    var recorded: [Call] { lock.withLock { calls } }
}

final class MockTerminal: TerminalPresenting, @unchecked Sendable {
    var presented = false
    var result: TerminalPresentation = .presented(appName: "Test Terminal")
    func present() -> TerminalPresentation { presented = true; return result }
}

@Suite("Action layer: intent → outbound JSON")
struct ActionsTests {
    @Test func replySendsTextThenEnter() async throws {
        let client = MockClient(); let actions = Actions(client: client, terminal: MockTerminal())
        _ = try await actions.reply(pane: "w1:p1", text: "do X instead")
        #expect(client.recorded.map(\.method) == ["pane.send_text", "pane.send_keys"])
    }
    @Test func replyNoSubmit() async throws {
        let client = MockClient(); let actions = Actions(client: client, terminal: MockTerminal())
        _ = try await actions.reply(pane: "w1:p1", text: "note", submit: false)
        #expect(client.recorded.map(\.method) == ["pane.send_text"])
    }
    @Test func rawKeysSendExactlyTheValidatedTokens() async throws {
        let client = MockClient(); let actions = Actions(client: client, terminal: MockTerminal())
        _ = try await actions.sendRawKeys(pane: "w1:p1", keys: ["down", "space"])
        #expect(client.recorded[0].params["keys"]?.arrayValue?.compactMap(\.stringValue)
            == ["down", "space"])
    }
    @Test func interruptFreshChecksWorkingThenSendsOneEscape() async throws {
        let client = MockClient()
        client.resultForMethod["pane.get"] = .object([
            "pane": try pane(status: .working).asJSONValue()
        ])

        #expect(try await Actions(client: client, terminal: MockTerminal())
            .interrupt(pane: "w1:p1") == .sent)
        #expect(client.recorded.map(\.method) == ["pane.get", "pane.send_keys"])
        #expect(client.recorded[1].params["keys"]?.arrayValue?.compactMap(\.stringValue)
            == ["esc"])
    }
    @Test func interruptRefusesPaneThatIsNoLongerWorking() async throws {
        let client = MockClient()
        client.resultForMethod["pane.get"] = .object([
            "pane": try pane(status: .idle).asJSONValue()
        ])

        await #expect(throws: ActionError.self) {
            try await Actions(client: client, terminal: MockTerminal())
                .interrupt(pane: "w1:p1")
        }
        #expect(client.recorded.map(\.method) == ["pane.get"])
    }
    @Test func interruptRefusesUnreadableFreshPane() async {
        let client = MockClient()
        client.resultForMethod["pane.get"] = .object(["ok": .bool(true)])

        await #expect(throws: ActionError.self) {
            try await Actions(client: client, terminal: MockTerminal())
                .interrupt(pane: "w1:p1")
        }
        #expect(client.recorded.map(\.method) == ["pane.get"])
    }
    @Test func cycleAgentModeSendsOneBackTabSequencePerRequest() async throws {
        let client = MockClient(); let actions = Actions(client: client, terminal: MockTerminal())
        _ = try await actions.cycleAgentMode(pane: "w1:p1")
        _ = try await actions.cycleAgentMode(pane: "w1:p1")
        #expect(client.recorded.map(\.method) == ["pane.send_text", "pane.send_text"])
        #expect(client.recorded[0].params["pane_id"]?.stringValue == "w1:p1")
        #expect(client.recorded.map { $0.params["text"]?.stringValue } == ["\u{1B}[Z", "\u{1B}[Z"])
    }
    @Test func jumpOrdering() async throws {
        let client = MockClient(); let terminal = MockTerminal(); let actions = Actions(client: client, terminal: terminal)
        #expect(try await actions.jump(pane: "w2:p1", workspaceID: "w2", tabID: "w2:t1") == .jumped(terminal: .presented(appName: "Test Terminal")))
        #expect(client.recorded.map(\.method) == ["workspace.focus", "tab.focus", "pane.focus", "workspace.focus", "tab.focus", "pane.focus"])
        #expect(terminal.presented)
    }
    @Test func jumpLooksUpPath() async throws {
        let client = MockClient(); client.resultForMethod["pane.get"] = .object(["pane": .object(["workspace_id": .string("w5"), "tab_id": .string("w5:t2")])])
        _ = try await Actions(client: client, terminal: MockTerminal()).jump(pane: "w5:p1")
        #expect(client.recorded.map(\.method).contains("pane.get"))
    }
    @Test func jumpReturnsTerminalPresentationFailure() async throws {
        let client = MockClient()
        let terminal = MockTerminal()
        terminal.result = .unavailable(.ambiguous(appNames: ["Ghostty", "iTerm2"]))

        #expect(try await Actions(client: client, terminal: terminal).jump(
            pane: "w1:p1", workspaceID: "w1", tabID: "w1:t1") == .jumped(
                terminal: .unavailable(.ambiguous(appNames: ["Ghostty", "iTerm2"]))))
        #expect(terminal.presented)
    }
    @Test func jumpDetached() async throws {
        let client = MockClient(); client.errorForMethod["workspace.focus"] = .api(code: "session_detached", message: "session is detached")
        let terminal = MockTerminal()
        #expect(try await Actions(client: client, terminal: terminal).jump(pane: "w9:p1", workspaceID: "w9", tabID: "w9:t1") == .needsAttach)
        #expect(!terminal.presented)
    }
    @Test func keyRejection() async {
        let client = MockClient(); client.errorForMethod["pane.send_keys"] = .api(code: "invalid_key", message: "invalid key token")
        await #expect(throws: ActionError.self) { try await Actions(client: client, terminal: MockTerminal()).sendRawKeys(pane: "w1:p1", keys: ["prefix+x"]) }
        #expect(client.recorded.count == 1)
    }

    private func pane(status: AgentStatus) -> PaneInfo {
        PaneInfo(
            paneID: "w1:p1", terminalID: "term", workspaceID: "w1",
            tabID: "w1:t1", focused: false, agentStatus: status,
            revision: 1, agent: "codex")
    }
}
