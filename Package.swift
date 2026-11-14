// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmniTrans",
    platforms: [.macOS(.v15)],
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
                // CMO: 跨模块内联，无需 WMO 即可获得大部分优化收益
                // 注意：SwiftPM release 默认已启用 -O，无需额外指定
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
        // ── 应用核心逻辑单元测试（OCR 代际守卫 / 结果组装 / 基准）──
        .testTarget(
            name: "OmniTransTests",
            dependencies: ["OmniTrans"],
            path: "Tests/OmniTransTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .enableExperimentalFeature("AccessLevelOnImport"),
            ]
        ),
    ],
    // 保持 Swift 5 语言模式：仓库按 Swift 5 + 实验性 StrictConcurrency 演进，
    // 升级到 Swift 6 语言模式属独立事项，不与本次 OCR 重构混合。
    swiftLanguageModes: [.v5]
)
