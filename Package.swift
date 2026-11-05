// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shrink",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure transcoding logic, no UI — this is what the tests exercise.
        .target(name: "ShrinkCore"),
        .executableTarget(name: "Shrink", dependencies: ["ShrinkCore"]),
        .testTarget(name: "ShrinkCoreTests", dependencies: ["ShrinkCore"]),
    ]
)
