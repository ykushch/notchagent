import AppKit
import HerdrClient
import SwiftUI

enum InteractionChoiceIntentResolver {
    static func intent(
        for choice: InteractionDisplayChoice,
        selectedChoicePreview: String?
    ) -> InteractionResponseIntent {
        choice.isChecked.map { .setChoice(choice.index, checked: !$0) }
            ?? (selectedChoicePreview != nil
                ? .previewChoice(choice.index)
                : .selectChoice(choice.index))
    }
}

struct InteractionChoiceButton<Label: View>: View {
    let identifier: String
    let isDisabled: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier(identifier)
    }
}

/// Agent-neutral rendering for the normalized interaction contract.
struct InteractionDetailView: View {
    let interaction: PendingInteraction
    @Binding var draftText: String
    let phase: PaneInteractionPhase
    let hotkeySymbols: String
    let respond: (InteractionResponseIntent) -> Void
    @State private var hoveredChoiceIndex: Int?

    private var display: InteractionDisplayModel {
        InteractionDisplayModel(interaction: interaction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            progressHeader
            if let title = display.title {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NotchPalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let context = display.userContextLine {
                Text(context).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchPalette.secondaryText).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(context)
            }
            evidenceCard
            if interaction.contentEvidence == nil,
               let body = display.body, !body.isEmpty {
                Text(body).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NotchPalette.secondaryText).textSelection(.enabled)
                    .lineLimit(8).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(display.choices, id: \.index) { choice in
                choiceRow(choice)
            }
        }
        .padding(interaction.kind == .approval ? 10 : 0)
        .background {
            if interaction.kind == .approval {
                RoundedRectangle(cornerRadius: 11)
                    .fill(NotchPalette.elevated)
            }
        }
        .overlay {
            if interaction.kind == .approval {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(NotchPalette.blocked.opacity(0.42), lineWidth: 1)
            }
        }
    }

    @ViewBuilder private var evidenceCard: some View {
        switch interaction.contentEvidence {
        case .command(let evidence):
            commandCard(evidence)
        case .diff(let evidence):
            diffCard(evidence)
        case nil:
            EmptyView()
        }
    }

    private func commandCard(_ evidence: InteractionCommandEvidence) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label("Command", systemImage: "terminal")
                    .font(.system(size: 9, weight: .semibold))
                Spacer()
                if let environment = evidence.environment {
                    Text(environment.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(NotchPalette.blocked)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(evidence.command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain).help("Copy command")
                .accessibilityLabel("Copy command")
            }
            Text(evidence.command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NotchPalette.primaryText).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = evidence.reason {
                Text(reason).font(.system(size: 9))
                    .foregroundStyle(NotchPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8).foregroundStyle(NotchPalette.secondaryText)
        .background(RoundedRectangle(cornerRadius: 8).fill(NotchPalette.elevated))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(NotchPalette.blocked.opacity(0.32)))
    }

    private func diffCard(_ evidence: InteractionDiffEvidence) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Label(evidence.filePath, systemImage: "doc.text")
                    .font(.system(size: 9, weight: .semibold)).lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("+\(evidence.additions)").foregroundStyle(NotchPalette.done)
                Text("−\(evidence.removals)").foregroundStyle(NotchPalette.blocked)
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .padding(8)
            ForEach(Array(evidence.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text(line.lineNumber.map(String.init) ?? "")
                        .frame(width: 20, alignment: .trailing)
                        .foregroundStyle(NotchPalette.tertiaryText)
                    Text(diffMarker(line.kind)).frame(width: 7)
                        .foregroundStyle(diffForeground(line.kind))
                    Text(line.text).foregroundStyle(NotchPalette.primaryText.opacity(0.86))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(diffBackground(line.kind))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(NotchPalette.elevated))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(NotchPalette.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Proposed changes to \(evidence.filePath), \(evidence.additions) additions, \(evidence.removals) removals")
    }

    private func diffMarker(_ kind: InteractionDiffLineKind) -> String {
        switch kind { case .context: " "; case .removal: "−"; case .addition: "+" }
    }

    private func diffForeground(_ kind: InteractionDiffLineKind) -> Color {
        switch kind {
        case .context: NotchPalette.secondaryText
        case .removal: NotchPalette.blocked
        case .addition: NotchPalette.done
        }
    }

    private func diffBackground(_ kind: InteractionDiffLineKind) -> Color {
        switch kind {
        case .context: .clear
        case .removal: NotchPalette.blocked.opacity(0.12)
        case .addition: NotchPalette.done.opacity(0.12)
        }
    }

    @ViewBuilder private var progressHeader: some View {
        if display.progressText != nil || !interaction.steps.isEmpty {
            HStack(spacing: 8) {
                if let progress = display.progressText {
                    Text(progress)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchPalette.primaryText)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                ForEach(interaction.steps.indices, id: \.self) { index in
                    let step = interaction.steps[index]
                    Button {
                        respond(.navigateToStep(index))
                    } label: {
                        Circle()
                            .fill(stepColor(step, at: index))
                            .frame(width: 6, height: 6)
                            .contentShape(Rectangle().inset(by: -4))
                    }
                    .buttonStyle(.plain)
                    .disabled(phase.isBusy || !interaction.capabilities.contains(.navigateSteps))
                    .help(step.isSubmit ? "Submit" : step.label)
                    .accessibilityLabel("Step \(index + 1), \(step.label)\(step.isAnswered ? ", answered" : "")")
                }
                }
            }
        }
    }

