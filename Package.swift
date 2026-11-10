// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SwitchCore"),
        .executableTarget(name: "claude-switch", dependencies: ["SwitchCore"]),
        .executableTarget(name: "ClaudeSwitcher", dependencies: ["SwitchCore"]),
        .testTarget(name: "SwitchCoreTests", dependencies: ["SwitchCore"]),
    ]
)
