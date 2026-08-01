import Carbon.HIToolbox
import Observation

enum ScreenSaverHotKeyRegistrationState: Equatable {
    case notConfigured
    case ready
    case conflict
    case unavailable(OSStatus)

    var statusText: String {
        switch self {
        case .notConfigured: "Not configured"
        case .ready: "Ready"
        case .conflict: "Shortcut conflict"
        case .unavailable: "Unavailable"
        }
    }

    var message: String? {
        switch self {
        case .notConfigured, .ready:
            nil
        case .conflict:
            "Another application has reserved this shortcut. Record a different combination."
        case let .unavailable(status):
            "macOS could not register this shortcut (error \(status))."
        }
    }
}

@MainActor
protocol ScreenSaverHotKeyRegistering: AnyObject {
    var onPressed: (() -> Void)? { get set }
    func register(_ shortcut: GlobalKeyboardShortcut) -> ScreenSaverHotKeyRegistrationState
    func unregister()
    func stop()
}

/// Owns the user-facing shortcut lifecycle. Registration is independent of the
/// Accessibility-protected event tap used for agent actions.
@MainActor
@Observable
final class ScreenSaverHotKeyRegistrar {
    private(set) var state: ScreenSaverHotKeyRegistrationState = .notConfigured

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let backend: any ScreenSaverHotKeyRegistering
    @ObservationIgnored private let onPressed: () -> Void
    @ObservationIgnored private var isStarted = false

    init(
        settings: Settings,
        onPressed: @escaping () -> Void,
        backend: (any ScreenSaverHotKeyRegistering)? = nil
    ) {
        self.settings = settings
        self.onPressed = onPressed
        self.backend = backend ?? CarbonScreenSaverHotKeyBackend()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        backend.onPressed = { [weak self] in self?.onPressed() }
        refreshRegistration()
        observeShortcut()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        backend.onPressed = nil
        backend.stop()
        state = .notConfigured
    }

    func refreshRegistration() {
        guard isStarted else { return }
        guard let shortcut = settings.screenSaverShortcut else {
            backend.unregister()
            state = .notConfigured
            return
        }
        state = backend.register(shortcut)
    }

    private func observeShortcut() {
        guard isStarted else { return }
        withObservationTracking {
            _ = settings.screenSaverShortcut
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isStarted else { return }
                self.refreshRegistration()
                self.observeShortcut()
            }
        }
    }
}

@MainActor
private final class CarbonScreenSaverHotKeyBackend: ScreenSaverHotKeyRegistering {
    var onPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register(_ shortcut: GlobalKeyboardShortcut) -> ScreenSaverHotKeyRegistrationState {
        unregister()
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else { return .unavailable(handlerStatus) }

        var registeredRef: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &registeredRef)
        guard status == noErr, let registeredRef else {
            return status == eventHotKeyExistsErr ? .conflict : .unavailable(status)
        }
        hotKeyRef = registeredRef
        return .ready
    }

    func unregister() {
        if let hotKeyRef { _ = UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    func stop() {
        unregister()
        if let handlerRef { _ = RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    fileprivate func handlePress() {
        onPressed?()
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handlerRef == nil else { return noErr }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        return InstallEventHandler(
            GetApplicationEventTarget(),
            screenSaverHotKeyHandler,
            1,
            &eventType,
            pointer,
            &handlerRef)
    }

    private static let signature: OSType = 0x4E534148 // "NSAH"
}

private func screenSaverHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let backend = Unmanaged<CarbonScreenSaverHotKeyBackend>
        .fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in backend.handlePress() }
    return noErr
}
