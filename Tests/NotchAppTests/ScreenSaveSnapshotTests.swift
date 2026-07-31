import Foundation
import ScreenSaveKit
import Testing
@testable import NotchApp

@Suite("Screen-saver status boundary")
struct ScreenSaveSnapshotTests {
    @Test("configuration is independent, versioned, and tolerant of future styles")
    func configurationCompatibility() throws {
        let configuration = ScreenSaveConfiguration(style: .aurora)
        let encoded = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(
            ScreenSaveConfiguration.self, from: encoded) == configuration)

        let futureStyle = Data(#"{"schema":1,"style":"future-style"}"#.utf8)
        #expect(try JSONDecoder().decode(
            ScreenSaveConfiguration.self, from: futureStyle).style == .classic)

        let futureSchema = Data(#"{"schema":99,"style":"classic"}"#.utf8)
        #expect(try JSONDecoder().decode(
            ScreenSaveConfiguration.self, from: futureSchema).validated() == .default)
        #expect(ScreenSaveStyleID.allCases == [
            .classic, .aurora, .currentWallpaper,
        ])
    }

    @Test("wallpaper configuration matches display identity before index")
    func wallpaperSelection() {
        let first = ScreenSaveWallpaperAsset(
            displayID: "100", screenIndex: 0, fileName: "first.heic")
        let second = ScreenSaveWallpaperAsset(
            displayID: "200", screenIndex: 1, fileName: "second.jpg")
        let configuration = ScreenSaveConfiguration(
            style: .currentWallpaper, wallpapers: [first, second])

        #expect(configuration.wallpaper(displayID: "200", screenIndex: 0) == second)
        #expect(configuration.wallpaper(displayID: nil, screenIndex: 1) == second)
        #expect(configuration.wallpaper(displayID: "missing", screenIndex: 8) == first)
    }

    @Test("wallpaper cache location refuses path traversal")
    func wallpaperCacheLocationSafety() {
        let valid = ScreenSaveWallpaperAsset(
            displayID: "100", screenIndex: 0, fileName: "display-100.heic")
        let traversal = ScreenSaveWallpaperAsset(
            displayID: "100", screenIndex: 0, fileName: "../status.json")
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        #expect(ScreenSaveWallpaperCacheLocation.fileURL(
            for: valid, hostHomeDirectory: home)?.path
            == "/Users/example/Library/Application Support/NotchAgent/ScreenSaverWallpapers/display-100.heic")
        #expect(ScreenSaveWallpaperCacheLocation.fileURL(
            for: traversal, hostHomeDirectory: home) == nil)
    }

    @Test("wallpaper cache copies display assets into the shared directory")
    func wallpaperCacheWriter() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = root.appendingPathComponent("source.heic")
        let cacheURL = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let bytes = Data("wallpaper-data".utf8)
        try bytes.write(to: sourceURL)

        let assets = await ScreenSaveWallpaperCacheWriter(directoryURL: cacheURL).cache([
            ScreenSaveWallpaperSource(
                displayID: "42", screenIndex: 1, sourceURL: sourceURL),
        ])
        let asset = try #require(assets.first)

        #expect(asset == ScreenSaveWallpaperAsset(
            displayID: "42", screenIndex: 1, fileName: "display-42.heic"))
        #expect(try Data(contentsOf: cacheURL.appendingPathComponent(asset.fileName)) == bytes)
    }

    @Test("configuration has its own shared file beside the expiring heartbeat")
    func configurationLocation() {
        let hostHome = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let statusURL = ScreenSaveSnapshotLocation.fileURL(
            hostHomeDirectory: hostHome)
        let configurationURL = ScreenSaveConfigurationLocation.fileURL(
            hostHomeDirectory: hostHome)

        #expect(configurationURL.deletingLastPathComponent()
            == statusURL.deletingLastPathComponent())
        #expect(configurationURL.lastPathComponent == "screensaver-configuration.json")
        #expect(configurationURL != statusURL)
    }

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

    @Test("writer publishes presentation configuration independently")
    func configurationWriterRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("configuration.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ScreenSaveConfiguration(style: .classic)

        try await ScreenSaveConfigurationWriter(fileURL: fileURL)
            .write(configuration)

        let decoded = try JSONDecoder().decode(
            ScreenSaveConfiguration.self, from: Data(contentsOf: fileURL))
        #expect(decoded == configuration)
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
        #expect(ScreenSaverInstaller.shouldContinueInstallPolling(state: .updateAvailable))
        #expect(!ScreenSaverInstaller.shouldContinueInstallPolling(state: .installed))
    }

    @Test("version reads observe an Info plist replaced while the app stays open")
    func freshBundleVersionReads() throws {
        let saverURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("saver")
        let contentsURL = saverURL.appendingPathComponent("Contents")
        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        defer { try? FileManager.default.removeItem(at: saverURL) }
        try FileManager.default.createDirectory(
            at: contentsURL, withIntermediateDirectories: true)

        func write(build: String) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleShortVersionString": "0.1",
                    "CFBundleVersion": build,
                ],
                format: .xml,
                options: 0)
            try data.write(to: infoURL, options: .atomic)
        }

        try write(build: "100")
        #expect(ScreenSaverInstaller.readBundleVersion(at: saverURL) == "0.1+100")
        try write(build: "200")
        #expect(ScreenSaverInstaller.readBundleVersion(at: saverURL) == "0.1+200")
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

    @Test("reload action restarts cached hosts only for the current installation")
    func reloadsInstalledSaverHost() {
        let source = URL(fileURLWithPath: "/tmp/source/NotchAgent.saver")
        let installed = URL(fileURLWithPath: "/tmp/installed/NotchAgent.saver")
        var reloadCalls = 0
        let installer = ScreenSaverInstaller(
            sourceURL: source,
            installedURL: installed,
            fileExists: { $0 == source || $0 == installed },
            bundleVersion: { _ in "1.0" },
            openURL: { _ in true },
            reloadHosts: { reloadCalls += 1; return 2 })

        #expect(installer.canReloadInstalledSaver)
        installer.reloadInstalledSaver()

        #expect(reloadCalls == 1)
        #expect(installer.message?.contains("Reloaded the installed saver") == true)
    }

    @Test("reload action stays disabled until installation is current")
    func refusesReloadBeforeInstall() {
        var reloadCalls = 0
        let installer = ScreenSaverInstaller(
            sourceURL: URL(fileURLWithPath: "/tmp/source/NotchAgent.saver"),
            installedURL: URL(fileURLWithPath: "/tmp/missing/NotchAgent.saver"),
            fileExists: { $0.path.contains("/source/") },
            bundleVersion: { _ in "1.0" },
            openURL: { _ in true },
            reloadHosts: { reloadCalls += 1; return 1 })

        #expect(!installer.canReloadInstalledSaver)
        installer.reloadInstalledSaver()

        #expect(reloadCalls == 0)
        #expect(installer.message?.contains("Finish installing") == true)
    }

    @Test("reload remains available while a newer source is waiting to install")
    func reloadsExistingSaverWhenUpdateIsAvailable() {
        let source = URL(fileURLWithPath: "/tmp/source/NotchAgent.saver")
        let installed = URL(fileURLWithPath: "/tmp/installed/NotchAgent.saver")
        var reloadCalls = 0
        let installer = ScreenSaverInstaller(
            sourceURL: source,
            installedURL: installed,
            fileExists: { _ in true },
            bundleVersion: { $0 == source ? "2.0" : "1.0" },
            openURL: { _ in true },
            reloadHosts: { reloadCalls += 1; return 1 })

        #expect(installer.state == .updateAvailable)
        #expect(installer.canReloadInstalledSaver)
        installer.reloadInstalledSaver()
        #expect(reloadCalls == 1)
    }
}
