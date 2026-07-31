import Foundation

public struct InteractionDisplayChoice: Sendable, Equatable {
    public let index: Int
    public let kind: InteractionChoiceKind
    public let label: String
    public let description: String?
    public let shortcutKeys: [String]
    public let isSelected: Bool
    public let isChecked: Bool?

    public init(index: Int, kind: InteractionChoiceKind, label: String, description: String?,
                shortcutKeys: [String] = [], isSelected: Bool, isChecked: Bool?) {
        self.index = index
        self.kind = kind
        self.label = label
        self.description = description
        self.shortcutKeys = shortcutKeys
        self.isSelected = isSelected
        self.isChecked = isChecked
    }
}

/// Pure view data used by SwiftUI and fixture tests. Keeping this transformation
/// out of the view makes content parity testable without rendering or transport.
public struct InteractionDisplayModel: Sendable, Equatable {
    public let title: String?
    public let body: String?
    public let progressText: String?
    public let choices: [InteractionDisplayChoice]
    public let showsTextEntry: Bool
    public let showsBeginTextEntry: Bool
    public let choicesAreActionable: Bool
    public let showsCancel: Bool
    public let showsManualControls: Bool
    public let exposesStructuredSubmit: Bool
    public let showsExplicitSubmit: Bool
    public let approvalOnceAvailable: Bool
    public let approvalPersistChoiceIndex: Int?
    public let supportMessage: String?
    public let userContextLine: String?
    public let selectedChoicePreview: String?

    public init(interaction: PendingInteraction) {
        title = interaction.title
        body = interaction.body
        progressText = Self.progressText(interaction.progress)
        userContextLine = interaction.userPromptContext.map { "You: \(Self.oneLine($0))" }
        selectedChoicePreview = interaction.presentation.selectedChoicePreview
        let isMultiSelect = interaction.capabilities.contains(.selectMany)
        let checked = Set(interaction.presentation.checkedChoiceIndexes)
        choices = interaction.choices.indices.map { index in
            let choice = interaction.choices[index]
            return InteractionDisplayChoice(
                index: index, kind: choice.kind, label: choice.label,
                description: choice.description, shortcutKeys: choice.shortcutKeys,
                isSelected: interaction.presentation.selectedChoiceIndex == index,
                isChecked: isMultiSelect ? checked.contains(index) : nil)
        }
        let supportsText = interaction.capabilities.contains(.enterText)
        showsTextEntry = supportsText
            && interaction.presentation.mechanism == .textEntry
        showsBeginTextEntry = supportsText
            && interaction.presentation.mechanism != .textEntry
            && interaction.kind == .question
        let isNative = interaction.evidence.source == .native
        let executableScreenChoices: Bool = switch interaction.presentation.mechanism {
        case .numberedShortcut:
            true
        case .explicitShortcut:
            interaction.choices.allSatisfy { !$0.shortcutKeys.isEmpty }
        case .arrowNavigate, .multiSelect:
            interaction.presentation.selectedChoiceIndex != nil
        case .textEntry, .ambiguous, .manual:
            false
        }
        choicesAreActionable = (isNative || executableScreenChoices)
            && (interaction.capabilities.contains(.selectOne)
                || interaction.capabilities.contains(.selectMany))
        showsCancel = interaction.capabilities.contains(.deny)
        showsManualControls = true
        exposesStructuredSubmit = isNative
            || (interaction.presentation.mechanism != .ambiguous
            && interaction.presentation.mechanism != .manual
            && interaction.kind != .unknown)
        showsExplicitSubmit = interaction.kind == .reviewSubmit
            || (interaction.presentation.mechanism == .multiSelect
                && interaction.steps.contains(where: \.isSubmit)
                && interaction.presentation.activeStepIndex != nil)
        approvalOnceAvailable = interaction.kind == .approval
            && (isNative || (interaction.presentation.mechanism == .explicitShortcut
                && interaction.choices.first?.shortcutKeys == ["y"]))
        approvalPersistChoiceIndex = interaction.kind == .approval
            ? (isNative
                ? interaction.choices.indices.dropFirst().dropLast().first
                : interaction.presentation.mechanism == .explicitShortcut
                    ? interaction.choices.indices.first {
                        interaction.choices[$0].shortcutKeys == ["p"]
                    } : nil)
            : nil
        if interaction.presentation.mechanism == .ambiguous {
            supportMessage = "Response mechanism is ambiguous — use manual controls."
        } else if interaction.kind == .unknown {
            supportMessage = "Unrecognized prompt — use manual controls."
        } else {
            supportMessage = "Responses are revalidated against the live prompt before sending."
        }
    }

    public static func progressText(_ progress: InteractionProgress?) -> String? {
        guard let progress else { return nil }
        if let current = progress.current, let total = progress.total {
            let base = "Question \(current)/\(total)"
            return progress.unanswered.map { "\(base) (\($0) unanswered)" } ?? base
        }
        return progress.unanswered.map { "\($0) unanswered questions" }
    }

