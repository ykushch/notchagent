import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchMode: AppLaunchMode
    private var notchController: NotchWindowController?
    private var screenSaveController: ScreenSaveWindowController?
    private var viewModel: NotchViewModel?
    private var hotkeyMonitor: HotkeyMonitor?
    private var menuBar: MenuBarController?
    private var settings: Settings?
    private var soundEngine: SoundEngine?
    private var updateChecker: UpdateChecker?
    private var screenSaveSnapshotPublisher: ScreenSaveSnapshotPublisher?

    init(launchMode: AppLaunchMode = .normal) {
        self.launchMode = launchMode
        super.init()
    }

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

        self.settings = settings
        soundEngine = sound
        updateChecker = updates
        viewModel = model
        let snapshotPublisher = ScreenSaveSnapshotPublisher(model: model, settings: settings)
        screenSaveSnapshotPublisher = snapshotPublisher

        if launchMode == .screenSave {
            // Command mode is intentionally quiet and focused: no notch, menu,
            // update check, accessibility prompt, or global hotkeys.
            model.soundEngine = nil
            startScreenSave()
            model.start()
            snapshotPublisher.start()
            return
        }

        let controller = NotchWindowController(viewModel: model, settings: settings)
        controller.show()
        model.start()
        snapshotPublisher.start()

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
            onToggleNotch: { [weak model] in model?.toggle() },
            onPreviewScreenSave: { [weak self] in self?.startScreenSave() }
        )
        menuBar.install()
        updates.start()

        notchController = controller
        hotkeyMonitor = monitor
        self.menuBar = menuBar
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
        updateChecker?.stop()
        screenSaveSnapshotPublisher?.stop()
        viewModel?.stop()
        menuBar?.remove()
        notchController?.tearDown()
        screenSaveController?.tearDown()
        screenSaveController = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func startScreenSave() {
        guard screenSaveController == nil, let viewModel, let settings else { return }
        viewModel.setScreenSaveVisible(true)
        let controller = ScreenSaveWindowController(
            model: viewModel, settings: settings
        ) { [weak self] in
            self?.finishScreenSave()
        }
        screenSaveController = controller
        controller.show()
    }

    private func finishScreenSave() {
        screenSaveController?.tearDown()
        screenSaveController = nil
        viewModel?.setScreenSaveVisible(false)
        if launchMode == .screenSave {
            NSApp.terminate(nil)
        }
    }
}
