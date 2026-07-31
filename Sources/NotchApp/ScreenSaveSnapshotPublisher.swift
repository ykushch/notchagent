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

/// Publishes a small heartbeat that the sandboxed screen-saver host can read
/// without connecting to herdr or owning any agent lifecycle state.
@MainActor
final class ScreenSaveSnapshotPublisher {
    private weak var model: NotchViewModel?
    private let writer: ScreenSaveSnapshotWriter
    private var task: Task<Void, Never>?

    init(
        model: NotchViewModel,
        writer: ScreenSaveSnapshotWriter = ScreenSaveSnapshotWriter()
    ) {
        self.model = model
        self.writer = writer
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let model = self.model else { return }
                try? await writer.write(model.screenSaveSnapshot(at: Date()))
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
