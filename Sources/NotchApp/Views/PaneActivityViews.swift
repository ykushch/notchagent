import HerdrClient
import SwiftUI

struct WorkingOutputPreview: View {
    let state: PaneActivityState?
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Recent output", systemImage: "text.alignleft")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                Spacer()
                if state?.outputPhase == .reading {
                    ProgressView().controlSize(.small)
                    Text(state?.recentOutput == nil ? "Reading…" : "Refreshing…")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(NotchPalette.tertiaryText)
                } else if state?.outputReadAt != nil {
                    Text("recent")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(NotchPalette.tertiaryText)
                }
            }

            if let output = state?.recentOutput, !output.isEmpty {
                Text(verbatim: output)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(NotchPalette.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(NotchPalette.notchVoid.opacity(0.58)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(NotchPalette.hairline, lineWidth: 1))
            } else if state?.outputPhase == .reading {
                ProgressView("Reading recent terminal output…")
                    .font(.system(size: 9))
                    .foregroundStyle(NotchPalette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                Text("No recent output is available yet.")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchPalette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            }

            if let error = state?.outputError {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Retry", action: retry)
                        .foregroundStyle(NotchPalette.action)
                }
                .font(.system(size: 9, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(NotchPalette.blocked)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent output from working agent")
    }
}

struct WorkingAgentActionShelf: View {
    @Bindable var model: NotchViewModel
    let item: InteractionAttentionDisplayModel
    @State private var isConfirmingInterrupt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("Agent is working", systemImage: "bolt.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(NotchPalette.secondaryText)
                Spacer(minLength: 8)
                if model.isInterrupting(item.ref) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Interrupting agent")
                }
                Button("Interrupt Agent", role: .destructive) {
                    isConfirmingInterrupt = true
                }
                .buttonStyle(.bordered)
                .tint(NotchPalette.blocked)
                .controlSize(.small)
                .disabled(!model.canInterrupt(item.ref))
                .help("Send Escape once after confirmation")
                .accessibilityIdentifier("interrupt-agent")
                .accessibilityHint("Asks for confirmation before sending Escape once")
            }

            if let error = model.interruptError(for: item.ref) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(NotchPalette.blocked)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(NotchPalette.surface)
        .confirmationDialog(
            "Interrupt this agent?",
            isPresented: $isConfirmingInterrupt,
            titleVisibility: .visible
        ) {
            Button("Interrupt Agent", role: .destructive) {
                model.interrupt(item.ref)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends Escape once to \(item.agentName) in \(item.workspaceLabel). It may stop the current command or response, but it does not terminate the Herdr session or terminal.")
        }
    }
}
