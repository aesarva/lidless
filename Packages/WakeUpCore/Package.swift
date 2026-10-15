// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WakeUpCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WakeUpCore", targets: ["WakeUpCore"])],
    targets: [
        .target(name: "WakeUpCore"),
        .testTarget(name: "WakeUpCoreTests", dependencies: ["WakeUpCore"]),
    ]
)
