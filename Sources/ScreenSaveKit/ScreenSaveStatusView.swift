import SwiftUI

public struct ScreenSaveStatusView: View {
    public let snapshot: ScreenSaveSnapshot
    public let now: Date
    public let screenIndex: Int
    public let screenCount: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        snapshot: ScreenSaveSnapshot,
        now: Date,
        screenIndex: Int = 0,
        screenCount: Int = 1
    ) {
        self.snapshot = snapshot
        self.now = now
        self.screenIndex = screenIndex
        self.screenCount = screenCount
    }

    public var body: some View {
        ZStack {
            Color.black
            ScreenSaveBackdrop(
                status: overallStatus,
                reduceMotion: reduceMotion,
                screenSeed: screenIndex)
            ScreenSaveDashboard(
                snapshot: snapshot, now: now,
                screenIndex: screenIndex, screenCount: screenCount)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var overallStatus: ScreenSaveStatus {
        snapshot.agents.map(\.status).max {
            ScreenSavePalette.precedence($0) < ScreenSavePalette.precedence($1)
        } ?? .unknown
    }
}

private struct ScreenSaveDashboard: View {
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

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 26, weight: .bold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(ScreenSavePalette.primaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text("NOTCH AGENT")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .tracking(2.4)
                    Text("LIVE AGENT CONSTELLATION")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(ScreenSavePalette.secondaryText)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                ScreenSaveMetric(
                    value: snapshot.agents.count,
                    label: snapshot.agents.count == 1 ? "AGENT" : "AGENTS",
                    color: ScreenSavePalette.primaryText)
                let blocked = snapshot.agents.count { $0.status == .blocked }
                ScreenSaveMetric(
                    value: blocked,
                    label: "NEED INPUT",
                    color: blocked > 0
                        ? ScreenSavePalette.blocked : ScreenSavePalette.idle)
                if pageCount > 1 {
                    Text("\(pageNumber) / \(pageCount)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ScreenSavePalette.secondaryText)
                        .padding(.horizontal, 14)
                }
                Text(now, style: .time)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ScreenSavePalette.primaryText.opacity(0.86))
                    .padding(.leading, 8)
            }
        }
    }
}

private struct ScreenSaveMetric: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text("\(value)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(ScreenSavePalette.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(ScreenSavePalette.elevated.opacity(0.74)))
        .overlay(Capsule().stroke(
            ScreenSavePalette.hairline.opacity(0.7), lineWidth: 1))
    }
}

