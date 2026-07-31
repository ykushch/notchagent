import SwiftUI

#Preview("Long agent and project names") {
    ScreenSaveStatusView(
        snapshot: ScreenSaveSnapshot(
            generatedAt: Date(),
            connection: .connected,
            agents: [
                ScreenSaveAgentSnapshot(
                    id: "preview:long-name",
                    sessionLabel: "Remote production session with a long name",
                    isRemote: true,
                    taskTitle: "Implement the comprehensive screen-saver companion experience",
                    agentName: "claude-code-opus-long-running-agent",
                    modelName: "claude-opus-4.1",
                    workspaceLabel: "MySuperProjectWithAnExtraLongWorkspaceName",
                    tabTitle: "Agent orchestration and live status",
                    status: .working,
                    stateText: "working",
                    activeSince: Date().addingTimeInterval(-754)),
            ]),
        now: Date())
    .frame(width: 1_440, height: 900)
}
