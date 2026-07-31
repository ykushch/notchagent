import AppKit
import SwiftUI

struct WallpaperScreenSaveScene: View {
    let snapshot: ScreenSaveSnapshot
    let asset: ScreenSaveWallpaperAsset?
    let now: Date
    let screenIndex: Int
    let screenCount: Int

    var body: some View {
        ZStack {
            WallpaperScreenSaveBackdrop(asset: asset, status: overallStatus)
            ScreenSaveDashboard(
                snapshot: snapshot, now: now,
                screenIndex: screenIndex, screenCount: screenCount)
        }
        .environment(\.screenSaveTheme, .wallpaper)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var overallStatus: ScreenSaveStatus {
        snapshot.agents.map(\.status).max {
            ScreenSaveTheme.precedence($0) < ScreenSaveTheme.precedence($1)
        } ?? .unknown
    }
}

private struct WallpaperScreenSaveBackdrop: View {
    let asset: ScreenSaveWallpaperAsset?
    let status: ScreenSaveStatus
    @Environment(\.screenSaveTheme) private var theme
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.018, green: 0.024, blue: 0.034)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(1.006)
                        .blur(radius: 1.2)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [
                            Color(red: 0.035, green: 0.05, blue: 0.075),
                            Color(red: 0.012, green: 0.016, blue: 0.026),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                }

                Color.black.opacity(0.30)

                RadialGradient(
                    colors: [
                        theme.status(status).opacity(0.13),
                        .clear,
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.58)

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.34),
                        .clear,
                        Color.black.opacity(0.46),
                    ],
                    startPoint: .top,
                    endPoint: .bottom)

                RadialGradient(
                    colors: [.clear, Color.black.opacity(0.48)],
                    center: .center,
                    startRadius: min(proxy.size.width, proxy.size.height) * 0.18,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.72)
            }
        }
        .task(id: asset?.fileName) {
            guard let asset,
                  let url = ScreenSaveWallpaperCacheLocation.fileURL(for: asset) else {
                image = nil
                return
            }
            image = NSImage(contentsOf: url)
        }
        .allowsHitTesting(false)
    }
}

extension ScreenSaveTheme {
    static let wallpaper = ScreenSaveTheme(
        surface: color(0x070B10),
        elevated: color(0x111923),
        hairline: color(0x5A6672),
        primaryText: color(0xF4F7F9),
        secondaryText: color(0xA9B2BB),
        working: color(0xF1C75B),
        blocked: color(0xFF947D),
        done: color(0x69D892),
        idle: color(0x8C969F))
}
