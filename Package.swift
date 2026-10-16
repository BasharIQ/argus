// swift-tools-version:5.9
import PackageDescription

// XCTest and the toolchain Swift Testing runtime are unavailable under
// Command Line Tools, so tests are a plain executable with a tiny harness.
let package = Package(
    name: "Argus",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ArgusCore", swiftSettings: [.define("DEBUG", .when(configuration: .debug))]),
        .executableTarget(
            name: "ArgusApp",
            dependencies: ["ArgusCore"],
            resources: [.process("Resources")],
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
        ),
        .executableTarget(name: "ArgusTests", dependencies: ["ArgusCore"], path: "Tests/ArgusTests"),
    ]
)
