// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "tinkertown",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TinkerTownCore", targets: ["TinkerTownCore"]),
        .executable(name: "tinkertown", targets: ["tinkertown"])
    ],
    targets: [
        .target(name: "TinkerTownCore"),
        .executableTarget(name: "tinkertown", dependencies: ["TinkerTownCore"]),
        .testTarget(name: "TinkerTownCoreTests", dependencies: ["TinkerTownCore"])
    ]
)
