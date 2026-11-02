// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ZPSMacClean",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MacCleanCore"),
        .executableTarget(name: "ZPSMacClean", dependencies: ["MacCleanCore"]),
        .testTarget(name: "MacCleanCoreTests", dependencies: ["MacCleanCore"]),
    ]
)
