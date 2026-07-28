import AppKit
import Testing
@testable import NotchApp

@Suite("Notch geometry")
struct NotchGeometryTests {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1_512, height: 982)

    @Test("Physical notch uses the auxiliary-area gap")
    func physicalNotchGap() {
        let metrics = NotchScreenMetrics(
            frame: screenFrame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 950),
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
            auxiliaryTopRightArea: CGRect(x: 856, y: 950, width: 656, height: 32))

        let geometry = NotchGeometry(metrics: metrics)

        #expect(NotchGeometry.physicalNotchWidth(metrics: metrics) == 200)
        #expect(geometry.compactSize(revealed: false) == CGSize(width: 208, height: 35))
        #expect(geometry.compactSize(revealed: true) == CGSize(width: 208, height: 44))
        #expect(geometry.compactCanvasSize == CGSize(width: 208, height: 44))
        #expect(geometry.topContentInset == 32)
    }

    @Test("A side Dock does not alter physical-notch width")
    func sideDockDoesNotAlterNotch() {
        let metrics = NotchScreenMetrics(
            frame: screenFrame,
            visibleFrame: CGRect(x: 80, y: 0, width: 1_432, height: 950),
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
            auxiliaryTopRightArea: CGRect(x: 856, y: 950, width: 656, height: 32))

        #expect(NotchGeometry(metrics: metrics).compactWidth == 208)
    }

    @Test("External displays use the compact floating fallback")
    func externalDisplayFallback() {
        let metrics = NotchScreenMetrics(
            frame: screenFrame,
            visibleFrame: CGRect(x: 0, y: 23, width: 1_512, height: 959),
            safeAreaTop: 0)

        let geometry = NotchGeometry(metrics: metrics)

        #expect(geometry.compactSize(revealed: false) == CGSize(width: 190, height: 3))
        #expect(geometry.compactSize(revealed: true) == CGSize(width: 190, height: 12))
        #expect(geometry.compactCanvasSize == CGSize(width: 190, height: 12))
        #expect(geometry.topContentInset == 0)
    }

    @Test("Compact and expanded frames stay top-centered")
    func topAnchoredFrames() {
        let geometry = NotchGeometry(metrics: NotchScreenMetrics(
            frame: screenFrame,
            visibleFrame: screenFrame,
            safeAreaTop: 0))

        let compact = geometry.panelFrame(on: screenFrame, expanded: false)
        let revealed = geometry.panelFrame(
            on: screenFrame, expanded: false, compactRevealed: true)
        let expanded = geometry.panelFrame(on: screenFrame, expanded: true)

        #expect(compact.maxY == screenFrame.maxY)
        #expect(expanded.maxY == screenFrame.maxY)
        #expect(compact.midX == screenFrame.midX)
        #expect(revealed.maxY == screenFrame.maxY)
        #expect(revealed.midX == screenFrame.midX)
        #expect(revealed.height == 12)
        #expect(expanded.midX == screenFrame.midX)
    }

    @Test("Expanded canvas clamps to a small visible frame")
    func expandedCanvasClamps() {
        let geometry = NotchGeometry(metrics: NotchScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 420, height: 500),
            visibleFrame: CGRect(x: 0, y: 0, width: 420, height: 400),
            safeAreaTop: 0))

        #expect(geometry.expandedSize.width == 396)
        #expect(geometry.expandedSize.height == 288)
    }

    @Test("Overview height follows small session counts and caps large lists")
    func adaptiveOverviewHeight() {
        let geometry = NotchGeometry(metrics: NotchScreenMetrics(
            frame: screenFrame,
            visibleFrame: screenFrame,
            safeAreaTop: 0))

        #expect(geometry.overviewHeight(agentCount: 0, bannerCount: 0) == 244)
        #expect(geometry.overviewHeight(agentCount: 1, bannerCount: 0) == 190)
        #expect(geometry.overviewHeight(agentCount: 2, bannerCount: 0) == 192)
        #expect(geometry.overviewHeight(agentCount: 3, bannerCount: 0) == 250)
        #expect(geometry.overviewHeight(agentCount: 6, bannerCount: 0) == 420)
    }

    @Test("Overview warnings occupy natural space")
    func adaptiveOverviewBanners() {
        let geometry = NotchGeometry(metrics: NotchScreenMetrics(
            frame: screenFrame,
            visibleFrame: screenFrame,
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
            auxiliaryTopRightArea: CGRect(x: 856, y: 950, width: 656, height: 32)))

        #expect(geometry.overviewHeight(agentCount: 2, bannerCount: 1) == 272)
        #expect(geometry.overviewHeight(agentCount: 2, bannerCount: 2) == 322)
    }

    @Test("The update notice reserves more room than a one-line banner")
    func adaptiveOverviewUpdateBanner() {
        let geometry = NotchGeometry(metrics: NotchScreenMetrics(
            frame: screenFrame,
            visibleFrame: screenFrame,
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
            auxiliaryTopRightArea: CGRect(x: 856, y: 950, width: 656, height: 32)))

        let plain = geometry.overviewHeight(agentCount: 2, bannerCount: 0)
        let oneBanner = geometry.overviewHeight(agentCount: 2, bannerCount: 1)
        let withUpdate = geometry.overviewHeight(agentCount: 2, bannerCount: 0, hasUpdateBanner: true)

        #expect(withUpdate > oneBanner)
        // Heights round to even values, so compare the reserved space, not an
        // exact sum.
        #expect(abs(withUpdate - plain - NotchGeometry.overviewUpdateBannerHeight - 7) <= 2)
        // Stacking the update notice on top of a warning still fits the cap.
        #expect(geometry.overviewHeight(agentCount: 2, bannerCount: 1, hasUpdateBanner: true)
            <= geometry.maximumExpandedHeight)
    }

    @Test("Requested heights are rounded, clamped, and top-anchored")
    func requestedExpandedFrame() {
        let geometry = NotchGeometry(metrics: NotchScreenMetrics(
            frame: screenFrame,
            visibleFrame: screenFrame,
            safeAreaTop: 0))
        let size = geometry.expandedSize(requestedHeight: 251)
        let frame = geometry.panelFrame(on: screenFrame, size: size)

        #expect(size == CGSize(width: 520, height: 252))
        #expect(frame.maxY == screenFrame.maxY)
        #expect(frame.midX == screenFrame.midX)
        #expect(geometry.expandedSize(requestedHeight: 900).height == 420)
    }

    @Test("Sub-four-point measurement noise is ignored")
    func materialHeightThreshold() {
        #expect(!NotchGeometry.materiallyDifferent(250, 253))
        #expect(NotchGeometry.materiallyDifferent(250, 254))
    }
}
