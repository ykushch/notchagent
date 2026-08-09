import Foundation
import Observation

public enum PaneOutputPhase: String, Sendable, Equatable {
    case idle
    case reading
}

public enum PanePromptPhase: String, Sendable, Equatable {
    case idle
    case sending
}

/// Pane-scoped state for the focused surfaces that are deliberately outside the
/// blocked-interaction model: a bounded working-output glimpse and an idle task
/// draft. `SessionRuntime` provides the session scope, so pane ids remain the
/// correct key here.
public struct PaneActivityState: Sendable, Equatable {
    public let paneID: String
    public var recentOutput: String?
    public var outputRevision: UInt64?
    public var outputAttemptRevision: UInt64?
    public var outputReadAt: Date?
    public var outputPhase: PaneOutputPhase
    public var outputError: String?
    public var promptDraft: String
    public var promptPhase: PanePromptPhase
    public var promptError: String?

    public init(
        paneID: String,
        recentOutput: String? = nil,
        outputRevision: UInt64? = nil,
        outputAttemptRevision: UInt64? = nil,
        outputReadAt: Date? = nil,
        outputPhase: PaneOutputPhase = .idle,
        outputError: String? = nil,
        promptDraft: String = "",
        promptPhase: PanePromptPhase = .idle,
        promptError: String? = nil
    ) {
        self.paneID = paneID
        self.recentOutput = recentOutput
        self.outputRevision = outputRevision
        self.outputAttemptRevision = outputAttemptRevision
        self.outputReadAt = outputReadAt
        self.outputPhase = outputPhase
        self.outputError = outputError
        self.promptDraft = promptDraft
        self.promptPhase = promptPhase
        self.promptError = promptError
    }

    public var isBusy: Bool {
        outputPhase == .reading || promptPhase == .sending
    }
}

/// Minimal live pane evidence consumed by `PaneActivityCoordinator`.
public struct PaneActivitySnapshot: Sendable, Equatable {
    public let paneID: String
    public let agentStatus: AgentStatus
    public let revision: UInt64

    public init(paneID: String, agentStatus: AgentStatus, revision: UInt64) {
        self.paneID = paneID
        self.agentStatus = agentStatus
        self.revision = revision
    }
}

public protocol RecentOutputProviding: Sendable {
    func recentOutput(paneID: String) async throws -> String
}

/// Reads a bounded, plain-text tail for a selected working pane. This is a raw
/// glimpse, not a semantic completion summary: the terminal remains authoritative.
public struct ScreenRecentOutputProvider: RecentOutputProviding, Sendable {
    private let client: any RequestSending
    private let requestLineLimit: Int
    private let displayLineLimit: Int
    private let characterLimit: Int

    public init(
        client: any RequestSending,
        requestLineLimit: Int = 40,
        displayLineLimit: Int = 16,
        characterLimit: Int = 4_096
    ) {
        self.client = client
        self.requestLineLimit = max(1, requestLineLimit)
        self.displayLineLimit = max(1, displayLineLimit)
        self.characterLimit = max(1, characterLimit)
    }

    public func recentOutput(paneID: String) async throws -> String {
        let params = try PaneReadParams(
            paneID: paneID,
            source: .recentUnwrapped,
            lines: requestLineLimit,
            format: "text",
            stripAnsi: true
        ).asJSONValue()
        let result = try await client.request("pane.read", params: params)
        guard let value = result["read"],
              let read = try? value.decode(PaneReadResult.self) else {
            throw InteractionProviderError.unreadablePane(paneID: paneID)
        }
        return RecentOutputExtractor.extract(
            from: read.text,
            lineLimit: displayLineLimit,
            characterLimit: characterLimit)
    }
}

public enum RecentOutputExtractor {
    public static func extract(
        from terminalText: String,
        lineLimit: Int = 16,
        characterLimit: Int = 4_096
    ) -> String {
        var lines = PromptClassifier.stripAnsi(terminalText)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        var value = lines.suffix(max(1, lineLimit)).joined(separator: "\n")
        let limit = max(1, characterLimit)
        if value.count > limit {
            let start = value.index(value.endIndex, offsetBy: -limit)
            var tail = String(value[start...])
            if let newline = tail.firstIndex(of: "\n"), newline != tail.startIndex {
                let completeLine = tail.index(after: newline)
                if completeLine < tail.endIndex {
                    tail = String(tail[completeLine...])
                }
            }
            value = "…\n" + tail
        }
        return value
    }
}

