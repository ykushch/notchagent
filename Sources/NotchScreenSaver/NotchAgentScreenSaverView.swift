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

    private func reload(at now: Date) {
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
                now: context.date)
        }
    }
}
