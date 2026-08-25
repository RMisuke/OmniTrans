// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OmniTrans",
    platforms: [.macOS(.v14)],
    targets: [
        // ── 屏幕坐标系统一转换层（独立库，供 App 与单元测试共同依赖）──
        .target(
            name: "DisplayGeometry",
            path: "Sources/DisplayGeometry",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
            ]
        ),
        .executableTarget(
            name: "OmniTrans",
            dependencies: ["DisplayGeometry"],
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
        ),
        // ── 多屏坐标转换单元测试 ──
        .testTarget(
            name: "DisplayGeometryTests",
            dependencies: ["DisplayGeometry"],
            path: "Tests/DisplayGeometryTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
            ]
        ),
        // ── 应用核心逻辑单元测试（OCR 代际守卫等）──
        .testTarget(
            name: "OmniTransTests",
            dependencies: ["OmniTrans"],
            path: "Tests/OmniTransTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
            ]
        ),
    ]
)
