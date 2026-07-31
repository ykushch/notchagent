import Testing
@testable import NotchApp

@Suite("App launch mode")
struct AppLaunchModeTests {
    @Test("screensave executable alias selects screen-save mode")
    func executableAlias() {
        #expect(AppLaunchMode(arguments: ["/tmp/screensave"]) == .screenSave)
    }

    @Test("NotchApp accepts the screensave command and flag")
    func commandArguments() {
        #expect(AppLaunchMode(arguments: ["/tmp/NotchApp", "screensave"]) == .screenSave)
        #expect(AppLaunchMode(arguments: ["/tmp/NotchApp", "--screensave"]) == .screenSave)
    }

    @Test("regular app launch keeps the notch presentation")
    func normalLaunch() {
        #expect(AppLaunchMode(arguments: ["/tmp/NotchApp"]) == .normal)
        #expect(AppLaunchMode(arguments: ["/tmp/NotchApp", "unknown"]) == .normal)
    }
}
