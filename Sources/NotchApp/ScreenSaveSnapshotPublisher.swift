import Foundation
import ScreenSaveKit

actor ScreenSaveSnapshotWriter {
    private let fileURL: URL

    init(fileURL: URL = ScreenSaveSnapshotLocation.fileURL()) {
        self.fileURL = fileURL
    }

    func write(_ snapshot: ScreenSaveSnapshot) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}

actor ScreenSaveConfigurationWriter {
    private let fileURL: URL

    init(fileURL: URL = ScreenSaveConfigurationLocation.fileURL()) {
        self.fileURL = fileURL
    }

    func write(_ configuration: ScreenSaveConfiguration) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
    }
}

/// Publishes a small heartbeat that the sandboxed screen-saver host can read
/// without connecting to herdr or owning any agent lifecycle state.
@MainActor
final class ScreenSaveSnapshotPublisher {
    private weak var model: NotchViewModel?
    private weak var settings: Settings?
    private let writer: ScreenSaveSnapshotWriter
    private let configurationWriter: ScreenSaveConfigurationWriter
    private let wallpaperCacheWriter: ScreenSaveWallpaperCacheWriter
    private var task: Task<Void, Never>?
    private var wallpaperAssets: [ScreenSaveWallpaperAsset] = []
    private var lastWallpaperRefresh: Date?

    init(
        model: NotchViewModel,
        settings: Settings,
        writer: ScreenSaveSnapshotWriter = ScreenSaveSnapshotWriter(),
        configurationWriter: ScreenSaveConfigurationWriter = ScreenSaveConfigurationWriter(),
        wallpaperCacheWriter: ScreenSaveWallpaperCacheWriter = ScreenSaveWallpaperCacheWriter()
    ) {
        self.model = model
        self.settings = settings
        self.writer = writer
        self.configurationWriter = configurationWriter
        self.wallpaperCacheWriter = wallpaperCacheWriter
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let model = self.model,
                      let settings = self.settings else { return }
                let now = Date()
                try? await writer.write(model.screenSaveSnapshot(at: now))
                if settings.screenSaveStyle == .currentWallpaper,
                   lastWallpaperRefresh.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                    let sources = ScreenSaveWallpaperCapture.currentSources()
                    let refreshed = await wallpaperCacheWriter.cache(sources)
                    if !refreshed.isEmpty { wallpaperAssets = refreshed }
                    lastWallpaperRefresh = now
                }
                try? await configurationWriter.write(ScreenSaveConfiguration(
                    style: settings.screenSaveStyle,
                    wallpapers: wallpaperAssets))
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