public protocol IdlePromptSending: Sendable {
    func sendPrompt(paneID: String, text: String) async throws
}

public enum IdlePromptSenderError: Error, Sendable, Equatable {
    case unreadablePane(paneID: String)
    case paneNoLongerIdle(paneID: String, status: AgentStatus)
}

extension IdlePromptSenderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unreadablePane(paneID):
            "Couldn't confirm that pane \(paneID) is still idle. Nothing was sent."
        case let .paneNoLongerIdle(_, status):
            "This agent is now \(status.rawValue). Nothing was sent."
        }
    }
}

/// Safety boundary for starting a new task. A fresh `pane.get` narrows the race
/// between rendering an idle composer and injecting text into an agent that has
/// since started working or become blocked.
public struct SafeIdlePromptSender: IdlePromptSending, Sendable {
    private let client: any RequestSending
    private let actions: Actions

    public init(client: any RequestSending) {
        self.client = client
        self.actions = Actions(client: client)
    }

    public func sendPrompt(paneID: String, text: String) async throws {
        let result = try await client.request(
            "pane.get", params: FocusParams(paneID: paneID).asJSONValue())
        guard let value = result["pane"],
              let pane = try? value.decode(PaneInfo.self) else {
            throw IdlePromptSenderError.unreadablePane(paneID: paneID)
        }
        guard pane.agentStatus == .idle else {
            throw IdlePromptSenderError.paneNoLongerIdle(
                paneID: paneID, status: pane.agentStatus)
        }
        _ = try await actions.reply(pane: paneID, text: text)
    }
}

/// Main-actor state and lifecycle for non-blocked focused panes. Reads are
/// selected-pane-only and revision-driven, with a bounded fallback for terminal
/// revisions that do not advance reliably.
@Observable
@MainActor
public final class PaneActivityCoordinator {
    public typealias Clock = @Sendable () -> Date

    public private(set) var states: [String: PaneActivityState] = [:]

    @ObservationIgnored private let outputProvider: any RecentOutputProviding
    @ObservationIgnored private let promptSender: any IdlePromptSending
    @ObservationIgnored private let fallbackPollInterval: Int
    @ObservationIgnored private let now: Clock
    @ObservationIgnored private var knownPanes: [String: PaneActivitySnapshot] = [:]
    @ObservationIgnored private var selectedPaneID: String?
    @ObservationIgnored private var pollIndex = 0
    @ObservationIgnored private var nextGeneration: UInt64 = 0
    @ObservationIgnored private var outputGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var promptGenerations: [String: UInt64] = [:]

    public init(
        outputProvider: any RecentOutputProviding,
        promptSender: any IdlePromptSending,
        fallbackPollInterval: Int = 4,
        now: @escaping Clock = Date.init
    ) {
        self.outputProvider = outputProvider
        self.promptSender = promptSender
        self.fallbackPollInterval = max(1, fallbackPollInterval)
        self.now = now
    }

    public func state(for paneID: String) -> PaneActivityState? {
        states[paneID]
    }

    public var selectedState: PaneActivityState? {
        selectedPaneID.flatMap { states[$0] }
    }

    public func clearSelection() {
        guard let selectedPaneID else { return }
        outputGenerations[selectedPaneID] = nil
        if var state = states[selectedPaneID], state.outputPhase == .reading {
            state.outputPhase = .idle
            states[selectedPaneID] = state
        }
        self.selectedPaneID = nil
    }

    @discardableResult
    public func reconcile(
        panes: [PaneActivitySnapshot],
        selectedPaneID: String?,
        countsTowardFallbackCadence: Bool = true
    ) async -> [String] {
        if countsTowardFallbackCadence { pollIndex += 1 }
        let previousPanes = knownPanes
        let previousSelection = self.selectedPaneID
        knownPanes = Dictionary(uniqueKeysWithValues: panes.map { ($0.paneID, $0) })
        self.selectedPaneID = selectedPaneID

        if previousSelection != selectedPaneID, let previousSelection {
            outputGenerations[previousSelection] = nil
            if var state = states[previousSelection], state.outputPhase == .reading {
                state.outputPhase = .idle
                states[previousSelection] = state
            }
        }

        let liveIDs = Set(knownPanes.keys)
        for paneID in states.keys where !liveIDs.contains(paneID) {
            states[paneID] = nil
            outputGenerations[paneID] = nil
            promptGenerations[paneID] = nil
        }

        for pane in panes where previousPanes[pane.paneID]?.agentStatus != .working
            && pane.agentStatus == .working && states[pane.paneID] != nil {
            var state = states[pane.paneID]!
            state.recentOutput = nil
            state.outputRevision = nil
            state.outputAttemptRevision = nil
            state.outputReadAt = nil
            state.outputError = nil
            states[pane.paneID] = state
        }

        guard let selectedPaneID, let pane = knownPanes[selectedPaneID] else { return [] }
        ensureState(selectedPaneID)
        guard pane.agentStatus == .working else {
            outputGenerations[selectedPaneID] = nil
            if var state = states[selectedPaneID], state.outputPhase == .reading {
                state.outputPhase = .idle
                states[selectedPaneID] = state
            }
            return []
        }

        let state = states[selectedPaneID]!
        let shouldRefresh = state.outputAttemptRevision == nil
            || state.outputAttemptRevision != pane.revision
            || (countsTowardFallbackCadence
                && pollIndex.isMultiple(of: fallbackPollInterval))
        guard shouldRefresh, state.outputPhase == .idle else { return [] }
        return await refreshOutput(paneID: selectedPaneID) ? [selectedPaneID] : []
    }

