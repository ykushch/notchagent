import HerdrClient
import SwiftUI

/// Contextual controls remain outside the scrolling prompt so the active task
/// has one predictable action area. Recovery controls use progressive disclosure.
struct InteractionActionShelf: View {
    @Bindable var model: NotchViewModel
    let interaction: PendingInteraction
    let phase: PaneInteractionPhase

    @State private var terminalExpanded = false
    @FocusState private var contextFieldFocused: Bool

    private var display: InteractionDisplayModel {
        InteractionDisplayModel(interaction: interaction)
    }

    private var requiresManualFallback: Bool {
        interaction.kind == .unknown
            || interaction.presentation.mechanism == .ambiguous
            || interaction.presentation.mechanism == .manual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            primaryControls
            TerminalFallbackDisclosure(
                model: model,
                isExpanded: $terminalExpanded,
                warning: requiresManualFallback ? display.supportMessage : nil)
            phaseStatus
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(NotchPalette.surface)
        .onChange(of: requiresManualFallback, initial: true) { _, required in
            if required { terminalExpanded = true }
        }
        .onChange(of: display.showsTextEntry, initial: true) { _, visible in
            if visible {
                Task { @MainActor in
                    await Task.yield()
                    contextFieldFocused = true
                }
            }
        }
    }

    @ViewBuilder private var primaryControls: some View {
        if interaction.kind == .approval {
            approvalControls
        } else if display.showsTextEntry {
            contextComposer
        } else if hasQuestionControls {
            questionControls
        }
    }

    private var hasQuestionControls: Bool {
        display.showsBeginTextEntry
            || interaction.capabilities.contains(.navigateSteps)
            || display.showsCancel
            || display.exposesStructuredSubmit
    }

