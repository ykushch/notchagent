import AppKit
import Foundation
import ScreenSaveKit

struct ScreenSaveWallpaperSource: Sendable, Equatable {
    let displayID: String
    let screenIndex: Int
    let sourceURL: URL
}

actor ScreenSaveWallpaperCacheWriter {
    private let directoryURL: URL
    private var lastSourceURLs: [String: URL] = [:]

    init(directoryURL: URL = ScreenSaveWallpaperCacheLocation.directoryURL()) {
        self.directoryURL = directoryURL
    }

    func cache(_ sources: [ScreenSaveWallpaperSource]) -> [ScreenSaveWallpaperAsset] {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)

        return sources.compactMap { source in
            let fileName = Self.fileName(for: source)
            let destination = directoryURL.appendingPathComponent(fileName)
            if lastSourceURLs[source.displayID] != source.sourceURL
                || !fileManager.fileExists(atPath: destination.path) {
                guard let data = try? Data(contentsOf: source.sourceURL),
                      (try? data.write(to: destination, options: .atomic)) != nil else {
                    return nil
                }
                lastSourceURLs[source.displayID] = source.sourceURL
            }
            return ScreenSaveWallpaperAsset(
                displayID: source.displayID,
                screenIndex: source.screenIndex,
                fileName: fileName)
        }
    }

    private static func fileName(for source: ScreenSaveWallpaperSource) -> String {
        let rawExtension = source.sourceURL.pathExtension.lowercased()
        let safeExtension = rawExtension.count <= 10
            && rawExtension.allSatisfy { $0.isLetter || $0.isNumber }
            ? rawExtension : "image"
        return safeExtension.isEmpty
            ? "display-\(source.displayID)"
            : "display-\(source.displayID).\(safeExtension)"
    }
}

@MainActor
enum ScreenSaveWallpaperCapture {
    static func currentSources(
        screens: [NSScreen] = NSScreen.screens,
        workspace: NSWorkspace = .shared
    ) -> [ScreenSaveWallpaperSource] {
        screens.enumerated().compactMap { index, screen in
            guard let displayID = screen.screenSaveDisplayID,
                  let sourceURL = workspace.desktopImageURL(for: screen) else {
                return nil
            }
            return ScreenSaveWallpaperSource(
                displayID: displayID,
                screenIndex: index,
                sourceURL: sourceURL)
        }
    }
}

extension NSScreen {
    var screenSaveDisplayID: String? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { String($0.uint32Value) }
    }
}
