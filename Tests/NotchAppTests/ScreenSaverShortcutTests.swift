import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import NotchApp

@MainActor
@Suite("Screen saver shortcut")
struct ScreenSaverShortcutTests {
    @Test("Normalizes a recorded shortcut and matches relevant modifiers only")
    func normalizationAndMatching() {
        let shortcut = GlobalKeyboardShortcut(
            keyCode: 1,
            flags: [.control, .option, .capsLock],
            characters: "s")!

        #expect(shortcut.displayName == "⌃⌥S")
        #expect(shortcut.matches(
            keyCode: 1, flags: [.control, .option, .capsLock, .numericPad]))
        #expect(!shortcut.matches(keyCode: 1, flags: [.control]))
        #expect(!shortcut.matches(keyCode: 2, flags: [.control, .option]))
    }

    @Test("Rejects shortcuts without Command or Control")
    func requiresSafeModifier() {
        #expect(GlobalKeyboardShortcut(
            keyCode: 1, flags: [.option], characters: "s") == nil)
        #expect(GlobalKeyboardShortcut(
            keyCode: 1, flags: [.shift, .option], characters: "s") == nil)
    }

    @Test("Detects collisions with existing agent actions")
    func detectsAgentConflict() {
        let shortcut = GlobalKeyboardShortcut(
            keyCode: 16, flags: [.control, .option], characters: "y")!
        #expect(shortcut.conflictsWithAgentHotkeys(modifier: .controlOption))
        #expect(!shortcut.conflictsWithAgentHotkeys(modifier: .command))
    }

    @Test("Screen saver shortcut persists through Settings")
    func persistence() throws {
        let suiteName = "NotchAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        #expect(settings.screenSaverShortcut == nil)

        let shortcut = GlobalKeyboardShortcut(
            keyCode: 1, flags: [.control, .option], characters: "s")!
        settings.screenSaverShortcut = shortcut

        #expect(Settings(defaults: defaults).screenSaverShortcut == shortcut)
        settings.screenSaverShortcut = nil
        #expect(Settings(defaults: defaults).screenSaverShortcut == nil)
    }

    @Test("Automation requests permission with a harmless query")
    func automationPermission() {
        var scripts: [String] = []
        let automation = SystemScreenSaverAutomation { source in
            scripts.append(source)
            return AppleScriptExecution(succeeded: true, errorNumber: nil, message: nil)
        }

        automation.requestPermission()

        #expect(automation.state == .authorized)
        #expect(scripts.count == 1)
        #expect(scripts[0].contains("get name of current screen saver"))
    }

    @Test("Automation starts the selected saver through System Events")
    func automationStart() {
        var script = ""
        let automation = SystemScreenSaverAutomation { source in
            script = source
            return AppleScriptExecution(succeeded: true, errorNumber: nil, message: nil)
        }

        #expect(automation.start())
        #expect(script.contains("start current screen saver"))
        #expect(automation.state == .authorized)
    }

    @Test("Automation reports denied Apple Events access")
    func automationDenied() {
        let automation = SystemScreenSaverAutomation { _ in
            AppleScriptExecution(succeeded: false, errorNumber: -1743, message: "Not permitted")
        }

        automation.requestPermission()

        #expect(automation.state == .denied)
        #expect(automation.message?.contains("Automation") == true)
    }

    @Test("Global screen saver shortcut registers independently and invokes its action")
    func registrarInvokesAction() {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.screenSaverShortcut = GlobalKeyboardShortcut(
            keyCode: 1, flags: [.control, .option], characters: "s")
        let backend = FakeScreenSaverHotKeyBackend()
        var started = false
        let registrar = ScreenSaverHotKeyRegistrar(
            settings: settings,
            onPressed: { started = true },
            backend: backend)

        registrar.start()
        #expect(registrar.state == .ready)
        #expect(backend.registered == settings.screenSaverShortcut)

        backend.onPressed?()
        #expect(started)

        registrar.stop()
        #expect(backend.stopCount == 1)
    }

    @Test("Registration failures are surfaced instead of silently accepting a shortcut")
    func registrarSurfacesConflict() {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.screenSaverShortcut = GlobalKeyboardShortcut(
            keyCode: 1, flags: [.control, .option], characters: "s")
        let backend = FakeScreenSaverHotKeyBackend()
        backend.nextState = .conflict
        let registrar = ScreenSaverHotKeyRegistrar(
            settings: settings,
            onPressed: {},
            backend: backend)

        registrar.start()

        #expect(registrar.state == .conflict)
        #expect(registrar.state.message?.contains("reserved") == true)
    }

    @Test("Shortcut modifiers map to the Carbon global-hotkey API")
    func carbonModifierMapping() {
        let shortcut = GlobalKeyboardShortcut(
            keyCode: 1,
            flags: [.command, .control, .option, .shift],
            characters: "s")!
        let expected = UInt32(cmdKey | controlKey | optionKey | shiftKey)

        #expect(shortcut.carbonModifiers == expected)
    }
}

@MainActor
private final class FakeScreenSaverHotKeyBackend: ScreenSaverHotKeyRegistering {
    var onPressed: (() -> Void)?
    var nextState: ScreenSaverHotKeyRegistrationState = .ready
    private(set) var registered: GlobalKeyboardShortcut?
    private(set) var unregisterCount = 0
    private(set) var stopCount = 0

    func register(_ shortcut: GlobalKeyboardShortcut) -> ScreenSaverHotKeyRegistrationState {
        registered = shortcut
        return nextState
    }

    func unregister() {
        registered = nil
        unregisterCount += 1
    }

    func stop() {
        registered = nil
        stopCount += 1
    }
}
