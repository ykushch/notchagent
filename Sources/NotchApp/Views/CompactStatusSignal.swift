import HerdrClient
import SwiftUI

struct CompactSignalSnapshot: Sendable, Equatable {
    let status: RollupStatus
    let count: Int
    let enteredAt: Date?
    let triggerRevision: Int
}

struct CompactSignalTracker: Sendable, Equatable {
    private(set) var status: RollupStatus?
    private(set) var enteredAt: Date?
    private(set) var triggerRevision = 0

    mutating func observe(
        status newStatus: RollupStatus,
        newlyBlockedCount: Int = 0,
        newlyFinishedCount: Int = 0,
        at now: Date
    ) {
        let changed = status != newStatus
        if changed {
            status = newStatus
            enteredAt = now
            triggerRevision &+= 1
        }

        if newStatus == .blocked, newlyBlockedCount > 0 {
            enteredAt = now
            if !changed { triggerRevision &+= 1 }
        } else if newStatus == .done, newlyFinishedCount > 0 {
            enteredAt = now
            if !changed { triggerRevision &+= 1 }
        }
    }
}

struct CompactSignalStyle: Sendable, Equatable {
    static let idleRecessionDelay: TimeInterval = 10
    static let doneDisplayDuration: TimeInterval = 60
    static let baseWidth: CGFloat = 40
    static let countWidthStep: CGFloat = 6
    static let maximumCount = 5
    static let recessedWidth: CGFloat = 28

    let visualStatus: RollupStatus
    let width: CGFloat
    let opacity: Double

    static func shouldPulse(
        _ snapshot: CompactSignalSnapshot,
        reduceMotion: Bool
    ) -> Bool {
        snapshot.status == .blocked && !reduceMotion
    }

    static func resolve(_ snapshot: CompactSignalSnapshot, at now: Date) -> Self {
        let elapsed = snapshot.enteredAt.map {
            max(0, now.timeIntervalSince($0))
        }

        if snapshot.status == .done,
           let elapsed,
           elapsed >= doneDisplayDuration {
            return Self(visualStatus: .idle, width: recessedWidth, opacity: 0.3)
        }

        if snapshot.status == .idle,
           let elapsed,
           elapsed >= idleRecessionDelay {
            return Self(visualStatus: .idle, width: recessedWidth, opacity: 0.3)
        }

        let count = min(max(1, snapshot.count), maximumCount)
        let width = baseWidth + CGFloat(count - 1) * countWidthStep
        return Self(visualStatus: snapshot.status, width: width, opacity: 1)
    }
}

struct CompactStatusBar: View {
    let snapshot: CompactSignalSnapshot
    let style: CompactSignalStyle
    let reduceMotion: Bool

    @State private var isPulsing = false
    @State private var pulseTask: Task<Void, Never>?

    var body: some View {
        Capsule()
            .fill(NotchPalette.status(style.visualStatus))
            .frame(width: style.width, height: 3)
            .opacity(style.opacity)
            .scaleEffect(
                x: isPulsing ? 1.08 : 1,
                y: isPulsing ? 1.5 : 1)
            .shadow(
                color: isPulsing ? NotchPalette.blocked.opacity(0.68) : .clear,
                radius: isPulsing ? 6 : 0)
            .animation(.easeInOut(duration: 0.6), value: style)
            .onChange(of: snapshot.triggerRevision, initial: true) {
                startBlockedPulse()
            }
            .onDisappear {
                pulseTask?.cancel()
                pulseTask = nil
            }
    }

    private func startBlockedPulse() {
        pulseTask?.cancel()
        isPulsing = false
        guard CompactSignalStyle.shouldPulse(
            snapshot,
            reduceMotion: reduceMotion
        ) else { return }

        pulseTask = Task { @MainActor in
            for _ in 0..<3 {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    isPulsing = true
                }
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    isPulsing = false
                }
                try? await Task.sleep(for: .milliseconds(220))
            }
        }
    }
}

#if DEBUG
private struct CompactStatusSignalGallery: View {
    private let now = Date(timeIntervalSince1970: 10_000)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            signal("working", status: .working, count: 3, elapsed: 0)
            signal("blocked", status: .blocked, count: 2, elapsed: 0)
            signal("done", status: .done, count: 1, elapsed: 0)
            signal("idle", status: .idle, count: 4, elapsed: 0)
            signal("idle · asleep", status: .idle, count: 4, elapsed: 10)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(NotchPalette.secondaryText)
        .padding(20)
        .background(NotchPalette.surface)
    }

    private func signal(
        _ label: String,
        status: RollupStatus,
        count: Int,
        elapsed: TimeInterval
    ) -> some View {
        let snapshot = CompactSignalSnapshot(
            status: status,
            count: count,
            enteredAt: now,
            triggerRevision: 0)
        let style = CompactSignalStyle.resolve(
            snapshot,
            at: now.addingTimeInterval(elapsed))
        return HStack {
            Text(label).frame(width: 110, alignment: .leading)
            CompactStatusBar(
                snapshot: snapshot,
                style: style,
                reduceMotion: true)
            Spacer()
        }
        .frame(width: 240)
    }
}

#Preview("Compact status palette") {
    CompactStatusSignalGallery()
}
#endif
