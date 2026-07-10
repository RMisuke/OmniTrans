// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OmniTrans",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OmniTrans",
            path: "Sources/OmniTrans",
            swiftSettings: [
                // ── Release-only optimizations ──
                .unsafeFlags(["-whole-module-optimization"], .when(configuration: .release)),
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),

                // ── Swift 6 strict concurrency ──
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release)),
            ]
        )
    ]
)
