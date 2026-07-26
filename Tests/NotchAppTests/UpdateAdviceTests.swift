import Foundation
import Testing
@testable import NotchApp

@Suite("UpdateAdvice")
struct UpdateAdviceTests {
    static let manifest = UpdateManifest(
        version: AppVersion("1.3.0")!,
        downloadURL: URL(string: "https://github.com/ykushch/notchagent/releases/download/v1.3.0/NotchApp-1.3.0.zip")!,
        sha256: String(repeating: "a", count: 64),
        releaseNotesURL: URL(string: "https://github.com/ykushch/notchagent/releases/tag/v1.3.0")!)

    @Test("Homebrew installs are told to upgrade the cask, not to download")
    func homebrewGuidance() {
        let guidance = UpdateAdvice.guidance(
            for: .homebrew, manifest: Self.manifest, currentVersion: AppVersion("1.2.0")!)
        #expect(guidance.command == "brew upgrade --cask ykushch/tap/notchagent")
        #expect(guidance.commandActionTitle == "Copy upgrade command")
        #expect(guidance.primaryLink == Self.manifest.releaseNotesURL)
        #expect(guidance.headline == "NotchAgent 1.3.0 is available")
        #expect(guidance.detail.contains("1.2.0"))
    }

    @Test("Manual installs get the archive, and no command that would do nothing")
    func manualGuidance() {
        let guidance = UpdateAdvice.guidance(
            for: .manual, manifest: Self.manifest, currentVersion: AppVersion("1.2.0")!)
        #expect(guidance.command == nil)
        #expect(guidance.commandActionTitle == nil)
        #expect(guidance.primaryLink == Self.manifest.downloadURL)
        #expect(guidance.primaryLinkActionTitle == "Download NotchApp-1.3.0.zip")
        #expect(guidance.releaseNotesURL == Self.manifest.releaseNotesURL)
    }

    @Test("Every path warns about the Accessibility grant an ad-hoc upgrade drops")
    func accessibilityReminder() {
        for origin in [InstallOrigin.homebrew, .manual, .development] {
            let guidance = UpdateAdvice.guidance(
                for: origin, manifest: Self.manifest, currentVersion: nil)
            #expect(guidance.accessibilityReminder.contains("Accessibility"))
        }
    }

    @Test("An unknown current version simply omits the 'you're on' clause")
    func unknownCurrentVersion() {
        let guidance = UpdateAdvice.guidance(
            for: .manual, manifest: Self.manifest, currentVersion: nil)
        #expect(!guidance.detail.contains("You're on"))
    }
}
