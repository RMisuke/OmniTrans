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
                // Whole-module optimization in release builds
                .unsafeFlags(["-whole-module-optimization"], .when(configuration: .release)),
                // Enable Swift 6 strict concurrency checking
                .enableExperimentalFeature("StrictConcurrency"),
                // Access-level imports reduce symbol visibility and rebuild scope
                .enableExperimentalFeature("AccessLevelOnImport"),
            ]
        )
    ]
)
