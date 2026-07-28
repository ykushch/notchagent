import AppKit
import HerdrClient
import Observation
import SwiftUI

@MainActor
final class NotchWindowController {
    private let viewModel: NotchViewModel
    private let settings: Settings
    private let panel: NotchPanel
    private let hostingView: NSHostingView<PlaceholderNotchView>
    private let surfaceState: NotchSurfaceState

    private var currentScreenNumber: NSNumber?
    private var pendingScreenNumber: NSNumber?
    private var pendingScreenSince: ContinuousClock.Instant?
    private var screenPollTimer: Timer?
    private var screenParametersObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var transitionRevision = 0

    init(viewModel: NotchViewModel, settings: Settings) {
        self.viewModel = viewModel
        self.settings = settings
        let screen = Self.preferredScreen(for: settings)
        let geometry = NotchGeometry(metrics: NotchScreenMetrics(screen: screen))
        let frame = geometry.panelFrame(on: screen.frame, size: geometry.compactCanvasSize)
        let surfaceState = NotchSurfaceState(
            geometry: geometry,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            compactIndicatorMode: settings.compactIndicatorMode)
        self.surfaceState = surfaceState
        panel = NotchPanel(contentRect: frame)
        hostingView = NSHostingView(rootView: PlaceholderNotchView(
            model: viewModel, surface: surfaceState))
        currentScreenNumber = Self.screenNumber(screen)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    func show() {
        applyPresentation()
        panel.orderFrontRegardless()
        observePresentation()
        observeScreenChanges()
        observeAccessibilityOptions()
        observeMouseClicks()
        configureScreenPolling()
    }

    func tearDown() {
        screenPollTimer?.invalidate()
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        panel.orderOut(nil)
    }

    private func observePresentation() {
        withObservationTracking {
            _ = viewModel.presentation
            _ = viewModel.selectedInteractionSizingIdentity
            _ = viewModel.agentCount
            _ = viewModel.connection
            _ = viewModel.accessibilityMissing
            _ = viewModel.jumpNotice
            _ = settings.displayPlacement
            _ = settings.preferredTerminal
            _ = settings.customTerminalAppName
            _ = settings.customTerminalBundleID
            _ = settings.compactIndicatorMode
            _ = surfaceState.requestedExpandedHeight
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.configureScreenPolling()
                self?.screenSelectionMayHaveChanged()
                self?.applyPresentation()
                self?.observePresentation()
            }
        }
    }

