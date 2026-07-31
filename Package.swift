// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HerdrClient", targets: ["HerdrClient"]),
        .library(name: "ScreenSaveKit", targets: ["ScreenSaveKit"]),
        .executable(name: "notchctl", targets: ["notchctl"]),
        .executable(name: "NotchApp", targets: ["NotchApp"]),
        // Command-line alias for launching NotchApp directly into its ambient
        // full-screen presentation.
        .executable(name: "screensave", targets: ["NotchApp"]),
    ],
    targets: [
        // Milestone M1: headless core (socket client + models + store + classifier + actions).
        .target(
            name: "HerdrClient"
        ),
        .target(
            name: "ScreenSaveKit"
        ),
        // Milestone M1 gate: CLI harness that dogfoods the core.
        .executableTarget(
            name: "notchctl",
            dependencies: ["HerdrClient"]
        ),
        // Milestone M2: notch NSPanel UI app.
        .executableTarget(
            name: "NotchApp",
            dependencies: ["HerdrClient", "ScreenSaveKit"],
            exclude: ["README.md"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "HerdrClientTests",
            dependencies: ["HerdrClient"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "NotchAppTests",
            dependencies: ["NotchApp", "ScreenSaveKit"]
        ),
    ]
)
