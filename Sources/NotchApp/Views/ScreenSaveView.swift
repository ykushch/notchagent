import Foundation
import ScreenSaveKit
import SwiftUI

/// App-owned preview for the same status-only renderer used by the standard
/// macOS `.saver` bundle.
struct ScreenSaveView: View {
    @Bindable var model: NotchViewModel
    @Bindable var settings: Settings
    let displayID: String?
    let screenIndex: Int
    let screenCount: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScreenSaveStatusView(
                snapshot: model.screenSaveSnapshot(at: context.date),
                configuration: configuration,
                now: context.date,
                displayID: displayID,
                screenIndex: screenIndex,
                screenCount: screenCount)
        }
    }

    private var configuration: ScreenSaveConfiguration {
        let cached: ScreenSaveConfiguration?
        if let data = try? Data(contentsOf: ScreenSaveConfigurationLocation.fileURL()) {
            cached = try? JSONDecoder().decode(ScreenSaveConfiguration.self, from: data)
        } else {
            cached = nil
        }
        return ScreenSaveConfiguration(
            style: settings.screenSaveStyle,
            wallpapers: cached?.wallpapers ?? [])
    }
}
