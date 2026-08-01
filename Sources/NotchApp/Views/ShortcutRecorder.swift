import AppKit
import SwiftUI

/// A small AppKit-backed field because SwiftUI's normal text fields do not
/// expose the physical key code needed for a reliable global shortcut.
struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: GlobalKeyboardShortcut?
    @Binding var isRecording: Bool
    let onRecorded: (GlobalKeyboardShortcut) -> Void
    let onCleared: () -> Void
    let onInvalid: (String) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.shortcut = shortcut
        view.isRecording = isRecording
        view.onStartRecording = { isRecording = true }
        view.onCancelRecording = { isRecording = false }
        view.onRecorded = { value in
            onRecorded(value)
            isRecording = false
        }
        view.onCleared = {
            onCleared()
            isRecording = false
        }
        view.onInvalid = onInvalid
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.shortcut = shortcut
        nsView.isRecording = isRecording
        nsView.onStartRecording = { isRecording = true }
        nsView.onCancelRecording = { isRecording = false }
        nsView.onRecorded = { value in
            onRecorded(value)
            isRecording = false
        }
        nsView.onCleared = {
            onCleared()
            isRecording = false
        }
        nsView.onInvalid = onInvalid
        if isRecording, nsView.window?.firstResponder !== nsView {
            nsView.window?.makeFirstResponder(nsView)
        }
        nsView.needsDisplay = true
    }
}

@MainActor
final class ShortcutRecorderNSView: NSView {
    var shortcut: GlobalKeyboardShortcut?
    var isRecording = false
    var onStartRecording: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    var onRecorded: ((GlobalKeyboardShortcut) -> Void)?
    var onCleared: (() -> Void)?
    var onInvalid: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            onCancelRecording?()
        } else {
            onStartRecording?()
            window?.makeFirstResponder(self)
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        if event.keyCode == 53 { // Escape cancels without changing the value.
            onCancelRecording?()
            return
        }
        if event.keyCode == 51 { // Delete clears the saved shortcut.
            onCleared?()
            return
        }
        guard let shortcut = GlobalKeyboardShortcut(
            keyCode: Int64(event.keyCode),
            flags: event.modifierFlags,
            characters: event.charactersIgnoringModifiers) else {
            onInvalid?("Use a key with Command or Control, such as ⌃⌥S.")
            return
        }
        onRecorded?(shortcut)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let title = isRecording ? "Press shortcut…" : (shortcut?.displayName ?? "Set Shortcut…")
        let color: NSColor = isRecording ? .controlAccentColor : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: color
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes)
    }
}
