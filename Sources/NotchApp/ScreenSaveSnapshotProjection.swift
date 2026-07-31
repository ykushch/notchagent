import Foundation
import HerdrClient
import ScreenSaveKit

extension NotchViewModel {
    /// The system saver receives status identity only. In particular, the
    /// interaction summary—which may contain prompt text—does not cross this
    /// boundary.
    func screenSaveSnapshot(at now: Date) -> ScreenSaveSnapshot {
        ScreenSaveSnapshot(
            generatedAt: now,
            connection: connection.screenSaveConnection,
            agents: attentionItems(at: now).map { item in
                ScreenSaveAgentSnapshot(
                    id: item.id,
                    sessionLabel: item.sessionLabel,
                    isRemote: item.isRemote,
                    taskTitle: item.taskTitle,
                    agentName: item.agentName,
                    modelName: item.modelName,
                    workspaceLabel: item.workspaceLabel,
                    tabTitle: item.tabTitle,
                    status: item.status.screenSaveStatus,
                    stateText: item.stateText,
                    activeSince: item.activeSince)
            })
    }
}

private extension SessionRuntime.Connection {
    var screenSaveConnection: ScreenSaveConnection {
        switch self {
        case .connecting: .connecting
        case .connected: .connected
        case .unavailable: .unavailable
        }
    }
}

private extension RollupStatus {
    var screenSaveStatus: ScreenSaveStatus {
        switch self {
        case .blocked: .blocked
        case .working: .working
        case .done: .done
        case .idle: .idle
        case .unknown: .unknown
        }
    }
}
