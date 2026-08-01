import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut that can be persisted and matched against a global
/// `CGEvent`. The physical key code is stored so the shortcut remains stable
/// across keyboard layouts; the label is only used for presentation.
struct GlobalKeyboardShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt16
    let modifierRawValue: UInt
    let keyLabel: String

    init?(keyCode: Int64, flags: NSEvent.ModifierFlags, characters: String?) {
        guard let keyCode = UInt16(exactly: keyCode) else { return nil }
        let modifiers = flags.intersection(Self.relevantModifierFlags)
        guard modifiers.contains(.command) || modifiers.contains(.control) else {
            return nil
        }
        guard let keyLabel = Self.label(
            keyCode: keyCode, characters: characters),
              !keyLabel.isEmpty else {
            return nil
        }
        self.keyCode = keyCode
        modifierRawValue = modifiers.rawValue
        self.keyLabel = keyLabel
    }

    init(keyCode: UInt16, modifierRawValue: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifierRawValue = modifierRawValue & Self.relevantModifierFlags.rawValue
        self.keyLabel = keyLabel
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierRawValue)
    }

    var displayName: String {
        "\(Self.symbols(for: modifiers))\(keyLabel)"
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    func matches(keyCode: Int64, flags: NSEvent.ModifierFlags) -> Bool {
        guard let eventKeyCode = UInt16(exactly: keyCode), self.keyCode == eventKeyCode else {
            return false
        }
        let eventModifiers = flags.intersection(Self.relevantModifierFlags)
        return eventModifiers == modifiers
    }

    /// The existing agent hotkeys use one shared modifier combination with a
    /// small fixed set of keys. Rejecting those combinations avoids making a
    /// newly recorded screen-saver shortcut silently change agent behavior.
    func conflictsWithAgentHotkeys(modifier: HotkeyModifier) -> Bool {
        guard modifiers == modifier.flags else { return false }
        switch keyCode {
        case 36, 123, 124, 125, 126: // Return and arrows
            return true
        default:
            break
        }
        return ["Y", "N", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
            .contains(keyLabel)
    }

    static let relevantModifierFlags: NSEvent.ModifierFlags = [
        .command, .control, .option, .shift
    ]

    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }

    private static func label(keyCode: UInt16, characters: String?) -> String? {
        switch keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            guard let characters, !characters.isEmpty else { return nil }
            return characters.uppercased()
        }
    }
}
