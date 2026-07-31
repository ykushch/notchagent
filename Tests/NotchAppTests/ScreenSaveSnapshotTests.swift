import Foundation
import ScreenSaveKit
import Testing
@testable import NotchApp

@Suite("Screen-saver status boundary")
struct ScreenSaveSnapshotTests {
    @Test("fresh status survives while stale identity is hidden")
    func stalePrivacyBoundary() {
        let generatedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let snapshot = ScreenSaveSnapshot(
            generatedAt: generatedAt,
            connection: .connected,
            agents: [agent])

        #expect(snapshot.hidingStaleData(
            at: generatedAt.addingTimeInterval(14)).agents == [agent])
        let stale = snapshot.hidingStaleData(
            at: generatedAt.addingTimeInterval(16))
        #expect(stale.connection == .unavailable)
        #expect(stale.agents.isEmpty)
    }

    @Test("encoded boundary contains no prompt or interaction fields")
    func statusOnlyEncoding() throws {
        let snapshot = ScreenSaveSnapshot(
            generatedAt: Date(timeIntervalSinceReferenceDate: 10),
            connection: .connected,
            agents: [agent])
        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let agents = try #require(object["agents"] as? [[String: Any]])
        let keys = Set(try #require(agents.first).keys)

        #expect(!keys.contains("summary"))
        #expect(!keys.contains("prompt"))
        #expect(!keys.contains("terminalOutput"))
        #expect(!keys.contains("draft"))
    }

    @Test("writer publishes a decodable atomic heartbeat")
    func writerRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("status.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = ScreenSaveSnapshot(
            generatedAt: Date(timeIntervalSinceReferenceDate: 20),
            connection: .connected,
            agents: [agent])

        try await ScreenSaveSnapshotWriter(fileURL: fileURL).write(snapshot)

        let decoded = try JSONDecoder().decode(
            ScreenSaveSnapshot.self, from: Data(contentsOf: fileURL))
        #expect(decoded == snapshot)
    }

    @Test("shared path does not inherit the screen-saver container home")
    func sharedPathUsesHostHome() {
        let hostHome = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let containerHome = URL(
            fileURLWithPath:
                "/Users/example/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data",
            isDirectory: true)

        let sharedURL = ScreenSaveSnapshotLocation.fileURL(
            hostHomeDirectory: hostHome)

        #expect(sharedURL.path
            == "/Users/example/Library/Application Support/NotchAgent/screensaver-status.json")
        #expect(!sharedURL.path.hasPrefix(containerHome.path))
    }

    private var agent: ScreenSaveAgentSnapshot {
        ScreenSaveAgentSnapshot(
            id: "local:w1:p1",
            taskTitle: "Build companion",
            agentName: "codex",
            modelName: "gpt-5",
            workspaceLabel: "NotchAgent",
            tabTitle: "Tab 1",
            status: .working,
            stateText: "working",
            activeSince: Date(timeIntervalSinceReferenceDate: 900))
    }
}

@Suite("Screen-saver installer", .serialized)
@MainActor
struct ScreenSaverInstallerTests {
    @Test("installation state distinguishes missing, installed, and update")
    func stateResolution() {
        #expect(ScreenSaverInstaller.resolveState(
            sourceExists: false, installedExists: false,
            sourceVersion: nil, installedVersion: nil) == .sourceUnavailable)
        #expect(ScreenSaverInstaller.resolveState(
            sourceExists: true, installedExists: false,
            sourceVersion: "1.0", installedVersion: nil) == .notInstalled)
        #expect(ScreenSaverInstaller.resolveState(
            sourceExists: true, installedExists: true,
            sourceVersion: "1.0", installedVersion: "1.0") == .installed)
        #expect(ScreenSaverInstaller.resolveState(
            sourceExists: true, installedExists: true,
            sourceVersion: "2.0", installedVersion: "1.0") == .updateAvailable)
    }

    @Test("install hands the saver to the standard workspace opener")
    func standardInstallerEntryPoint() {
        let source = URL(fileURLWithPath: "/tmp/source/NotchAgent.saver")
        let installed = URL(fileURLWithPath: "/tmp/installed/NotchAgent.saver")
        var opened: [URL] = []
        let installer = ScreenSaverInstaller(
            sourceURL: source,
            installedURL: installed,
            fileExists: { $0 == source },
            bundleVersion: { _ in "1.0" },
            openURL: { opened.append($0); return true })

        #expect(installer.state == .notInstalled)
        installer.install()
        installer.stop()

        #expect(opened == [source])
        #expect(installer.message?.contains("macOS installation prompt") == true)
    }

    @Test("settings action opens the current Wallpaper settings pane")
    func opensSettings() {
        var opened: [URL] = []
        let installer = ScreenSaverInstaller(
            sourceURL: nil,
            installedURL: URL(fileURLWithPath: "/tmp/missing.saver"),
            fileExists: { _ in false },
            bundleVersion: { _ in nil },
            openURL: { opened.append($0); return true })

        installer.openSystemSettings()

        #expect(opened.first?.absoluteString
            == "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")
    }
}
