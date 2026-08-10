import Foundation

/// The result of an action.
public enum ActionResult: Sendable, Equatable {
    /// Keys/text were sent successfully.
    case sent
    /// Jump focused the pane and attempted to present its terminal application.
    case jumped(terminal: TerminalPresentation)
    /// The pane is on a detached session; focus can't be applied. Not a crash.
    case needsAttach
}

/// Errors specific to the action layer.
public enum ActionError: Error, Sendable {
    /// herdr rejected the keys (invalid key combo or `prefix+` binding) before writing.
    case keysRejected(message: String)
    /// A fresh read could not prove that the target pane is still working.
    case interruptPaneUnreadable(paneID: String)
    /// The target changed state before the confirmed interrupt could be sent.
    case interruptPaneNoLongerWorking(paneID: String, status: AgentStatus)
}

extension ActionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .keysRejected(message): message
        case let .interruptPaneUnreadable(paneID):
            "Couldn't confirm that pane \(paneID) is still working. Nothing was sent."
        case let .interruptPaneNoLongerWorking(_, status):
            "This agent is now \(status.rawValue). Nothing was sent."
        }
    }
}

/// Translates user intents into herdr calls + terminal presentation.
///
/// **Never auto-answers.** Every method is user-initiated; there are no timers
/// or defaults. Approve/deny/answer send validated key-combo tokens (herdr accepts
/// modifier chords such as `shift+tab`, but rejects `prefix+` bindings and invalid
/// keys before writing — surfaced as `ActionError.keysRejected`).
public struct Actions: Sendable {
    let client: any RequestSending
    let terminal: any TerminalPresenting

    public init(
        client: any RequestSending,
        terminal: any TerminalPresenting = TerminalActivator()
    ) {
        self.client = client
        self.terminal = terminal
    }

    /// Free-text reply (F9). Sends text; the caller decides whether a trailing
    /// `enter` is needed for the shape (default: yes, submit it).
    @discardableResult
    public func reply(pane: String, text: String, submit: Bool = true) async throws -> ActionResult {
        let params = try PaneSendTextParams(paneID: pane, text: text).asJSONValue()
        try await send("pane.send_text", params: params)
        if submit {
            return try await sendRawKeys(pane: pane, keys: ["enter"])
        }
        return .sent
    }

    /// Send raw keys directly (the always-available fallback for unknown shapes).
    @discardableResult
    public func sendRawKeys(pane: String, keys: [String]) async throws -> ActionResult {
        let params = try PaneSendKeysParams(paneID: pane, keys: keys).asJSONValue()
        try await send("pane.send_keys", params: params)
        return .sent
    }

    /// Interrupt a currently-working agent by sending exactly one Escape key.
    ///
    /// A fresh `pane.get` narrows the race between presenting the confirmation and
    /// writing to the terminal. herdr has no atomic interrupt-if-working method, so
    /// this is the closest safe boundary available: if the pane can no longer be
    /// proven to be working, no key is sent.
    @discardableResult
    public func interrupt(pane: String) async throws -> ActionResult {
        let result = try await client.request(
            "pane.get", params: FocusParams(paneID: pane).asJSONValue())
        guard let value = result["pane"],
              let info = try? value.decode(PaneInfo.self) else {
            throw ActionError.interruptPaneUnreadable(paneID: pane)
        }
        guard info.agentStatus == .working else {
            throw ActionError.interruptPaneNoLongerWorking(
                paneID: pane, status: info.agentStatus)
        }
        return try await sendRawKeys(pane: pane, keys: ["esc"])
    }

    /// Cycle the selected agent's interaction mode. The agent remains the source
    /// of truth for which mode becomes active; this method sends exactly one
    /// user-requested BackTab sequence and does not infer the resulting mode.
    ///
    /// `pane.send_keys` is intentionally not used here. In herdr 0.7.5 its
    /// Shift-Tab key event can redraw Claude without changing modes, while the
    /// terminal's standard BackTab sequence is handled correctly and repeatedly.
    @discardableResult
    public func cycleAgentMode(pane: String) async throws -> ActionResult {
        let params = try PaneSendTextParams(paneID: pane, text: "\u{1B}[Z").asJSONValue()
        try await send("pane.send_text", params: params)
        return .sent
    }

    // MARK: Jump

    /// Focus the pane in herdr, then present its terminal. Focusing a pane on a detached
    /// session returns `.needsAttach` rather than throwing.
    ///
    /// Focuses the WHOLE path — workspace → tab → pane — not just the pane. herdr is
    /// workspaces→tabs→panes, and the attached client only switches its DISPLAYED
    /// tab when the workspace + tab are focused too; `pane.focus` alone moves the
    /// server's focused id but can leave the terminal showing the previous tab.
    /// `workspaceID`/`tabID` come from
    /// the caller's `PaneInfo`; if omitted we look them up via `pane.get`.
    @discardableResult
    public func jump(
        pane: String,
        workspaceID: String? = nil,
        tabID: String? = nil,
        presenter: (any TerminalPresenting)? = nil
    ) async throws -> ActionResult {
        // Resolve workspace/tab if not supplied.
        var ws = workspaceID, tab = tabID
        if ws == nil || tab == nil {
            if let info = try? await client.request("pane.get", params: FocusParams(paneID: pane).asJSONValue()),
               let paneObj = info["pane"] {
                ws = ws ?? paneObj["workspace_id"]?.stringValue
                tab = tab ?? paneObj["tab_id"]?.stringValue
            }
        }
        func focusPath() async throws {
            // Focus outermost → innermost so the client switches its rendered view.
            if let ws { try await send("workspace.focus", params: .object(["workspace_id": .string(ws)])) }
            if let tab { try await send("tab.focus", params: .object(["tab_id": .string(tab)])) }
            try await send("pane.focus", params: FocusParams(paneID: pane).asJSONValue())
        }
        do {
            try await focusPath()
        } catch let HerdrError.api(code, message) {
            // A detached/unavailable session surfaces as an API error, not a crash.
            if code.contains("detached") || message.lowercased().contains("detached") {
                return .needsAttach
            }
            throw HerdrError.api(code: code, message: message)
        }
        let presentation = (presenter ?? terminal).present()
        // Re-assert the focus AFTER presenting the terminal. The client can miss/queue the
        // tab switch while it's backgrounded; issuing the focus again once it's
        // frontmost nudges it to render the target tab (the "different tab → jump
        // does nothing" case). Best-effort — ignore errors on the re-assert.
        try? await Task.sleep(nanoseconds: 120_000_000)
        try? await focusPath()
        return .jumped(terminal: presentation)
    }

    // MARK: Internal

    /// Send a request, translating herdr's key-rejection error into `ActionError`.
    private func send(_ method: String, params: JSONValue) async throws {
        do {
            try await client.request(method, params: params)
        } catch let HerdrError.api(code, message) {
            // herdr rejects invalid keys / prefix bindings before writing.
            if method.hasPrefix("pane.send"),
               code.contains("key") || code.contains("invalid") || code.contains("prefix")
                || message.lowercased().contains("key") {
                throw ActionError.keysRejected(message: message)
            }
            throw HerdrError.api(code: code, message: message)
        }
    }
}
