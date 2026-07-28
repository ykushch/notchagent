import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var viewModel: NotchViewModel?
    private var hotkeyMonitor: HotkeyMonitor?
    private var menuBar: MenuBarController?
    private var settings: Settings?
    private var soundEngine: SoundEngine?
    private var updateChecker: UpdateChecker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Settings()
        // A nil socket means "track every running session"; an explicit override
        // still pins the notch to exactly that server.
        let model = NotchViewModel(pinnedSession: settings.resolvedSession())
        let sound = SoundEngine(settings: settings)
        let updates = UpdateChecker(settings: settings)
        model.settings = settings
        model.soundEngine = sound
        model.updateChecker = updates

        let controller = NotchWindowController(viewModel: model, settings: settings)
        controller.show()
        model.start()

        let monitor = HotkeyMonitor(viewModel: model, settings: settings)
        monitor.start()
        if settings.askForAccessibilityOnLaunch, !HotkeyMonitor.accessibilityGranted() {
            HotkeyMonitor.promptForAccessibility()
        }

        let menuBar = MenuBarController(
            settings: settings,
            updates: updates,
            registry: model.registry,
            onSessionChange: { [weak model, weak settings] in
                guard let model, let settings else { return }
                model.reconnect(pinnedSession: settings.resolvedSession())
            },
            onRemoteHostsChange: { [weak model] in
                model?.remoteHostsDidChange()
            },
            onToggleNotch: { [weak model] in model?.toggle() }
        )
        menuBar.install()
        updates.start()

        self.settings = settings
        soundEngine = sound
        updateChecker = updates
        viewModel = model
        notchController = controller
        hotkeyMonitor = monitor
        self.menuBar = menuBar
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
        updateChecker?.stop()
        viewModel?.stop()
        menuBar?.remove()
        notchController?.tearDown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
