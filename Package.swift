// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "tinkertown",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TinkerTownCore", targets: ["TinkerTownCore"]),
        .executable(name: "tinkertown", targets: ["tinkertown"]),
        .executable(name: "TinkerTownApp", targets: ["TinkerTownApp"])
    ],
    targets: [
        .target(name: "TinkerTownCore"),
        .executableTarget(name: "tinkertown", dependencies: ["TinkerTownCore"]),
        .executableTarget(
            name: "TinkerTownApp",
            dependencies: ["TinkerTownCore"],
            path: "Sources/TinkerTownApp"
        ),
        .testTarget(name: "TinkerTownCoreTests", dependencies: ["TinkerTownCore"])
    ]
)