private struct ScreenSaveAgentCard: View {
    let agent: ScreenSaveAgentSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 15) {
                ScreenSaveStatusOrb(status: agent.status)
                VStack(alignment: .leading, spacing: 5) {
                    Text(agent.taskTitle)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(ScreenSavePalette.primaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(locationLine)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(ScreenSavePalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Text(agent.status.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(ScreenSavePalette.status(agent.status))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(
                        ScreenSavePalette.status(agent.status).opacity(0.12)))
                    .fixedSize()
            }

            Spacer(minLength: 2)

            HStack(spacing: 8) {
                Label(agent.agentName, systemImage: "terminal")
                if let modelName = agent.modelName { Text(modelName) }
                if agent.isRemote { Label("REMOTE", systemImage: "network") }
            }
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(ScreenSavePalette.secondaryText)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(agent.stateText.uppercased())
                    .foregroundStyle(ScreenSavePalette.status(agent.status))
                Spacer()
                if let elapsed = elapsedText {
                    Label(elapsed, systemImage: "clock").monospacedDigit()
                }
            }
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(ScreenSavePalette.tertiaryText)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(ScreenSavePalette.elevated.opacity(0.80)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                ScreenSavePalette.status(agent.status).opacity(
                    agent.status == .blocked ? 0.55 : 0.20),
                lineWidth: agent.status == .blocked ? 1.5 : 1))
        .shadow(
            color: ScreenSavePalette.status(agent.status).opacity(
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
    @State private var breathes = false

    private var animates: Bool { status == .working || status == .blocked }

    var body: some View {
        ZStack {
            Circle()
                .fill(ScreenSavePalette.status(status).opacity(0.16))
                .frame(width: 42, height: 42)
                .scaleEffect(breathes && animates ? 1.15 : 0.94)
                .opacity(breathes && animates ? 0.55 : 0.95)
            Circle()
                .fill(ScreenSavePalette.status(status))
                .frame(width: 15, height: 15)
                .shadow(color: ScreenSavePalette.status(status).opacity(0.7), radius: 9)
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

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: connection == .unavailable
                ? "bolt.horizontal.circle" : "ellipsis.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(connection == .unavailable
                    ? ScreenSavePalette.blocked : ScreenSavePalette.working)
            Text(connection == .unavailable
                ? "NotchAgent is not streaming" : "Waiting for agents")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(ScreenSavePalette.primaryText)
            Text(connection == .unavailable
                ? "Open NotchAgent to publish live, privacy-safe agent statuses."
                : "Agents running under herdr will appear here live.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(ScreenSavePalette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScreenSaveFooter: View {
    let screenIndex: Int
    let screenCount: Int

    var body: some View {
        HStack {
            Text("STATUS ONLY · PROMPT CONTENT IS HIDDEN")
            Spacer()
            if screenCount > 1 { Text("DISPLAY \(screenIndex + 1) OF \(screenCount)") }
            Text("MOVE MOUSE OR PRESS ANY KEY TO EXIT")
        }
        .font(.system(size: 8, weight: .bold, design: .rounded))
        .tracking(1.2)
        .foregroundStyle(ScreenSavePalette.tertiaryText)
    }
}

private struct ScreenSaveBackdrop: View {
    let status: ScreenSaveStatus
    let reduceMotion: Bool
    let screenSeed: Int

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) {
            context in
            Canvas { graphics, size in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                let accent = ScreenSavePalette.status(status)
                for index in 0..<10 {
                    let seed = Double(index + screenSeed * 11)
                    let x = size.width * unit(sin(seed * 12.9898) * 43_758.5453)
                        + CGFloat(sin(time * 0.055 + seed) * 36)
                    let y = size.height * unit(sin(seed * 78.233 + 2.1) * 12_345.678)
                        + CGFloat(cos(time * 0.043 + seed * 0.7) * 28)
                    let diameter = CGFloat(160 + unit(seed * 19.17) * 250)
                    let rect = CGRect(
                        x: x - diameter / 2, y: y - diameter / 2,
                        width: diameter, height: diameter)
                    graphics.fill(
                        Path(ellipseIn: rect),
                        with: .color(accent.opacity(index.isMultiple(of: 3) ? 0.055 : 0.025)))
                }
            }
            .blur(radius: 70)
        }
        .overlay {
            LinearGradient(
                colors: [
                    ScreenSavePalette.surface.opacity(0.78),
                    Color.black.opacity(0.38),
                    ScreenSavePalette.surface.opacity(0.88),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        }
        .allowsHitTesting(false)
    }

    private func unit(_ value: Double) -> CGFloat {
        CGFloat(value - floor(value))
    }
}

public struct ScreenSaveGridLayout: Sendable, Equatable {
    public static let minimumCardWidth: CGFloat = 420
    public static let maximumCardWidth: CGFloat = 620
    public static let minimumCardHeight: CGFloat = 190

    public struct Page: Sendable, Equatable {
        public let index: Int
        public let count: Int
        public let itemRange: Range<Int>
    }

    public let columnCount: Int
    public let rowCount: Int
    public let itemCount: Int
    public let spacing: CGFloat = 18
    public let edgePadding: CGFloat
    public let minimumColumnWidth: CGFloat

    public init(size: CGSize, itemCount: Int) {
        self.itemCount = itemCount
        edgePadding = max(36, min(88, size.width * 0.055))
        let usableWidth = max(1, size.width - edgePadding * 2)
        let usableHeight = max(1, size.height - 210)
        minimumColumnWidth = min(Self.minimumCardWidth, usableWidth)
        columnCount = max(1, Int(
            (usableWidth + spacing) / (Self.minimumCardWidth + spacing)))
        rowCount = max(1, Int(
            (usableHeight + spacing) / (Self.minimumCardHeight + spacing)))
    }

    /// A partial page should stay centered instead of reserving invisible
    /// columns that leave one or two cards stranded at the leading edge.
    public func columns(displayedItemCount: Int) -> [GridItem] {
        let visibleColumnCount = min(columnCount, max(1, displayedItemCount))
        return Array(repeating: GridItem(
            .flexible(
                minimum: minimumColumnWidth,
                maximum: Self.maximumCardWidth),
            spacing: spacing), count: visibleColumnCount)
    }

    public var capacity: Int { max(1, columnCount * rowCount) }

    public func page(at date: Date) -> Page {
        let count = max(1, Int(ceil(Double(itemCount) / Double(capacity))))
        let index = itemCount == 0
            ? 0 : Int(date.timeIntervalSinceReferenceDate / 12) % count
        let lower = min(itemCount, index * capacity)
        let upper = min(itemCount, lower + capacity)
        return Page(index: index, count: count, itemRange: lower..<upper)
    }
}

private enum ScreenSavePalette {
    static let surface = color(0x110F0D)
    static let elevated = color(0x1D1A16)
    static let hairline = color(0x35322E)
    static let primaryText = color(0xF0EEE9)
    static let secondaryText = color(0x95928D)
    static let tertiaryText = secondaryText.opacity(0.62)
    static let working = color(0xD6A20A)
    static let blocked = color(0xFB8371)
    static let done = color(0x5AC576)
    static let idle = color(0x74716C)

    static func status(_ status: ScreenSaveStatus) -> Color {
        switch status {
        case .blocked: blocked
        case .working: working
        case .done: done
        case .idle: idle
        case .unknown: idle.opacity(0.62)
        }
    }

    static func precedence(_ status: ScreenSaveStatus) -> Int {
        switch status {
        case .blocked: 4
        case .working: 3
        case .done: 2
        case .idle: 1
        case .unknown: 0
        }
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