    private static func oneLine(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Deterministic summary for one pane in the shared attention queue. This is
/// deliberately UI-framework-free so ordering, state language, summaries, and
/// accessibility can be fixture tested.
public struct InteractionAttentionDisplayModel: Identifiable, Sendable, Equatable {
    public let ref: AgentRef
    /// Shown as a badge so two agents from different sessions are visibly
    /// different rows. Nil for the single default local session, where a badge
    /// would be noise.
    public let sessionLabel: String?
    public let isRemote: Bool
    public let taskTitle: String
    public let agentName: String
    public let modelName: String?
    public let workspaceLabel: String
    public let tabTitle: String
    public let status: RollupStatus
    public let stateText: String
    public let summary: String
    public let activeSince: Date?
    public let elapsedText: String?
    public let freshnessText: String?
    public let isSelected: Bool

    public var paneID: String { ref.paneID }
    public var sessionID: String { ref.sessionID }

    /// Identity for `ForEach`. It **must** be the session-scoped ref: every herdr
    /// server names its first pane `w1:p1`, so keying on `paneID` alone collapses
    /// unrelated agents from different sessions into one row.
    public var id: String { ref.id }
    public var title: String { workspaceLabel }
    public var accessibilityLabel: String {
        [agentName, "in \(workspaceLabel)", tabTitle, modelName,
         sessionLabel.map { "session \($0)" }, "pane \(paneID)",
         stateText, summary, elapsedText, freshnessText]
            .compactMap { $0 }.joined(separator: ", ")
    }

    public init(paneID: String, sessionID: String = SessionDescriptor.localDefaultID,
                sessionLabel: String? = nil, isRemote: Bool = false,
                taskTitle: String, agentName: String,
                modelName: String? = nil, workspaceLabel: String,
                tabTitle: String = "Tab", status: RollupStatus,
                state: PaneInteractionState?, completionSummary: String? = nil,
                activeSince: Date? = nil, now: Date = Date(),
                isSelected: Bool) {
        self.ref = AgentRef(sessionID: sessionID, paneID: paneID)
        self.sessionLabel = sessionLabel
        self.isRemote = isRemote
        self.taskTitle = taskTitle
        self.agentName = agentName
        self.modelName = modelName
        self.workspaceLabel = workspaceLabel
        self.tabTitle = tabTitle
        self.status = status
        self.isSelected = isSelected
        self.activeSince = activeSince
        elapsedText = activeSince.map { "\(Self.duration(from: $0, to: now)) elapsed" }
        freshnessText = state?.lastReadAt.map {
            let seconds = max(0, now.timeIntervalSince($0))
            return seconds < 60 ? "fresh <1m" : "read \(Self.duration(from: $0, to: now)) ago"
        }
        if let error = state?.error, !error.isEmpty {
            stateText = "error"
            summary = Self.oneLine(error)
        } else if state?.draft.state == .stale {
            stateText = "draft needs review"
            summary = "The saved draft belongs to an earlier prompt."
        } else if let phase = state?.phase, phase != .idle {
            stateText = phase.rawValue
            summary = switch phase {
            case .reading: "Reading the live prompt…"
            case .responding: "Revalidating and sending…"
            case .settling: "Waiting for the terminal to settle…"
            case .idle: ""
            }
        } else if let interaction = state?.interaction {
            stateText = interaction.kind == .unknown ? "manual input" : "needs input"
            let progress = InteractionDisplayModel.progressText(interaction.progress)
            summary = [progress, interaction.title, interaction.body]
                .compactMap { $0 }.map(Self.oneLine).first { !$0.isEmpty }
                ?? "Prompt is ready for review."
        } else if status == .done {
            stateText = "finished"
            summary = completionSummary.map(Self.oneLine)
                ?? "Finished. Jump to review the final output."
        } else if status == .blocked {
            stateText = "needs input"
            summary = "Reading the live prompt…"
        } else if status == .working {
            stateText = "working"
            summary = "Agent is working — no input needed."
        } else {
            stateText = status.rawValue
            summary = "No pending interaction."
        }
    }

    private static func oneLine(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }
}

/// Stable space, tab, and terminal identity derived only from fields herdr owns.
/// A true agent task name is not available yet, so cwd remains a location
/// fallback rather than being presented as model-authored context.
public enum PaneDisplayIdentity {
    public static func spaceTitle(
        pane: PaneInfo, workspaceLabel: String? = nil
    ) -> String {
        if let workspaceLabel = nonEmpty(workspaceLabel) { return workspaceLabel }
        if let cwd = directoryName(pane.cwd) { return cwd }
        if let cwd = directoryName(pane.foregroundCwd) { return cwd }
        return pane.workspaceID
    }

    public static func tabTitle(label: String?, number: Int?) -> String {
        if let label = nonEmpty(label) {
            return normalizedGenericTabTitle(label)
        }
        if let number { return "Tab \(number)" }
        return "Tab"
    }

    public static func taskTitle(
        pane: PaneInfo, workspaceLabel: String? = nil
    ) -> String {
        if let title = nonEmpty(pane.title) { return title }
        if let label = nonEmpty(pane.label) { return label }
        if let cwd = directoryName(pane.cwd) { return cwd }
        if let cwd = directoryName(pane.foregroundCwd) { return cwd }
        if let workspaceLabel = nonEmpty(workspaceLabel) { return workspaceLabel }
        return nonEmpty(pane.displayAgent) ?? nonEmpty(pane.agent) ?? pane.paneID
    }

    public static func modelBadge(pane: PaneInfo) -> String? {
        nonEmpty(pane.tokens?[OpenCodePaneDescriptor.modelToken])
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func directoryName(_ path: String?) -> String? {
        guard let path = nonEmpty(path) else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func normalizedGenericTabTitle(_ label: String) -> String {
        let compact = label.filter { !$0.isWhitespace }
        if !compact.isEmpty, compact.allSatisfy(\.isNumber) {
            return "Tab \(compact)"
        }
        guard compact.count > 3,
              compact.prefix(3).lowercased() == "tab",
              compact.dropFirst(3).allSatisfy(\.isNumber) else {
            return label
        }
        return "Tab \(compact.dropFirst(3))"
    }
}

public enum AttentionRollupDisplay {
    public static func pillTaskTitle(
        items: [InteractionAttentionDisplayModel], selected: AgentRef?
    ) -> String? {
        if let selected,
           let row = items.first(where: {
               $0.ref == selected && $0.status == .blocked
           }) {
            return row.title
        }
        return items.first(where: { $0.status == .blocked })?.title
    }
}
