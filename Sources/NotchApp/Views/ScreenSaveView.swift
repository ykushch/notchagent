import ScreenSaveKit
import SwiftUI

/// App-owned preview for the same status-only renderer used by the standard
/// macOS `.saver` bundle.
struct ScreenSaveView: View {
    @Bindable var model: NotchViewModel
    let screenIndex: Int
    let screenCount: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScreenSaveStatusView(
                snapshot: model.screenSaveSnapshot(at: context.date),
                now: context.date,
                screenIndex: screenIndex,
                screenCount: screenCount)
        }
    }
}
