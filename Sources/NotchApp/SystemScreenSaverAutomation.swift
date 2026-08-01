import AppKit
import Foundation
import Observation

enum ScreenSaverAutomationState: Equatable {
    case unknown
    case authorized
    case denied
    case unavailable

    var statusText: String {
        switch self {
        case .unknown: "Not checked"
        case .authorized: "Allowed"
        case .denied: "Permission needed"
        case .unavailable: "Unavailable"
        }
    }
}

struct AppleScriptExecution {
    let succeeded: Bool
    let errorNumber: Int?
    let message: String?
}

/// Starts the user's currently selected macOS screen saver through the
/// documented System Events scripting dictionary. This is deliberately
/// separate from ScreenSaveWindowController, which is only the in-app preview.
@MainActor
@Observable
final class SystemScreenSaverAutomation {
    private(set) var state: ScreenSaverAutomationState = .unknown
    private(set) var message: String?

    @ObservationIgnored private let execute: @MainActor (String) -> AppleScriptExecution

    init(execute: (@MainActor (String) -> AppleScriptExecution)? = nil) {
        self.execute = execute ?? Self.executeScript
    }

    func refreshPermission() {
        let result = execute(Self.permissionScript)
        applyPermissionResult(result)
    }

    /// Runs a harmless query so macOS can present the Automation consent
    /// dialog without starting the screen saver as a side effect.
    func requestPermission() {
        refreshPermission()
        if state == .authorized {
            message = "Notch Agent can control System Events."
        } else if state == .denied {
            message = "Allow Notch Agent under System Settings → Privacy & Security → Automation."
        }
    }

    @discardableResult
    func start() -> Bool {
        let result = execute(Self.startScript)
        guard result.succeeded else {
            if result.errorNumber == Self.permissionDeniedError {
                state = .denied
                message = "Allow Notch Agent under System Settings → Privacy & Security → Automation."
            } else {
                message = result.message ?? "macOS could not start the selected screen saver."
            }
            return false
        }
        state = .authorized
        message = nil
        return true
    }

    func openAutomationSettings() {
        openAutomationSettings(openURL: { NSWorkspace.shared.open($0) })
    }

    func openAutomationSettings(openURL: (URL) -> Bool) {
        let automationURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        if !openURL(automationURL) {
            _ = openURL(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    private func applyPermissionResult(_ result: AppleScriptExecution) {
        if result.succeeded {
            state = .authorized
            message = nil
        } else if result.errorNumber == Self.permissionDeniedError {
            state = .denied
            message = "Allow Notch Agent under System Settings → Privacy & Security → Automation."
        } else {
            state = .unavailable
            message = result.message ?? "System Events is unavailable."
        }
    }

    private static let permissionDeniedError = -1743
    private static let permissionScript = """
    tell application "System Events"
        get name of current screen saver
    end tell
    """
    private static let startScript = """
    tell application "System Events"
        start current screen saver
    end tell
    """

    private static func executeScript(_ source: String) -> AppleScriptExecution {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return AppleScriptExecution(
                succeeded: false, errorNumber: nil, message: "Could not compile the screen saver command.")
        }
        _ = script.executeAndReturnError(&error)
        guard let error else {
            return AppleScriptExecution(succeeded: true, errorNumber: nil, message: nil)
        }
        let number = error[NSAppleScript.errorNumber] as? Int
        let message = error[NSAppleScript.errorMessage] as? String
        return AppleScriptExecution(succeeded: false, errorNumber: number, message: message)
    }
}
