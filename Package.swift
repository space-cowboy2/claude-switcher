// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SecondWind",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SwitchCore"),
        .executableTarget(name: "secondwind", dependencies: ["SwitchCore"]),
        .executableTarget(name: "SecondWindBar", dependencies: ["SwitchCore"]),
        .testTarget(name: "SwitchCoreTests", dependencies: ["SwitchCore"]),
    ]
)
