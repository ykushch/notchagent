import HerdrClient
import SwiftUI

/// Stable root hosted by the panel. The transparent AppKit canvas can change
/// independently while this one black surface morphs between its three modes.
struct PlaceholderNotchView: View {
    @Bindable var model: NotchViewModel
    @Bindable var surface: NotchSurfaceState

    private var isCompact: Bool { surface.presentation == .compact }
    private var isCompactRevealed: Bool { surface.isCompactIndicatorRevealed }
    private var isAttachedToNotch: Bool { surface.geometry.topContentInset > 0 }
    private var compactBottomRadius: CGFloat {
        // Preserve the notch silhouette in both compact heights. A radius equal
        // to the revealed lip height pulls the lower left and right edges inward
        // instead of leaving a square black extension below the hardware notch.
        isAttachedToNotch ? 12 : (isCompactRevealed ? 10 : 2)
    }
    private var shellShape: NotchSurfaceShape {
        NotchSurfaceShape(
            topRadius: isAttachedToNotch ? 0 : (isCompact ? 6 : 12),
            bottomRadius: isCompact ? compactBottomRadius : 22)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shellShape
                .fill(isCompact ? NotchPalette.notchVoid : NotchPalette.surface)
                .overlay(shellShape.stroke(NotchPalette.hairline, lineWidth: 1))

            CompactNotchSummary(
                model: model,
                surface: surface,
                topInset: surface.geometry.topContentInset)
                .opacity(isCompact ? 1 : 0)
                .scaleEffect(isCompact ? 1 : 0.92, anchor: .top)
                .allowsHitTesting(isCompact)

            if surface.presentation.isExpanded {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let snapshot = model.displaySnapshot(at: context.date)
                    ExpandedNotchSurface(
                        model: model,
                        surface: surface,
                        presentation: surface.presentation,
                        snapshot: snapshot,
                        topInset: surface.geometry.topContentInset)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .frame(
            width: surface.visibleSize.width,
            height: surface.visibleSize.height,
            alignment: .top)
        .clipShape(shellShape)
        .contentShape(shellShape)
        .shadow(
            color: surface.presentation.isExpanded
                ? NotchPalette.notchVoid.opacity(0.48) : .clear,
            radius: 20,
            y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover(perform: surface.setCompactHovering)
        .onExitCommand(perform: model.collapse)
    }
}

private struct CompactNotchSummary: View {
    @Bindable var model: NotchViewModel
    @Bindable var surface: NotchSurfaceState
    let topInset: CGFloat

    private var pendingUpdateVersion: String? { model.pendingUpdate?.version.rawValue }

    var body: some View {
        Button(action: model.toggle) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let snapshot = model.compactSignalSnapshot
                let style = CompactSignalStyle.resolve(snapshot, at: context.date)
                VStack(spacing: 0) {
                    Spacer(minLength: topInset)
                    if surface.isCompactIndicatorRevealed {
                        HStack(spacing: 5) {
                            HerdrBrandMark()
                                .frame(width: 9, height: 9)
                                .foregroundStyle(NotchPalette.primaryText.opacity(0.68))
                            Circle()
                                .fill(NotchPalette.status(style.visualStatus))
                                .frame(width: 5, height: 5)
                            Text("\(snapshot.count)")
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .foregroundStyle(NotchPalette.primaryText.opacity(0.86))
                                .monospacedDigit()
                            if pendingUpdateVersion != nil {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(NotchPalette.updateAccent)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.horizontal, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    } else {
                        // Status and update stay separate signals. The status bar
                        // uses width for count; the update remains a small paper tick.
                        HStack(spacing: 4) {
                            CompactStatusBar(
                                snapshot: snapshot,
                                style: style,
                                reduceMotion: surface.reduceMotion)
                            if pendingUpdateVersion != nil {
                                Capsule()
                                    .fill(NotchPalette.updateAccent)
                                    .frame(width: 4, height: 3)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
    }

    private var helpText: String {
        guard let version = pendingUpdateVersion else { return "herdr agents — click to expand" }
        return "herdr agents — NotchAgent \(version) is available"
    }

    private var accessibilityText: String {
        let base = [
            AgentCountLabel.text(model.agentCount),
            "overall status \(model.overallStatus.rawValue)",
            AgentCountLabel.attentionText(model.attentionCount),
        ].joined(separator: ", ")
        guard let version = pendingUpdateVersion else { return base }
        return "\(base). NotchAgent \(version) is available"
    }
}

struct NotchSurfaceShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: topRadius,
                bottomLeading: bottomRadius,
                bottomTrailing: bottomRadius,
                topTrailing: topRadius),
            style: .continuous)
            .path(in: rect)
    }
}
