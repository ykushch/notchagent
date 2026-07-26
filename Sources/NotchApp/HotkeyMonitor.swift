import AppKit

@MainActor
final class HotkeyMonitor {
    fileprivate let viewModel: NotchViewModel
    private let settings: Settings
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?

    init(viewModel: NotchViewModel, settings: Settings) { self.viewModel = viewModel; self.settings = settings }

    func start() {
        refreshPermissionState()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissionState() }
        }
        if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
    }

    func stop() { permissionTimer?.invalidate(); permissionTimer = nil; removeTap() }

    private func refreshPermissionState() {
        let granted = Self.accessibilityGranted()
        viewModel.accessibilityMissing = !granted
        if granted { installIfPermitted() } else { removeTap() }
    }

    private func installIfPermitted() {
        guard Self.accessibilityGranted() else { viewModel.accessibilityMissing = true; return }
        guard eventTap == nil else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let mask = 1 << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: hotkeyTapCallback, userInfo: selfPtr),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap; runLoopSource = source; viewModel.accessibilityMissing = false
    }

    private func removeTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        runLoopSource = nil; eventTap = nil
    }

    fileprivate func handleKey(keyCode: Int64, flags: NSEvent.ModifierFlags, characters: String?) -> Bool {
        guard viewModel.selected != nil else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard flags.intersection(relevant) == settings.hotkeyModifier.flags else { return false }
        switch keyCode {
        case 36: viewModel.replySelected(); return true
        case 123: viewModel.navigateStep(-1); return true
        case 124: viewModel.navigateStep(1); return true
        case 125: viewModel.sendArrowToSelected("down"); return true
        case 126: viewModel.sendArrowToSelected("up"); return true
        default: break
        }
        switch characters?.lowercased() {
        case "y": viewModel.approveSelected(); return true
        case "n": viewModel.denySelected(); return true
        case let value?:
            if let number = Int(value), (1...9).contains(number) { viewModel.answerSelected(index: number - 1); return true }
        default: break
        }
        return false
    }

    fileprivate func reenableTap() { if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) } }
    static func accessibilityGranted() -> Bool { AXIsProcessTrusted() }
    static func promptForAccessibility() {
        let promptKey = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { monitor.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown, let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = nsEvent.modifierFlags
    let characters = nsEvent.charactersIgnoringModifiers
    let consumed = MainActor.assumeIsolated {
        monitor.handleKey(keyCode: keyCode, flags: flags, characters: characters)
    }
    return consumed ? nil : Unmanaged.passUnretained(event)
}
