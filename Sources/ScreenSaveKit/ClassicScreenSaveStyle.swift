import SwiftUI

/// The original screen-saver presentation, preserved as the first concrete
/// style. New styles can supply another scene and theme without changing the
/// shared status dashboard.
struct ClassicScreenSaveScene: View {
    let snapshot: ScreenSaveSnapshot
    let now: Date
    let screenIndex: Int
    let screenCount: Int
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Color.black
            ClassicScreenSaveBackdrop(
                status: overallStatus,
                reduceMotion: reduceMotion,
                screenSeed: screenIndex)
            ScreenSaveDashboard(
                snapshot: snapshot, now: now,
                screenIndex: screenIndex, screenCount: screenCount)
        }
        .environment(\.screenSaveTheme, .classic)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var overallStatus: ScreenSaveStatus {
        snapshot.agents.map(\.status).max {
            ScreenSaveTheme.precedence($0) < ScreenSaveTheme.precedence($1)
        } ?? .unknown
    }
}

struct ClassicScreenSaveBackdrop: View {
    let status: ScreenSaveStatus
    let reduceMotion: Bool
    let screenSeed: Int
    @Environment(\.screenSaveTheme) private var theme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) {
            context in
            Canvas { graphics, size in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                let accent = theme.status(status)
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
                    theme.surface.opacity(0.78),
                    Color.black.opacity(0.38),
                    theme.surface.opacity(0.88),
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

struct ScreenSaveTheme {
    let surface: Color
    let elevated: Color
    let hairline: Color
    let primaryText: Color
    let secondaryText: Color
    let working: Color
    let blocked: Color
    let done: Color
    let idle: Color

    var tertiaryText: Color { secondaryText.opacity(0.62) }

    static let classic = ScreenSaveTheme(
        surface: color(0x110F0D),
        elevated: color(0x1D1A16),
        hairline: color(0x35322E),
        primaryText: color(0xF0EEE9),
        secondaryText: color(0x95928D),
        working: color(0xD6A20A),
        blocked: color(0xFB8371),
        done: color(0x5AC576),
        idle: color(0x74716C))

    func status(_ status: ScreenSaveStatus) -> Color {
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

    static func color(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

private struct ScreenSaveThemeKey: EnvironmentKey {
    static let defaultValue = ScreenSaveTheme.classic
}

extension EnvironmentValues {
    var screenSaveTheme: ScreenSaveTheme {
        get { self[ScreenSaveThemeKey.self] }
        set { self[ScreenSaveThemeKey.self] = newValue }
    }
}
