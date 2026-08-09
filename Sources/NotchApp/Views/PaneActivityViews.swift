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
