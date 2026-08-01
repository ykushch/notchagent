import AppKit
import Foundation

/// Turns "a newer version exists" into the specific thing *this* user should
/// do about it. Pure — the UI renders whatever comes back and never decides
/// between brew and a download on its own.
enum UpdateAdvice {
    static let caskUpgradeCommand = "brew upgrade --cask ykushch/tap/notchagent"

    struct Guidance: Sendable, Equatable {
        /// "NotchAgent 1.3.0 is available"
        let headline: String
        /// One line of context, including the version being replaced.
        let detail: String
        /// A shell command to copy, when one applies (Homebrew installs).
        let command: String?
        let commandActionTitle: String?
        /// Where the primary button goes: the download for manual installs,
        /// the release notes for Homebrew installs (brew fetches the archive).
        let primaryLink: URL
        let primaryLinkActionTitle: String
        let releaseNotesURL: URL
        /// Shown once, because an ad-hoc signature changes identity on upgrade
        /// and macOS can drop Accessibility and Automation grants with it.
        let accessibilityReminder: String
    }

    static let accessibilityReminder =
        "After upgrading, re-enable Accessibility only if you use agent global shortcuts. If you use the screen saver shortcut, re-approve Automation access for System Events."

    static func guidance(
        for origin: InstallOrigin,
        manifest: UpdateManifest,
        currentVersion: AppVersion?
    ) -> Guidance {
        let headline = "NotchAgent \(manifest.version) is available"
        let from = currentVersion.map { "You're on \($0). " } ?? ""

        switch origin {
        case .homebrew:
            return Guidance(
                headline: headline,
                detail: "\(from)Upgrade with Homebrew to keep the cask in sync.",
                command: caskUpgradeCommand,
                commandActionTitle: "Copy upgrade command",
                primaryLink: manifest.releaseNotesURL,
                primaryLinkActionTitle: "Release notes",
                releaseNotesURL: manifest.releaseNotesURL,
                accessibilityReminder: accessibilityReminder)
        case .manual, .development:
            return Guidance(
                headline: headline,
                detail: "\(from)Download the archive and replace NotchApp.app.",
                command: nil,
                commandActionTitle: nil,
                primaryLink: manifest.downloadURL,
                primaryLinkActionTitle: "Download \(manifest.archiveName)",
                releaseNotesURL: manifest.releaseNotesURL,
                accessibilityReminder: accessibilityReminder)
        }
    }
}

/// The two side effects an update notice can have. Shared so the menu bar and
/// the notch banner behave identically instead of drifting apart.
@MainActor
enum UpdateActions {
    static func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
