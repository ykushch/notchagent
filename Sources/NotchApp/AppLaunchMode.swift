import Foundation

enum AppLaunchMode: Sendable, Equatable {
    case normal
    case screenSave

    init(arguments: [String]) {
        let executable = arguments.first.map {
            URL(fileURLWithPath: $0).lastPathComponent.lowercased()
        }
        let requestedMode = arguments.dropFirst().first?.lowercased()
        if executable == "screensave"
            || requestedMode == "screensave"
            || requestedMode == "--screensave" {
            self = .screenSave
        } else {
            self = .normal
        }
    }
}
