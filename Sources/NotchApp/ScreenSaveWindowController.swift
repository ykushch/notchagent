import AppKit
import SwiftUI

/// Owns one screen-level window per connected display. The windows share the
/// app's existing model; this presentation never opens another herdr connection.
@MainActor
final class ScreenSaveWindowController {
    private let model: NotchViewModel
    private let onDismiss: () -> Void
    private var windows: [ScreenSaveWindow] = []
    private var cursorIsHidden = false

    init(model: NotchViewModel, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
    }

    func show() {
        guard windows.isEmpty else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        windows = screens.enumerated().map { index, screen in
            let root = ScreenSaveView(
                model: model, screenIndex: index, screenCount: screens.count)
            let hostingView = NSHostingView(rootView: root)
            return ScreenSaveWindow(
                frame: screen.frame, contentView: hostingView,
                onDismiss: { [weak self] in self?.onDismiss() })
        }

        NSCursor.hide()
        cursorIsHidden = true
        for window in windows { window.orderFrontRegardless() }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
    }

    func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        if cursorIsHidden {
            NSCursor.unhide()
            cursorIsHidden = false
        }
    }
}

/// A borderless window that behaves like an application-owned screen saver.
/// A short mouse grace period avoids dismissing immediately because of the event
/// that activated it; after that, deliberate input exits from every display.
@MainActor
final class ScreenSaveWindow: NSWindow {
    private let onDismiss: () -> Void
    private let shownAt = Date()
    private let initialMouseLocation = NSEvent.mouseLocation
    private var didRequestDismiss = false

    init(
        frame: NSRect,
        contentView: NSView,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        // `NSWindow.init(..., screen:)` is a convenience initializer that sends
        // `init(contentRect:styleMask:backing:defer:)` back to the dynamic class.
        // An NSWindow subclass does not inherit that initializer once it declares
        // its own designated initializer, so using the screen variant traps at
        // runtime. Call the superclass's designated initializer directly.
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        self.contentView = contentView
        setFrame(frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .scrollWheel, .swipe, .magnify, .rotate, .gesture:
            requestDismiss()
            return
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let location = NSEvent.mouseLocation
            let distance = hypot(
                location.x - initialMouseLocation.x,
                location.y - initialMouseLocation.y)
            if Date().timeIntervalSince(shownAt) > 0.6, distance >= 14 {
                requestDismiss()
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    private func requestDismiss() {
        guard !didRequestDismiss else { return }
        didRequestDismiss = true
        onDismiss()
    }
}