    private var questionControls: some View {
        HStack(spacing: 8) {
            if display.showsBeginTextEntry {
                Button {
                    model.respondToSelectedInteraction(.beginTextEntry)
                } label: {
                    Label("Add Context…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .help("Add an optional text response")
            }
            Spacer(minLength: 4)
            if interaction.capabilities.contains(.navigateSteps) {
                questionStepper
            }
            if let selected = interaction.presentation.selectedChoiceIndex,
               interaction.presentation.selectedChoicePreview != nil,
               interaction.choices.indices.contains(selected) {
                Button {
                    model.respondToSelectedInteraction(.selectChoice(selected))
                } label: {
                    Label("Choose selected", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(NotchPalette.action)
                .help("Submit “\(interaction.choices[selected].label)”")
            }
            if display.showsExplicitSubmit {
                Button {
                    model.respondToSelectedInteraction(.submit)
                } label: {
                    Label("Submit", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(NotchPalette.action)
                .help(interaction.kind == .reviewSubmit
                    ? "Submit these answers"
                    : "Review and submit the selected answers")
                .accessibilityIdentifier("interaction-submit")
            }
            safetyIndicator
            if display.showsCancel {
                interactionMenu(includesBackToChoices: false)
            }
        }
        .controlSize(.small)
        .disabled(phase.isBusy)
    }

    private var questionStepper: some View {
        HStack(spacing: 0) {
            Button {
                model.respondToSelectedInteraction(.navigatePrevious)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 24, height: 22)
            }
            .help("Previous question")

            Rectangle()
                .fill(NotchPalette.hairline)
                .frame(width: 1, height: 14)

            Text(compactProgress)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(NotchPalette.secondaryText)
                .monospacedDigit()
                .frame(minWidth: 38, minHeight: 22)
                .accessibilityLabel(display.progressText ?? "Question navigation")

            Rectangle()
                .fill(NotchPalette.hairline)
                .frame(width: 1, height: 14)

            Button {
                model.respondToSelectedInteraction(.navigateNext)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 24, height: 22)
            }
            .help("Next question")
        }
        .buttonStyle(.plain)
        .foregroundStyle(NotchPalette.secondaryText)
        .background(Capsule().fill(NotchPalette.elevated))
        .overlay(Capsule().stroke(NotchPalette.hairline, lineWidth: 1))
    }

    private var compactProgress: String {
        guard let current = interaction.progress?.current,
              let total = interaction.progress?.total else { return "Steps" }
        return "\(current) / \(total)"
    }

    private var contextComposer: some View {
        HStack(spacing: 7) {
            TextField("Add context…", text: $model.replyText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .focused($contextFieldFocused)
                .onSubmit(submitContext)
                .disabled(phase.isBusy)

            Button(action: submitContext) {
                Label("Send", systemImage: "arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .tint(NotchPalette.action)
            .disabled(trimmedDraft.isEmpty || phase.isBusy)

            safetyIndicator
            interactionMenu(includesBackToChoices: true)
        }
        .controlSize(.small)
    }

    private var approvalControls: some View {
        HStack(spacing: 7) {
            Label("Approval", systemImage: "shield.lefthalf.filled")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NotchPalette.blocked)
            Spacer(minLength: 4)
            if interaction.capabilities.contains(.deny) {
                Button("Deny") {
                    model.respondToSelectedInteraction(.deny)
                }
                .buttonStyle(.bordered)
            }
            if let index = display.approvalPersistChoiceIndex {
                Button(interaction.evidence.source == .native
                    ? "Allow Always" : "Allow Prefix") {
                    model.respondToSelectedInteraction(.selectChoice(index))
                }
                .buttonStyle(.bordered)
            }
            if display.approvalOnceAvailable {
                Button("Allow Once") {
                    model.respondToSelectedInteraction(.approve)
                }
                .buttonStyle(.borderedProminent)
                .tint(NotchPalette.action)
            }
            safetyIndicator
        }
        .controlSize(.small)
        .disabled(phase.isBusy)
    }

    private var safetyIndicator: some View {
        Image(systemName: "shield.checkered")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(NotchPalette.tertiaryText)
            .help(display.supportMessage
                ?? "The live prompt is checked again before a response is sent.")
            .accessibilityLabel("Live checked before sending")
    }

    private func interactionMenu(includesBackToChoices: Bool) -> some View {
        Menu {
            if includesBackToChoices {
                Button("Back to Choices", systemImage: "arrow.uturn.backward") {
                    model.respondToSelectedInteraction(.clearTextEntry)
                }
            }
            if display.showsCancel {
                if includesBackToChoices { Divider() }
                Button("Cancel Question Flow", systemImage: "xmark") {
                    model.respondToSelectedInteraction(.cancel)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More actions")
    }

    @ViewBuilder private var phaseStatus: some View {
        if phase != .idle {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(phaseText)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(NotchPalette.secondaryText)
        }
    }

    private var phaseText: String {
        switch phase {
        case .reading: "Reading live prompt…"
        case .responding: "Revalidating and sending…"
        case .settling: "Waiting for terminal redraw…"
        case .idle: ""
        }
    }

    private var trimmedDraft: String {
        model.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitContext() {
        guard !trimmedDraft.isEmpty else { return }
        model.respondToSelectedInteraction(.submitText(trimmedDraft))
    }
}

struct TerminalFallbackShelf: View {
    @Bindable var model: NotchViewModel
    let warning: String
    @State private var isExpanded = true

    var body: some View {
        TerminalFallbackDisclosure(
            model: model,
            isExpanded: $isExpanded,
            warning: warning)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(NotchPalette.surface)
    }
}

private struct TerminalFallbackDisclosure: View {
    @Bindable var model: NotchViewModel
    @Binding var isExpanded: Bool
    let warning: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(NotchPalette.blocked)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 7) {
                    TextField("Keys or text…", text: $model.replyText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit(model.sendManualTextSelected)
                    Button(action: model.sendManualTextSelected) {
                        Label("Send", systemImage: "return")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NotchPalette.action)
                    Menu("More", systemImage: "keyboard") {
                        Button("Type Without Return", systemImage: "text.cursor") {
                            model.typeTextWithoutSubmitSelected()
                        }
                        Divider()
                        keyButton("Arrow Up", symbol: "arrow.up", key: "up")
                        keyButton("Arrow Down", symbol: "arrow.down", key: "down")
                        keyButton("Arrow Left", symbol: "arrow.left", key: "left")
                        keyButton("Arrow Right", symbol: "arrow.right", key: "right")
                        Divider()
                        keyButton("Return", symbol: "return", key: "enter")
                        keyButton("Space", symbol: "space", key: "space")
                        keyButton("Escape", symbol: "escape", key: "esc")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .controlSize(.small)
                .disabled(model.isActing)
            }
            .padding(.top, 7)
        } label: {
            Label("Terminal fallback", systemImage: "terminal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NotchPalette.secondaryText)
        }
        .tint(NotchPalette.tertiaryText)
    }

    private func keyButton(
        _ title: String, symbol: String, key: String
    ) -> some View {
        Button(title, systemImage: symbol) {
            model.sendRawKeysSelected([key])
        }
    }
}