    @discardableResult
    public func refreshSelectedOutput() async -> Bool {
        guard let selectedPaneID,
              knownPanes[selectedPaneID]?.agentStatus == .working else { return false }
        ensureState(selectedPaneID)
        guard states[selectedPaneID]?.outputPhase == .idle else { return false }
        return await refreshOutput(paneID: selectedPaneID)
    }

    public func promptDraft(for paneID: String) -> String {
        states[paneID]?.promptDraft ?? ""
    }

    public func setPromptDraft(_ text: String, paneID: String) {
        guard knownPanes[paneID] != nil else { return }
        ensureState(paneID)
        states[paneID]?.promptDraft = text
        states[paneID]?.promptError = nil
    }

    @discardableResult
    public func sendPrompt(paneID: String) async -> Bool {
        guard knownPanes[paneID]?.agentStatus == .idle else {
            setPromptError("This agent is no longer idle. Nothing was sent.", paneID: paneID)
            return false
        }
        ensureState(paneID)
        guard var state = states[paneID], state.promptPhase == .idle else { return false }
        let text = state.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        nextGeneration &+= 1
        let generation = nextGeneration
        promptGenerations[paneID] = generation
        state.promptPhase = .sending
        state.promptError = nil
        states[paneID] = state
        do {
            try await promptSender.sendPrompt(paneID: paneID, text: text)
            guard promptGenerations[paneID] == generation,
                  var current = states[paneID] else { return true }
            current.promptPhase = .idle
            if current.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                current.promptDraft = ""
            }
            states[paneID] = current
            promptGenerations[paneID] = nil
            return true
        } catch {
            guard promptGenerations[paneID] == generation,
                  var current = states[paneID] else { return false }
            current.promptPhase = .idle
            current.promptError = Self.message(for: error)
            states[paneID] = current
            promptGenerations[paneID] = nil
            return false
        }
    }

    private func refreshOutput(paneID: String) async -> Bool {
        guard let pane = knownPanes[paneID], pane.agentStatus == .working,
              var state = states[paneID] else { return false }
        nextGeneration &+= 1
        let generation = nextGeneration
        outputGenerations[paneID] = generation
        state.outputPhase = .reading
        state.outputError = nil
        states[paneID] = state
        do {
            let output = try await outputProvider.recentOutput(paneID: paneID)
            guard outputGenerations[paneID] == generation,
                  selectedPaneID == paneID,
                  knownPanes[paneID]?.agentStatus == .working,
                  var current = states[paneID] else { return false }
            current.recentOutput = output
            current.outputRevision = pane.revision
            current.outputAttemptRevision = pane.revision
            current.outputReadAt = now()
            current.outputPhase = .idle
            current.outputError = nil
            states[paneID] = current
            outputGenerations[paneID] = nil
            return true
        } catch {
            guard outputGenerations[paneID] == generation,
                  var current = states[paneID] else { return false }
            current.outputPhase = .idle
            current.outputAttemptRevision = pane.revision
            current.outputError = Self.message(for: error)
            states[paneID] = current
            outputGenerations[paneID] = nil
            return false
        }
    }

    private func ensureState(_ paneID: String) {
        if states[paneID] == nil {
            states[paneID] = PaneActivityState(paneID: paneID)
        }
    }

    private func setPromptError(_ message: String, paneID: String) {
        guard knownPanes[paneID] != nil else { return }
        ensureState(paneID)
        states[paneID]?.promptError = message
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
