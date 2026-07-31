import Foundation

/// Stable identifiers for complete screen-saver presentations. New styles are
/// additive: each one supplies its own scene while continuing to consume the
/// same privacy-safe status snapshot.
public enum ScreenSaveStyleID: String, CaseIterable, Codable, Identifiable, Sendable {
    case classic
    case aurora
    case currentWallpaper = "current-wallpaper"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic: "Classic"
        case .aurora: "Aurora Observatory"
        case .currentWallpaper: "Current Wallpaper"
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .classic
    }
}

/// Presentation-only configuration shared by the app preview and the separate
/// macOS screen-saver host. It intentionally contains no agent identity or
/// status data and remains valid when the live heartbeat expires.
public struct ScreenSaveConfiguration: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public static let `default` = ScreenSaveConfiguration(style: .classic)

    public let schema: Int
    public var style: ScreenSaveStyleID
    public var wallpapers: [ScreenSaveWallpaperAsset]

    public init(
        style: ScreenSaveStyleID,
        wallpapers: [ScreenSaveWallpaperAsset] = []
    ) {
        schema = Self.schemaVersion
        self.style = style
        self.wallpapers = wallpapers
    }

    public func validated() -> Self {
        schema == Self.schemaVersion ? self : .default
    }

    public func wallpaper(displayID: String?, screenIndex: Int) -> ScreenSaveWallpaperAsset? {
        if let displayID,
           let exact = wallpapers.first(where: { $0.displayID == displayID }) {
            return exact
        }
        return wallpapers.first(where: { $0.screenIndex == screenIndex })
            ?? wallpapers.first
    }

    private enum CodingKeys: String, CodingKey {
        case schema, style, wallpapers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema)
            ?? Self.schemaVersion
        style = try container.decodeIfPresent(ScreenSaveStyleID.self, forKey: .style)
            ?? .classic
        wallpapers = try container.decodeIfPresent(
            [ScreenSaveWallpaperAsset].self, forKey: .wallpapers) ?? []
    }
}

public struct ScreenSaveWallpaperAsset: Codable, Sendable, Equatable {
    public let displayID: String
    public let screenIndex: Int
    public let fileName: String

    public init(displayID: String, screenIndex: Int, fileName: String) {
        self.displayID = displayID
        self.screenIndex = screenIndex
        self.fileName = fileName
    }
}

public enum ScreenSaveConfigurationLocation {
    public static func fileURL(
        hostHomeDirectory: URL = ScreenSaveSnapshotLocation.hostUserHomeDirectory
    ) -> URL {
        ScreenSaveSnapshotLocation.directoryURL(hostHomeDirectory: hostHomeDirectory)
            .appendingPathComponent("screensaver-configuration.json", isDirectory: false)
    }
}

public enum ScreenSaveWallpaperCacheLocation {
    public static func directoryURL(
        hostHomeDirectory: URL = ScreenSaveSnapshotLocation.hostUserHomeDirectory
    ) -> URL {
        ScreenSaveSnapshotLocation.directoryURL(hostHomeDirectory: hostHomeDirectory)
            .appendingPathComponent("ScreenSaverWallpapers", isDirectory: true)
    }

    public static func fileURL(
        for asset: ScreenSaveWallpaperAsset,
        hostHomeDirectory: URL = ScreenSaveSnapshotLocation.hostUserHomeDirectory
    ) -> URL? {
        guard !asset.fileName.isEmpty,
              URL(fileURLWithPath: asset.fileName).lastPathComponent == asset.fileName else {
            return nil
        }
        return directoryURL(hostHomeDirectory: hostHomeDirectory)
            .appendingPathComponent(asset.fileName, isDirectory: false)
    }
}
