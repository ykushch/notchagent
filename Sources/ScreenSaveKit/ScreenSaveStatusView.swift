import SwiftUI

public struct ScreenSaveStatusView: View {
    public let snapshot: ScreenSaveSnapshot
    public let configuration: ScreenSaveConfiguration
    public let now: Date
    public let displayID: String?
    public let screenIndex: Int
    public let screenCount: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        snapshot: ScreenSaveSnapshot,
        configuration: ScreenSaveConfiguration = .default,
        now: Date,
        displayID: String? = nil,
        screenIndex: Int = 0,
        screenCount: Int = 1
    ) {
        self.snapshot = snapshot
        self.configuration = configuration.validated()
        self.now = now
        self.displayID = displayID
        self.screenIndex = screenIndex
        self.screenCount = screenCount
    }

    public var body: some View {
        ScreenSaveScene(
            snapshot: snapshot,
            configuration: configuration,
            now: now,
            displayID: displayID,
            screenIndex: screenIndex,
            screenCount: screenCount,
            reduceMotion: reduceMotion)
    }
}

/// The single runtime selection boundary for complete presentations. A future
/// style can provide a different backdrop, theme, or full composition without
/// adding conditionals throughout the shared dashboard components.
private struct ScreenSaveScene: View {
    let snapshot: ScreenSaveSnapshot
    let configuration: ScreenSaveConfiguration
    let now: Date
    let displayID: String?
    let screenIndex: Int
    let screenCount: Int
    let reduceMotion: Bool

    var body: some View {
        switch configuration.style {
        case .classic:
            ClassicScreenSaveScene(
                snapshot: snapshot,
                now: now,
                screenIndex: screenIndex,
                screenCount: screenCount,
                reduceMotion: reduceMotion)
        case .aurora:
            AuroraScreenSaveScene(
                snapshot: snapshot,
                now: now,
                screenIndex: screenIndex,
                screenCount: screenCount,
                reduceMotion: reduceMotion)
        case .currentWallpaper:
            WallpaperScreenSaveScene(
                snapshot: snapshot,
                asset: configuration.wallpaper(
                    displayID: displayID, screenIndex: screenIndex),
                now: now,
                screenIndex: screenIndex,
                screenCount: screenCount)
        }
    }
}

struct ScreenSaveDashboard: View {
    let snapshot: ScreenSaveSnapshot
    let now: Date
    let screenIndex: Int
    let screenCount: Int

    var body: some View {
        GeometryReader { proxy in
            let layout = ScreenSaveGridLayout(
                size: proxy.size, itemCount: snapshot.agents.count)
            let page = layout.page(at: now)
            let agents = Array(snapshot.agents[page.itemRange])

            VStack(spacing: 24) {
                ScreenSaveHeader(
                    snapshot: snapshot, now: now,
                    pageNumber: page.index + 1, pageCount: page.count)
                Group {
                    if agents.isEmpty {
                        ScreenSaveEmptyState(connection: snapshot.connection)
                    } else {
                        LazyVGrid(
                            columns: layout.columns(
                                displayedItemCount: agents.count),
                            alignment: .center,
                            spacing: layout.spacing
                        ) {
                            ForEach(agents) { agent in
                                ScreenSaveAgentCard(agent: agent, now: now)
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: ScreenSaveGridLayout.minimumCardHeight,
                                        alignment: .topLeading)
                            }
                        }
                        .id(page.index)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                        .animation(.easeInOut(duration: 0.8), value: page.index)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ScreenSaveFooter(screenIndex: screenIndex, screenCount: screenCount)
            }
            .padding(.horizontal, layout.edgePadding)
            .padding(.vertical, 34)
        }
    }
}

private struct ScreenSaveHeader: View {
    let snapshot: ScreenSaveSnapshot
    let now: Date
    let pageNumber: Int
    let pageCount: Int
    @Environment(\.screenSaveTheme) private var theme

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 26, weight: .bold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(theme.primaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text("NOTCH AGENT")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .tracking(2.4)
                    Text("LIVE AGENT CONSTELLATION")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                ScreenSaveMetric(
                    value: snapshot.agents.count,
                    label: snapshot.agents.count == 1 ? "AGENT" : "AGENTS",
                    color: theme.primaryText)
                let blocked = snapshot.agents.count { $0.status == .blocked }
                ScreenSaveMetric(
                    value: blocked,
                    label: "NEED INPUT",
                    color: blocked > 0
                        ? theme.blocked : theme.idle)
                if pageCount > 1 {
                    Text("\(pageNumber) / \(pageCount)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 14)
                }
                Text(now, style: .time)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText.opacity(0.86))
                    .padding(.leading, 8)
            }
        }
    }
}

