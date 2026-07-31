import SwiftUI

struct AuroraScreenSaveScene: View {
    let snapshot: ScreenSaveSnapshot
    let now: Date
    let screenIndex: Int
    let screenCount: Int
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Color(red: 0.008, green: 0.018, blue: 0.045)
            AuroraScreenSaveBackdrop(
                status: overallStatus,
                reduceMotion: reduceMotion,
                screenSeed: screenIndex)
            ScreenSaveDashboard(
                snapshot: snapshot, now: now,
                screenIndex: screenIndex, screenCount: screenCount)
        }
        .environment(\.screenSaveTheme, .aurora)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var overallStatus: ScreenSaveStatus {
        snapshot.agents.map(\.status).max {
            ScreenSaveTheme.precedence($0) < ScreenSaveTheme.precedence($1)
        } ?? .unknown
    }
}

private struct AuroraScreenSaveBackdrop: View {
    let status: ScreenSaveStatus
    let reduceMotion: Bool
    let screenSeed: Int
    @Environment(\.screenSaveTheme) private var theme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.01, green: 0.035, blue: 0.075),
                    Color(red: 0.012, green: 0.018, blue: 0.055),
                    Color(red: 0.025, green: 0.012, blue: 0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            TimelineView(.animation(
                minimumInterval: 1.0 / 20.0,
                paused: reduceMotion
            )) { context in
                Canvas(
                    opaque: false,
                    colorMode: .linear,
                    rendersAsynchronously: true
                ) { graphics, size in
                    let time = reduceMotion
                        ? 0 : context.date.timeIntervalSinceReferenceDate
                    drawStatusGlow(in: &graphics, size: size, time: time)
                    drawStars(in: &graphics, size: size, time: time)
                    drawAurora(in: &graphics, size: size, time: time)
                }
            }

            RadialGradient(
                colors: [.clear, Color.black.opacity(0.16), Color.black.opacity(0.72)],
                center: .center,
                startRadius: 120,
                endRadius: 1_100)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.36),
                    .clear,
                    Color.black.opacity(0.30),
                ],
                startPoint: .top,
                endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }

    private func drawStatusGlow(
        in graphics: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval
    ) {
        let drift = CGFloat(sin(time * 0.035 + Double(screenSeed)))
        let center = CGPoint(
            x: size.width * (0.67 + drift * 0.06),
            y: size.height * 0.52)
        let diameter = max(size.width, size.height) * 0.92
        let rect = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter)
        graphics.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [
                    theme.status(status).opacity(0.095),
                    theme.status(status).opacity(0.025),
                    .clear,
                ]),
                center: center,
                startRadius: 0,
                endRadius: diameter / 2))
    }

    private func drawStars(
        in graphics: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval
    ) {
        for index in 0..<72 {
            let seed = Double(index + screenSeed * 101)
            let baseX = unit(sin(seed * 12.9898 + 0.2) * 43_758.5453)
            let baseY = unit(sin(seed * 78.233 + 4.7) * 12_345.678)
            let depth = 0.35 + Double(unit(seed * 8.31)) * 0.65
            let drift = reduceMotion ? 0 : time * (0.00035 + depth * 0.00032)
            let x = size.width * unit(Double(baseX) + drift)
            let y = size.height * baseY
            let twinkle = 0.45 + 0.55 * sin(time * (0.28 + depth * 0.3) + seed)
            let diameter = CGFloat(0.7 + depth * 1.7)
            let rect = CGRect(
                x: x - diameter / 2,
                y: y - diameter / 2,
                width: diameter,
                height: diameter)
            graphics.fill(
                Path(ellipseIn: rect),
                with: .color(Color.white.opacity(0.14 + twinkle * 0.34)))
        }
    }

    private func drawAurora(
        in graphics: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval
    ) {
        let ribbonColors: [[Color]] = [
            [.clear, Color(red: 0.08, green: 0.90, blue: 0.68).opacity(0.32), .clear],
            [.clear, Color(red: 0.18, green: 0.55, blue: 1.00).opacity(0.28), .clear],
            [.clear, Color(red: 0.66, green: 0.28, blue: 0.96).opacity(0.25), .clear],
            [.clear, Color(red: 0.12, green: 0.82, blue: 0.91).opacity(0.20), .clear],
        ]

        graphics.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.addFilter(.blur(radius: 46))

            for index in ribbonColors.indices {
                let phase = Double(index) * 1.73 + Double(screenSeed) * 0.61
                var path = Path()
                let sampleCount = 32
                for sample in 0...sampleCount {
                    let progress = CGFloat(sample) / CGFloat(sampleCount)
                    let x = size.width * (progress * 1.20 - 0.10)
                    let primaryWave = sin(
                        Double(progress) * 5.2 + phase + time * (0.025 + Double(index) * 0.004))
                    let secondaryWave = cos(
                        Double(progress) * 2.4 - phase * 0.7 + time * 0.017)
                    let baseline = 0.26 + CGFloat(index) * 0.135
                    let y = size.height * (
                        baseline + CGFloat(primaryWave) * 0.10
                            + CGFloat(secondaryWave) * 0.045)
                    if sample == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                layer.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: ribbonColors[index]),
                        startPoint: CGPoint(x: 0, y: size.height * 0.5),
                        endPoint: CGPoint(x: size.width, y: size.height * 0.5)),
                    style: StrokeStyle(
                        lineWidth: size.height * (0.13 + CGFloat(index) * 0.018),
                        lineCap: .round,
                        lineJoin: .round))
            }
        }
    }

    private func unit(_ value: Double) -> CGFloat {
        CGFloat(value - floor(value))
    }
}

extension ScreenSaveTheme {
    static let aurora = ScreenSaveTheme(
        surface: color(0x06101F),
        elevated: color(0x0D1929),
        hairline: color(0x3A5870),
        primaryText: color(0xEDF8FF),
        secondaryText: color(0x91AABB),
        working: color(0x5DE4C7),
        blocked: color(0xFF9B78),
        done: color(0x72E5A5),
        idle: color(0x71889A))
}
