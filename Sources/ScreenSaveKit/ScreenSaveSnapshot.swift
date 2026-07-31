import Foundation
#if os(macOS)
import Darwin
#endif

public enum ScreenSaveConnection: String, Codable, Sendable, Equatable {
    case connecting
    case connected
    case unavailable
}

public enum ScreenSaveStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case blocked
    case working
    case done
    case idle
    case unknown
}

/// The deliberately narrow, status-only boundary shared with the system screen
/// saver. Prompt bodies, terminal output, drafts, and response controls never
/// cross into the screen-saver host process.
public struct ScreenSaveAgentSnapshot: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let sessionLabel: String?
    public let isRemote: Bool
    public let taskTitle: String
    public let agentName: String
    public let modelName: String?
    public let workspaceLabel: String
    public let tabTitle: String
    public let status: ScreenSaveStatus
    public let stateText: String
    public let activeSince: Date?

    public init(
        id: String,
        sessionLabel: String? = nil,
        isRemote: Bool = false,
        taskTitle: String,
        agentName: String,
        modelName: String? = nil,
        workspaceLabel: String,
        tabTitle: String,
        status: ScreenSaveStatus,
        stateText: String,
        activeSince: Date? = nil
    ) {
        self.id = id
        self.sessionLabel = sessionLabel
        self.isRemote = isRemote
        self.taskTitle = taskTitle
        self.agentName = agentName
        self.modelName = modelName
        self.workspaceLabel = workspaceLabel
        self.tabTitle = tabTitle
        self.status = status
        self.stateText = stateText
        self.activeSince = activeSince
    }
}

public struct ScreenSaveSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schema: Int
    public let generatedAt: Date
    public let connection: ScreenSaveConnection
    public let agents: [ScreenSaveAgentSnapshot]

    public init(
        generatedAt: Date = Date(),
        connection: ScreenSaveConnection,
        agents: [ScreenSaveAgentSnapshot]
    ) {
        schema = Self.schemaVersion
        self.generatedAt = generatedAt
        self.connection = connection
        self.agents = agents
    }

    public static func unavailable(at date: Date = Date()) -> ScreenSaveSnapshot {
        ScreenSaveSnapshot(generatedAt: date, connection: .unavailable, agents: [])
    }

    /// A stopped app must not leave project names visible on a locked display.
    public func hidingStaleData(at now: Date, maximumAge: TimeInterval = 15) -> Self {
        guard schema == Self.schemaVersion,
              now.timeIntervalSince(generatedAt) >= 0,
              now.timeIntervalSince(generatedAt) <= maximumAge else {
            return .unavailable(at: now)
        }
        return self
    }
}

public enum ScreenSaveSnapshotLocation {
    /// Sandboxed screen-saver hosts redirect Foundation's user-domain folders
    /// into their own container. The POSIX account record remains the shared,
    /// real home directory and the host grants legacy savers read-only access.
    public static let hostUserHomeDirectory: URL = {
        #if os(macOS)
        if let record = getpwuid(getuid()),
           let path = record.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    public static func directoryURL(
        hostHomeDirectory: URL = hostUserHomeDirectory
    ) -> URL {
        hostHomeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("NotchAgent", isDirectory: true)
    }

    public static func fileURL(
        hostHomeDirectory: URL = hostUserHomeDirectory
    ) -> URL {
        directoryURL(hostHomeDirectory: hostHomeDirectory)
            .appendingPathComponent("screensaver-status.json", isDirectory: false)
    }
}