private struct ScreenSaveMetric: View {
    let value: Int
    let label: String
    let color: Color
    @Environment(\.screenSaveTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text("\(value)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(theme.elevated.opacity(0.74)))
        .overlay(Capsule().stroke(
            theme.hairline.opacity(0.7), lineWidth: 1))
    }
}

private struct ScreenSaveAgentCard: View {
    let agent: ScreenSaveAgentSnapshot
    let now: Date
    @Environment(\.screenSaveTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 15) {
                ScreenSaveStatusOrb(status: agent.status)
                VStack(alignment: .leading, spacing: 5) {
                    Text(agent.taskTitle)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(locationLine)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Text(agent.status.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(theme.status(agent.status))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(
                        theme.status(agent.status).opacity(0.12)))
                    .fixedSize()
            }

            Spacer(minLength: 2)

            HStack(spacing: 8) {
                Label(agent.agentName, systemImage: "terminal")
                if let modelName = agent.modelName { Text(modelName) }
                if agent.isRemote { Label("REMOTE", systemImage: "network") }
            }
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(agent.stateText.uppercased())
                    .foregroundStyle(theme.status(agent.status))
                Spacer()
                if let elapsed = elapsedText {
                    Label(elapsed, systemImage: "clock").monospacedDigit()
                }
            }
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(theme.tertiaryText)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(theme.elevated.opacity(0.80)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                theme.status(agent.status).opacity(
                    agent.status == .blocked ? 0.55 : 0.20),
                lineWidth: agent.status == .blocked ? 1.5 : 1))
        .shadow(
            color: theme.status(agent.status).opacity(
                agent.status == .blocked ? 0.18 : 0.06),
            radius: 24, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var locationLine: String {
        [agent.workspaceLabel, agent.tabTitle, agent.sessionLabel]
            .compactMap { $0 }.joined(separator: "  ·  ")
    }

    private var elapsedText: String? {
        guard let start = agent.activeSince else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "<1m elapsed" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m elapsed" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? "\(hours)h elapsed" : "\(hours)h \(remainder)m elapsed"
    }

    private var accessibilityLabel: String {
        [agent.agentName, "in \(agent.workspaceLabel)", agent.tabTitle,
         agent.modelName, agent.sessionLabel.map { "session \($0)" },
         agent.stateText, elapsedText]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

private struct ScreenSaveStatusOrb: View {
    let status: ScreenSaveStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.screenSaveTheme) private var theme
    @State private var breathes = false

    private var animates: Bool { status == .working || status == .blocked }

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.status(status).opacity(0.16))
                .frame(width: 42, height: 42)
                .scaleEffect(breathes && animates ? 1.15 : 0.94)
                .opacity(breathes && animates ? 0.55 : 0.95)
            Circle()
                .fill(theme.status(status))
                .frame(width: 15, height: 15)
                .shadow(color: theme.status(status).opacity(0.7), radius: 9)
        }
        .animation(
            reduceMotion || !animates
                ? nil
                : .easeInOut(duration: status == .blocked ? 0.85 : 1.8)
                    .repeatForever(autoreverses: true),
            value: breathes)
        .onAppear { breathes = true }
        .onChange(of: status) { _, _ in breathes.toggle() }
        .accessibilityHidden(true)
    }
}

private struct ScreenSaveEmptyState: View {
    let connection: ScreenSaveConnection
    @Environment(\.screenSaveTheme) private var theme

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: connection == .unavailable
                ? "bolt.horizontal.circle" : "ellipsis.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(connection == .unavailable
                    ? theme.blocked : theme.working)
            Text(connection == .unavailable
                ? "NotchAgent is not streaming" : "Waiting for agents")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text(connection == .unavailable
                ? "Open NotchAgent to publish live, privacy-safe agent statuses."
                : "Agents running under herdr will appear here live.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScreenSaveFooter: View {
    let screenIndex: Int
    let screenCount: Int
    @Environment(\.screenSaveTheme) private var theme

    var body: some View {
        HStack {
            Text("STATUS ONLY · PROMPT CONTENT IS HIDDEN")
            Spacer()
            if screenCount > 1 { Text("DISPLAY \(screenIndex + 1) OF \(screenCount)") }
            Text("MOVE MOUSE OR PRESS ANY KEY TO EXIT")
        }
        .font(.system(size: 8, weight: .bold, design: .rounded))
        .tracking(1.2)
        .foregroundStyle(theme.tertiaryText)
    }
}
