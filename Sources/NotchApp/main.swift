import AppKit

let launchMode = AppLaunchMode(arguments: CommandLine.arguments)
let app = NSApplication.shared
let delegate = AppDelegate(launchMode: launchMode)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