    private func stepColor(_ step: InteractionStep, at index: Int) -> Color {
        if index == interaction.presentation.activeStepIndex { return NotchPalette.primaryText }
        if step.isAnswered { return NotchPalette.done.opacity(0.78) }
        return NotchPalette.disabledText
    }

    @ViewBuilder private func choiceRow(_ choice: InteractionDisplayChoice) -> some View {
        if choice.kind == .textEntry {
            VStack(alignment: .leading, spacing: 5) {
                choiceContent(choice)
                textEntry(submit: { .submitChoiceText(choice.index, $0) })
            }
        } else if display.choicesAreActionable {
            InteractionChoiceButton(
                identifier: "interaction-choice-\(choice.index)",
                isDisabled: phase.isBusy,
                action: { respond(choiceIntent(choice)) }
            ) {
                choiceContent(choice)
            }
            .help(display.selectedChoicePreview == nil
                ? "Choose \(choice.label)"
                : "Preview \(choice.label) without submitting")
        } else {
            choiceContent(choice)
        }
    }

    private func choiceContent(_ choice: InteractionDisplayChoice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 7) {
                Text("\(choice.index + 1).").font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(choice.isSelected
                        ? NotchPalette.done : NotchPalette.secondaryText)
                if let checked = choice.isChecked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked
                            ? NotchPalette.done : NotchPalette.disabledText)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.label).font(.system(size: 11, weight: choice.isSelected ? .semibold : .regular))
                        .foregroundStyle(NotchPalette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    if let description = choice.description {
                        choiceDescription(description)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                Spacer(minLength: 0)
                if display.choicesAreActionable,
                   display.selectedChoicePreview != nil {
                        Label(choice.isSelected ? "Selected" : "Preview",
                              systemImage: choice.isSelected ? "checkmark" : "eye")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchPalette.tertiaryText)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(NotchPalette.hover))
                        .fixedSize()
                } else if display.choicesAreActionable, choice.index < 9 {
                    Text("\(hotkeySymbols)\(choice.index + 1)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchPalette.tertiaryText)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(NotchPalette.hover))
                        .fixedSize()
                }
            }
            if choice.isSelected,
               let preview = display.selectedChoicePreview,
               !preview.isEmpty {
                Divider().overlay(NotchPalette.hairline).padding(.vertical, 7)
                Text(preview)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(NotchPalette.secondaryText)
                    .textSelection(.disabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            choice.isChecked == true ? NotchPalette.done.opacity(0.18)
                : choice.isSelected ? NotchPalette.selected
                : hoveredChoiceIndex == choice.index ? NotchPalette.hover
                : NotchPalette.elevated))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
            choice.isSelected ? NotchPalette.done.opacity(0.6) : .clear))
        .onHover { hovering in
            hoveredChoiceIndex = hovering ? choice.index
                : hoveredChoiceIndex == choice.index ? nil : hoveredChoiceIndex
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(display.selectedChoicePreview == nil
            ? "Option \(choice.index + 1), \(choice.label)"
            : "Preview option \(choice.index + 1), \(choice.label), without submitting")
    }

    @ViewBuilder private func choiceDescription(_ description: String) -> some View {
        let text = Text(description)
            .font(.system(
                size: 9,
                design: description.contains("\n") ? .monospaced : .default))
            .foregroundStyle(NotchPalette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        if display.choicesAreActionable {
            text.textSelection(.disabled)
        } else {
            text.textSelection(.enabled)
        }
    }

    private func textEntry(
        submit intent: @escaping (String) -> InteractionResponseIntent
    ) -> some View {
        HStack(spacing: 6) {
            TextField("Type your answer…", text: $draftText)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
                .onSubmit { submitText(intent) }.disabled(phase.isBusy)
            Button("Submit") { submitText(intent) }
                .buttonStyle(.borderedProminent)
                .tint(NotchPalette.action)
                .controlSize(.small)
                .disabled(draftText.isEmpty || phase.isBusy)
        }
    }

    private func choiceIntent(_ choice: InteractionDisplayChoice) -> InteractionResponseIntent {
        InteractionChoiceIntentResolver.intent(
            for: choice, selectedChoicePreview: display.selectedChoicePreview)
    }

    private func submitText(_ intent: (String) -> InteractionResponseIntent) {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        respond(intent(text))
    }
}
