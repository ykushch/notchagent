import AppKit
import Combine
import Foundation
import ScreenSaver
import SwiftUI

/// Principal class loaded by macOS's ScreenSaverEngine. This process never
/// talks to herdr directly; it renders the status-only heartbeat published by
/// NotchAgent.
@MainActor
@objc(NotchAgentScreenSaverView)
final class NotchAgentScreenSaverView: ScreenSaverView {
    private let feed: ScreenSaverFeed
    private let hostingView: NSHostingView<ScreenSaverRootView>

    override init?(frame: NSRect, isPreview: Bool) {
        let feed = ScreenSaverFeed()
        self.feed = feed
        hostingView = NSHostingView(rootView: ScreenSaverRootView(feed: feed))
        super.init(frame: frame, isPreview: isPreview)

        animationTimeInterval = 1.0 / 30.0
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let screen = window?.screen else { return }
        let screens = NSScreen.screens
        let index = screens.firstIndex(where: { $0 === screen }) ?? 0
        let displayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { String($0.uint32Value) }
        feed.setScreenContext(
            displayID: displayID,
            screenIndex: index,
            screenCount: screens.count)
    }

    override func startAnimation() {
        super.startAnimation()
        feed.start()
    }

    override func stopAnimation() {
        feed.stop()
        super.stopAnimation()
    }
}

@MainActor
private final class ScreenSaverFeed: ObservableObject {
    @Published private(set) var snapshot = ScreenSaveSnapshot.unavailable()
    @Published private(set) var configuration = ScreenSaveConfiguration.default
    @Published private(set) var displayID: String?
    @Published private(set) var screenIndex = 0
    @Published private(set) var screenCount = 1
    private var refreshTask: Task<Void, Never>?

    func start() {
        reload(at: Date())
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                reload(at: Date())
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func setScreenContext(displayID: String?, screenIndex: Int, screenCount: Int) {
        self.displayID = displayID
        self.screenIndex = screenIndex
        self.screenCount = max(1, screenCount)
    }

    private func reload(at now: Date) {
        if let data = try? Data(contentsOf: ScreenSaveConfigurationLocation.fileURL()),
           let decoded = try? JSONDecoder().decode(ScreenSaveConfiguration.self, from: data) {
            configuration = decoded.validated()
        }
        do {
            let data = try Data(contentsOf: ScreenSaveSnapshotLocation.fileURL())
            snapshot = try JSONDecoder().decode(ScreenSaveSnapshot.self, from: data)
                .hidingStaleData(at: now)
        } catch {
            snapshot = .unavailable(at: now)
        }
    }
}

private struct ScreenSaverRootView: View {
    @ObservedObject var feed: ScreenSaverFeed

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScreenSaveStatusView(
                snapshot: feed.snapshot.hidingStaleData(at: context.date),
                configuration: feed.configuration,
                now: context.date,
                displayID: feed.displayID,
                screenIndex: feed.screenIndex,
                screenCount: feed.screenCount)
        }
    }
}
