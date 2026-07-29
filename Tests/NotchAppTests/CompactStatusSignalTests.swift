import AppKit
import HerdrClient
import SwiftUI
import Testing
@testable import NotchApp

@Suite("Compact status signal")
struct CompactStatusSignalTests {
    private let start = Date(timeIntervalSince1970: 10_000)

    @Test("count changes width and caps at five agents")
    func countWidth() {
        let one = style(status: .working, count: 1, elapsed: 0)
        let five = style(status: .working, count: 5, elapsed: 0)
        let many = style(status: .working, count: 12, elapsed: 0)

        #expect(one.width == 40)
        #expect(five.width == 64)
        #expect(many.width == five.width)
    }

    @Test("idle recedes after ten seconds")
    func idleRecession() {
        let awake = style(status: .idle, count: 3, elapsed: 9.99)
        let sleeping = style(status: .idle, count: 3, elapsed: 10)

        #expect(awake.visualStatus == .idle)
        #expect(awake.width == 52)
        #expect(awake.opacity == 1)
        #expect(sleeping.width == 28)
        #expect(sleeping.opacity == 0.3)
    }

    @Test("done visually decays without changing the semantic snapshot")
    func doneDecay() {
        let snapshot = CompactSignalSnapshot(
            status: .done,
            count: 2,
            enteredAt: start,
            triggerRevision: 1)
        let recent = CompactSignalStyle.resolve(
            snapshot,
            at: start.addingTimeInterval(59.99))
        let decayed = CompactSignalStyle.resolve(
            snapshot,
            at: start.addingTimeInterval(60))

        #expect(snapshot.status == .done)
        #expect(recent.visualStatus == .done)
        #expect(recent.opacity == 1)
        #expect(decayed.visualStatus == .idle)
        #expect(decayed.width == 28)
        #expect(decayed.opacity == 0.3)
    }

    @Test("blocked pulses are transition-triggered and honor Reduce Motion")
    func blockedPulsePolicy() {
        let blocked = CompactSignalSnapshot(
            status: .blocked,
            count: 1,
            enteredAt: start,
            triggerRevision: 3)
        let working = CompactSignalSnapshot(
            status: .working,
            count: 1,
            enteredAt: start,
            triggerRevision: 4)

        #expect(CompactSignalStyle.shouldPulse(blocked, reduceMotion: false))
        #expect(!CompactSignalStyle.shouldPulse(blocked, reduceMotion: true))
        #expect(!CompactSignalStyle.shouldPulse(working, reduceMotion: false))
    }

    @Test("tracker retriggers blocked and done signals without looping")
    func trackerTransitions() {
        var tracker = CompactSignalTracker()
        tracker.observe(status: .working, at: start)
        #expect(tracker.triggerRevision == 1)
        #expect(tracker.enteredAt == start)

        tracker.observe(status: .working, at: start.addingTimeInterval(1))
        #expect(tracker.triggerRevision == 1)
        #expect(tracker.enteredAt == start)

        tracker.observe(
            status: .blocked,
            newlyBlockedCount: 1,
            at: start.addingTimeInterval(2))
        #expect(tracker.triggerRevision == 2)
        #expect(tracker.enteredAt == start.addingTimeInterval(2))

        tracker.observe(
            status: .blocked,
            newlyBlockedCount: 1,
            at: start.addingTimeInterval(3))
        #expect(tracker.triggerRevision == 3)
        #expect(tracker.enteredAt == start.addingTimeInterval(3))

        tracker.observe(
            status: .done,
            newlyFinishedCount: 1,
            at: start.addingTimeInterval(4))
        #expect(tracker.triggerRevision == 4)
        #expect(tracker.enteredAt == start.addingTimeInterval(4))
    }

    @Test("semantic status colors match the committed palette")
    func statusPalette() throws {
        #expect(try hex(NotchPalette.status(.working)) == 0x60B0FF)
        #expect(try hex(NotchPalette.status(.blocked)) == 0xFB8371)
        #expect(try hex(NotchPalette.status(.done)) == 0x5AC576)
        #expect(try hex(NotchPalette.status(.idle)) == 0x74716C)
    }

    private func style(
        status: RollupStatus,
        count: Int,
        elapsed: TimeInterval
    ) -> CompactSignalStyle {
        CompactSignalStyle.resolve(
            CompactSignalSnapshot(
                status: status,
                count: count,
                enteredAt: start,
                triggerRevision: 0),
            at: start.addingTimeInterval(elapsed))
    }

    private func hex(_ color: Color) throws -> UInt32 {
        let converted = try #require(
            NSColor(color).usingColorSpace(.sRGB))
        let red = UInt32((converted.redComponent * 255).rounded())
        let green = UInt32((converted.greenComponent * 255).rounded())
        let blue = UInt32((converted.blueComponent * 255).rounded())
        return red << 16 | green << 8 | blue
    }
}
