import AppKit

struct NotchScreenMetrics: Sendable, Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let safeAreaTop: CGFloat
    let auxiliaryTopLeftArea: CGRect?
    let auxiliaryTopRightArea: CGRect?

    init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftArea: CGRect? = nil,
        auxiliaryTopRightArea: CGRect? = nil
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    init(screen: NSScreen) {
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea)
    }

    var hasPhysicalNotch: Bool { safeAreaTop > 0 }
}

struct NotchGeometry: Sendable, Equatable {
    static let floatingCompactWidth: CGFloat = 190
    static let notchHorizontalSeam: CGFloat = 8
    static let minimalIndicatorHeight: CGFloat = 3
    static let revealedIndicatorHeight: CGFloat = 12
    static let preferredExpandedWidth: CGFloat = 520
    static let preferredMaximumExpandedHeight: CGFloat = 420
    static let overviewRowHeight: CGFloat = 58
    static let overviewBannerHeight: CGFloat = 44
    /// The update notice carries a headline, detail, two actions, and the
    /// re-grant reminder, so it is materially taller than a one-line banner.
    static let overviewUpdateBannerHeight: CGFloat = 104
    static let overviewEmptyHeight: CGFloat = 168

    let compactWidth: CGFloat
    let expandedWidth: CGFloat
    let maximumExpandedHeight: CGFloat
    let topContentInset: CGFloat

    init(metrics: NotchScreenMetrics) {
        compactWidth = Self.physicalNotchWidth(metrics: metrics)
            .map { $0 + Self.notchHorizontalSeam }
            ?? Self.floatingCompactWidth
        let availableWidth = max(1, metrics.visibleFrame.width - 24)
        let availableHeight = max(1, metrics.visibleFrame.height * 0.72)

        expandedWidth = min(Self.preferredExpandedWidth, availableWidth)
        maximumExpandedHeight = min(Self.preferredMaximumExpandedHeight, availableHeight)
        topContentInset = metrics.hasPhysicalNotch ? metrics.safeAreaTop : 0
    }

    var expandedSize: CGSize {
        expandedSize(requestedHeight: maximumExpandedHeight)
    }

    func compactSize(revealed: Bool) -> CGSize {
        let indicatorHeight = revealed
            ? Self.revealedIndicatorHeight
            : Self.minimalIndicatorHeight
        return CGSize(width: compactWidth, height: topContentInset + indicatorHeight)
    }

    /// The panel keeps this fixed compact canvas while the visible indicator
    /// reveals inside it. Resizing the window itself from an `onHover` change
    /// moves its tracking area under the pointer and can make the notch jump.
    var compactCanvasSize: CGSize {
        compactSize(revealed: true)
    }

    var minimumOverviewHeight: CGFloat {
        min(maximumExpandedHeight, max(190, topContentInset + 150))
    }

    var minimumFocusedHeight: CGFloat {
        min(maximumExpandedHeight, max(300, topContentInset + 260))
    }

    func expandedSize(requestedHeight: CGFloat) -> CGSize {
        CGSize(
            width: expandedWidth,
            height: min(maximumExpandedHeight, max(1, Self.roundHeight(requestedHeight))))
    }

    func overviewHeight(agentCount: Int, bannerCount: Int, hasUpdateBanner: Bool = false) -> CGFloat {
        let header = topContentInset + (topContentInset > 0 ? 5 : 8) + 39
        let content: CGFloat
        if agentCount == 0 {
            content = Self.overviewEmptyHeight
        } else {
            content = CGFloat(agentCount) * Self.overviewRowHeight
        }
        let banners = CGFloat(bannerCount) * Self.overviewBannerHeight
            + (hasUpdateBanner ? Self.overviewUpdateBannerHeight : 0)
        let sections = (agentCount > 0 ? 1 : 0) + bannerCount + (hasUpdateBanner ? 1 : 0)
        let sectionGaps = CGFloat(max(0, sections - 1)) * 7
        return clampOverviewHeight(header + 28 + content + banners + sectionGaps)
    }

    func focusedHeight(choiceCount: Int, hasEvidence: Bool, hasActionShelf: Bool) -> CGFloat {
        let header = topContentInset + (topContentInset > 0 ? 5 : 8) + 39
        let promptContent = 92 + CGFloat(min(choiceCount, 4)) * 44 + (hasEvidence ? 46 : 0)
        let shelf: CGFloat = hasActionShelf ? 58 : 0
        return clampFocusedHeight(header + 28 + promptContent + shelf)
    }

    func clampOverviewHeight(_ height: CGFloat) -> CGFloat {
        min(maximumExpandedHeight, max(minimumOverviewHeight, Self.roundHeight(height)))
    }

    func clampFocusedHeight(_ height: CGFloat) -> CGFloat {
        min(maximumExpandedHeight, max(minimumFocusedHeight, Self.roundHeight(height)))
    }

    static func materiallyDifferent(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) >= 4
    }

    private static func roundHeight(_ height: CGFloat) -> CGFloat {
        (height / 2).rounded() * 2
    }

    static func physicalNotchWidth(metrics: NotchScreenMetrics) -> CGFloat? {
        guard metrics.hasPhysicalNotch,
              let left = metrics.auxiliaryTopLeftArea,
              let right = metrics.auxiliaryTopRightArea
        else { return nil }

        let gap = right.minX - left.maxX
        guard gap > 80, gap < 400 else { return nil }
        return gap
    }

    func panelFrame(on screenFrame: CGRect, expanded: Bool, compactRevealed: Bool = false) -> CGRect {
        let size = expanded ? expandedSize : compactSize(revealed: compactRevealed)
        return panelFrame(on: screenFrame, size: size)
    }

    func panelFrame(on screenFrame: CGRect, size: CGSize) -> CGRect {
        return CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height)
    }
}