    private func observeScreenChanges() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A disconnected display can leave a panel at a now-invalid frame.
                // Re-resolve immediately and restore status-bar ordering.
                self.adoptPreferredScreenImmediately()
                self.applyPresentation()
                self.panel.orderFrontRegardless()
            }
        }
    }

    private func observeAccessibilityOptions() {
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.surfaceState.reduceMotion =
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.applyPresentation()
            }
        }
    }

    private func observeMouseClicks() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }
        let mouseDownEvents: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: mouseDownEvents
        ) { [weak self] event in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.collapseIfClickIsOutsidePanel(at: location) }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: mouseDownEvents
        ) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.collapseIfClickIsOutsidePanel(at: location) }
        }
    }

    private func collapseIfClickIsOutsidePanel(at location: NSPoint) {
        guard viewModel.isExpanded, !panel.frame.contains(location) else { return }
        viewModel.collapse()
    }

    private func configureScreenPolling() {
        guard settings.displayPlacement != .notchDisplay else {
            screenPollTimer?.invalidate()
            screenPollTimer = nil
            return
        }
        guard screenPollTimer == nil else { return }

        // NSScreen.main follows keyboard focus but has no dedicated notification.
        // Follow modes poll cheaply and require a stable candidate before moving.
        screenPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.screenSelectionMayHaveChanged() }
        }
    }

    private func screenSelectionMayHaveChanged() {
        let candidate = Self.preferredScreen(for: settings)
        let candidateNumber = Self.screenNumber(candidate)
        guard candidateNumber != currentScreenNumber else {
            pendingScreenNumber = nil
            pendingScreenSince = nil
            return
        }

        if pendingScreenNumber != candidateNumber {
            pendingScreenNumber = candidateNumber
            pendingScreenSince = .now
            return
        }

        guard let pendingScreenSince,
              ContinuousClock.now - pendingScreenSince >= .seconds(1)
        else { return }
        currentScreenNumber = candidateNumber
        pendingScreenNumber = nil
        self.pendingScreenSince = nil
        applyPresentation(on: candidate)
        panel.orderFrontRegardless()
    }

    private func adoptPreferredScreenImmediately() {
        let screen = Self.preferredScreen(for: settings)
        currentScreenNumber = Self.screenNumber(screen)
        pendingScreenNumber = nil
        pendingScreenSince = nil
    }

    private func applyPresentation(on explicitScreen: NSScreen? = nil) {
        let screen = explicitScreen ?? Self.screen(
            numbered: currentScreenNumber) ?? Self.preferredScreen(for: settings)
        let geometry = NotchGeometry(metrics: NotchScreenMetrics(screen: screen))
        surfaceState.updateCompactIndicatorMode(settings.compactIndicatorMode)
        if surfaceState.geometry != geometry {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { surfaceState.updateGeometry(geometry) }
        }
        let target = viewModel.presentation
        prepareAdaptiveHeight(for: target, geometry: geometry)
        transition(to: target, on: screen, geometry: geometry)
    }

    private func prepareAdaptiveHeight(
        for target: NotchPresentation,
        geometry: NotchGeometry
    ) {
        switch target {
        case .compact:
            break
        case .overview:
            let bannerCount = (viewModel.connection == .unavailable ? 1 : 0)
                + (viewModel.accessibilityMissing ? 1 : 0)
                + (viewModel.jumpNotice == nil ? 0 : 1)
            surfaceState.prepareOverview(estimatedHeight: geometry.overviewHeight(
                agentCount: viewModel.agentCount,
                bannerCount: bannerCount,
                hasUpdateBanner: viewModel.pendingUpdate != nil))
        case .focused:
            guard let identity = viewModel.selectedInteractionSizingIdentity else { return }
            let interaction = viewModel.selectedInteraction
            surfaceState.prepareFocused(
                identity: identity,
                estimatedHeight: geometry.focusedHeight(
                    choiceCount: interaction?.choices.count ?? 0,
                    hasEvidence: interaction?.contentEvidence != nil,
                    hasActionShelf: viewModel.selectedInteractionState != nil))
        }
    }

    private func transition(
        to target: NotchPresentation,
        on screen: NSScreen,
        geometry: NotchGeometry
    ) {
        transitionRevision &+= 1
        let revision = transitionRevision

        if target.isExpanded {
            surfaceState.clearCompactHover()
            let targetSize = surfaceState.requestedExpandedSize
            let currentHeight = surfaceState.renderedExpandedHeight
            let isGrowing = targetSize.height >= currentHeight
            if isGrowing {
                setPanelFrame(geometry.panelFrame(on: screen.frame, size: targetSize))
            }
            panel.isInteractive = true

            guard surfaceState.presentation != target
                    || NotchGeometry.materiallyDifferent(currentHeight, targetSize.height)
            else {
                setPanelFrame(geometry.panelFrame(on: screen.frame, size: targetSize))
                return
            }
            let applyTarget = { [surfaceState] in
                surfaceState.presentation = target
                surfaceState.setRenderedExpandedHeight(targetSize.height)
            }
            guard let animation = surfaceState.animation else {
                applyTarget()
                setPanelFrame(geometry.panelFrame(on: screen.frame, size: targetSize))
                return
            }

            let finishShrink = { [weak self] in
                guard let self, self.transitionRevision == revision,
                      self.viewModel.presentation == target else { return }
                self.setPanelFrame(geometry.panelFrame(on: screen.frame, size: targetSize))
            }
            if surfaceState.presentation.isExpanded || !isGrowing {
                withAnimation(.easeInOut(duration: 0.2), completionCriteria: .logicallyComplete) {
                    applyTarget()
                } completion: {
                    Task { @MainActor in
                        if !isGrowing { finishShrink() }
                    }
                }
            } else {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, self.transitionRevision == revision,
                          self.viewModel.presentation == target else { return }
                    withAnimation(animation, applyTarget)
                }
            }
            return
        }

        panel.isInteractive = false
        guard surfaceState.presentation != .compact else {
            finishCollapse(revision: revision, screen: screen, geometry: geometry)
            return
        }
        guard let animation = surfaceState.animation else {
            surfaceState.presentation = .compact
            finishCollapse(revision: revision, screen: screen, geometry: geometry)
            return
        }

        withAnimation(animation, completionCriteria: .logicallyComplete) {
            surfaceState.presentation = .compact
        } completion: { [weak self] in
            Task { @MainActor in
                self?.finishCollapse(revision: revision, screen: screen, geometry: geometry)
            }
        }
    }

    private func finishCollapse(
        revision: Int,
        screen: NSScreen,
        geometry: NotchGeometry
    ) {
        guard transitionRevision == revision, !viewModel.isExpanded else { return }
        let frame = geometry.panelFrame(on: screen.frame, size: geometry.compactCanvasSize)
        setPanelFrame(
            frame,
            animated: !surfaceState.reduceMotion && surfaceState.presentation == .compact)
    }

    private func setPanelFrame(_ frame: CGRect, animated: Bool = false) {
        guard !NSEqualRects(panel.frame, frame) else { return }
        guard animated else {
            panel.setFrame(frame, display: true, animate: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private static func preferredScreen(for settings: Settings) -> NSScreen {
        let fallback = NSScreen.main ?? NSScreen.screens[0]
        switch settings.displayPlacement {
        case .notchDisplay:
            return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? fallback
        case .activeDisplay:
            return fallback
        case .terminalDisplay:
            return terminalScreen(profiles: settings.terminalProfiles) ?? fallback
        }
    }

    private static func terminalScreen(profiles: [TerminalProfile]) -> NSScreen? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let terminalPIDs = Set(NSWorkspace.shared.runningApplications.compactMap { app -> pid_t? in
            guard profiles.contains(where: {
                $0.bundleIdentifiers.contains(app.bundleIdentifier ?? "")
                    || $0.appName == app.localizedName
            })
            else { return nil }
            return app.processIdentifier
        })

        for info in windowInfo {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  terminalPIDs.contains(ownerPID),
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let quartzBounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary),
                  quartzBounds.width > 1, quartzBounds.height > 1
            else { continue }
            return screen(containingQuartzWindow: quartzBounds)
        }
        return nil
    }

    private static func screen(containingQuartzWindow quartzBounds: CGRect) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaBounds = CGRect(
            x: quartzBounds.minX,
            y: primary.frame.maxY - quartzBounds.maxY,
            width: quartzBounds.width,
            height: quartzBounds.height)
        guard let bestMatch = NSScreen.screens.max(by: { lhs, rhs in
            lhs.frame.intersection(cocoaBounds).area < rhs.frame.intersection(cocoaBounds).area
        }), bestMatch.frame.intersection(cocoaBounds).area > 0 else { return nil }
        return bestMatch
    }

    private static func screenNumber(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private static func screen(numbered number: NSNumber?) -> NSScreen? {
        guard let number else { return nil }
        return NSScreen.screens.first { screenNumber($0) == number }
    }

}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
