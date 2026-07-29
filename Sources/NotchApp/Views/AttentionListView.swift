import HerdrClient
import SwiftUI

struct AttentionListView: View {
    let items: [InteractionAttentionDisplayModel]
    let select: (AgentRef) -> Void
    let jump: (AgentRef) -> Void
    @State private var hoveredRef: AgentRef?

    var body: some View {
        LazyVStack(spacing: 6) {
            ForEach(items) { item in
                HStack(spacing: 4) {
                    Button { select(item.ref) } label: { row(item) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.accessibilityLabel)
                        .accessibilityHint("Show this agent's pending interaction")
                    Button("Jump") { jump(item.ref) }
                        .buttonStyle(.plain).font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NotchPalette.action).padding(.horizontal, 6)
                        .accessibilityLabel(
                            "Jump to \(item.agentName) in \(item.workspaceLabel), \(item.tabTitle)")
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 9).fill(
                    item.isSelected ? NotchPalette.selected
                        : hoveredRef == item.ref
                            ? NotchPalette.hover : NotchPalette.elevated))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(
                    hoveredRef == item.ref ? NotchPalette.hairline : .clear))
                .onHover { hovering in
                    hoveredRef = hovering ? item.ref
                        : hoveredRef == item.ref ? nil : hoveredRef
                }
            }
        }
    }

    private func row(_ item: InteractionAttentionDisplayModel) -> some View {
        HStack(spacing: 8) {
            Circle().fill(NotchPalette.status(item.status)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotchPalette.primaryText)
                    Spacer()
                    // Only set when more than one session is tracked — otherwise
                    // every row would carry the same redundant badge.
                    if let sessionLabel = item.sessionLabel {
                        Label {
                            Text(sessionLabel).lineLimit(1)
                        } icon: {
                            Image(systemName: item.isRemote ? "network" : "rectangle.on.rectangle")
                        }
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(NotchPalette.secondaryText)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(NotchPalette.hover))
                    }
                    Text(item.agentName.uppercased())
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.9))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(NotchPalette.selected))
                    if let modelName = item.modelName {
                        Text(modelName)
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .foregroundStyle(NotchPalette.secondaryText).lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(NotchPalette.hover))
                    }
                }
                HStack {
                    Text(item.summary)
                        .font(.system(size: 9))
                        .foregroundStyle(NotchPalette.secondaryText)
                        .lineLimit(1)
                    Spacer()
                    Text(item.stateText).font(.system(size: 8, weight: .bold))
                        .foregroundStyle(item.status == .blocked
                            ? NotchPalette.blocked : NotchPalette.tertiaryText)
                }
                HStack(spacing: 6) {
                    Text(item.tabTitle).lineLimit(1)
                    Spacer()
                    if let elapsed = item.elapsedText {
                        Label(elapsed, systemImage: "clock")
                    }
                    if let freshness = item.freshnessText {
                        Text(freshness)
                    }
                }
                .font(.system(size: 8))
                .foregroundStyle(NotchPalette.tertiaryText)
                .monospacedDigit()
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}
