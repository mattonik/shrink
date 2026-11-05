// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shrink",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure transcoding logic, no UI — this is what the tests exercise.
        .target(name: "ShrinkCore"),
        .executableTarget(name: "Shrink", dependencies: ["ShrinkCore"]),
        // Real PDF and video files for the tests; never linked into the app.
        .target(name: "ShrinkTestSupport"),
        .testTarget(name: "ShrinkCoreTests", dependencies: ["ShrinkCore", "ShrinkTestSupport"]),
        // The app's conversion queue, driven end to end without a window.
        .testTarget(name: "ShrinkTests", dependencies: ["Shrink", "ShrinkCore", "ShrinkTestSupport"]),
    ]
)
