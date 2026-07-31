import AppKit
import Testing
@testable import NotchApp

@MainActor
@Suite("Screen-save window")
struct ScreenSaveWindowTests {
    @Test("custom window uses an implemented designated initializer")
    func initializesWithoutRedispatchingToAnUnimplementedInitializer() {
        _ = NSApplication.shared
        let frame = NSRect(x: 40, y: 60, width: 800, height: 450)
        let window = ScreenSaveWindow(
            frame: frame,
            contentView: NSView(frame: frame),
            onDismiss: {})
        defer { window.orderOut(nil) }

        #expect(window.frame == frame)
        #expect(window.level == .screenSaver)
        #expect(window.canBecomeKey)
    }
}
