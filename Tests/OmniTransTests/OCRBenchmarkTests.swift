import XCTest
import AppKit
import CoreVideo
import CoreGraphics
@testable import OmniTrans

/// OCR 重构验收基准（计划步骤 8）：
/// - **准确率**：合成测试图（纯英文 / 中文 / 中英混排）经真实 Vision 推理后，
///   与地面真值做编辑距离对比，字符准确率必须 ≥ 阈值。
/// - **速度**：记录各场景端到端耗时（含预处理 + 竞速识别 + 组装），
///   输出 `BENCH|name|ms|accuracy` 行供 `plans/ocr-refactor-benchmarks.md` 汇总。
///
/// 测试图在运行时以 CoreGraphics 合成渲染（白底黑字、系统字体），
/// 无需外部 fixture 文件；Vision 在干净渲染文本上的基线准确率应接近满分，
/// 阈值留有跨机型余量。
final class OCRBenchmarkTests: XCTestCase {

    // MARK: - 基准用例定义

    private struct Fixture {
        let name: String
        let text: String
        let width: Int
        let height: Int
        let fontSize: CGFloat
    }

    /// 三类典型场景 × 两档分辨率（Retina 原生尺寸模拟高 DPI 截屏）。
    private lazy var fixtures: [Fixture] = [
        Fixture(name: "english_paragraph",
                text: "The quick brown fox jumps over the lazy dog. "
                    + "Pack my box with five dozen liquor jugs. "
                    + "How vexingly quick daft zebras jump!",
                width: 1600, height: 400, fontSize: 32),
        Fixture(name: "chinese_paragraph",
                text: "屏幕识别可以快速提取文字内容，支持中英混合排版。"
                    + "重构后的引擎采用并行竞速策略，先完成者胜出。",
                width: 1600, height: 400, fontSize: 34),
        Fixture(name: "mixed_line",
                text: "Version 2.0 发布说明：新增 OCR 竞速引擎，速度提升约 50%。",
                width: 1400, height: 200, fontSize: 30),
    ]

    /// 字符准确率阈值 —— 干净渲染文本上留足跨机型余量。
    private static let minAccuracy = 0.80

    // MARK: - 准确率基准

    func testAccuracyOnSyntheticFixtures() async throws {
        try await warmUp()
        for fixture in fixtures {
            let (result, _) = try await runFixture(fixture)
            guard let result else {
                XCTFail("\(fixture.name): 未识别出任何文字")
                continue
            }
            let accuracy = Self.characterAccuracy(recognized: result.text, groundTruth: fixture.text)
            print("BENCH|\(fixture.name)|accuracy=\(String(format: "%.4f", accuracy))|chars=\(result.text.count)")
            XCTAssertGreaterThanOrEqual(
                accuracy, Self.minAccuracy,
                "\(fixture.name) 准确率 \(accuracy) 低于阈值 —— 重构不得降低准确率")
        }
    }

    // MARK: - 耗时基准

    func testLatencyOnSyntheticFixtures() async throws {
        try await warmUp()
        for fixture in fixtures {
            let (_, elapsedMs) = try await runFixture(fixture)
            print(String(format: "BENCH|%@|latency_ms=%.1f", fixture.name, elapsedMs))
            // 宽松上限：合成图面积 ≤ 预算，竞速下推理应在数秒内完成；
            // 若显著劣化说明管线出现回归。
            XCTAssertLessThan(elapsedMs, 15_000, "\(fixture.name) 端到端耗时异常")
        }
    }

    /// 小区域走 mixed 单轨启发式（不触发竞速）的冒烟验证。
    func testSmallRegionSingleTrackPath() async throws {
        try await warmUp()
        let fixture = Fixture(name: "small_region",
                              text: "确定 Cancel",
                              width: 480, height: 120, fontSize: 24)
        let (result, elapsedMs) = try await runFixture(fixture)
        XCTAssertNotNil(result, "小区域应能识别出文字")
        if let result {
            let accuracy = Self.characterAccuracy(recognized: result.text,
                                                  groundTruth: fixture.text)
            print(String(format: "BENCH|small_region|latency_ms=%.1f|accuracy=%.4f", elapsedMs, accuracy))
        }
    }

    // MARK: - 执行封装

    /// 渲染 → 竞速识别 → 组装，返回结果与毫秒耗时。
    private func runFixture(_ fixture: Fixture) async throws -> (OCRResult?, Double) {
        let buffer = try Self.renderFixture(fixture)
        var pipeline = OCRCapturePipeline.shared

        let start = ContinuousClock.now
        // 组装阶段需要 appKitRect 做坐标映射；此处仅关心文字内容与耗时。
        let lines = await pipeline.racer.recognizeBest(buffer)
        let elapsedMs = Double((ContinuousClock.now - start).components.attoseconds) / 1e15

        let result = lines.flatMap { OCRResultAssembler.assemble($0, appKitRect: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height)) }
        return (result, elapsedMs)
    }

    /// 首次 Vision 调用会加载模型（~1s），正式计时前预热。
    private func warmUp() async throws {
        let buffer = try Self.renderFixture(fixtures[2])
        let recognizer = VisionTextRecognizer()
        _ = try? await recognizer.recognize(buffer, track: .english)
    }

    // MARK: - 合成图渲染

    /// 白底黑字渲染文本到 BGRA CVPixelBuffer（Vision 友好格式）。
    private static func renderFixture(_ fixture: Fixture) throws -> CVPixelBuffer {
        guard let buffer = ImagePreprocessor.createBuffer(width: fixture.width,
                                                          height: fixture.height) else {
            throw XCTSkip("CVPixelBufferCreate failed")
        }

        // 先把文字画进 NSImage（AppKit 富文本排版最省事）
        let image = NSImage(size: NSSize(width: fixture.width, height: fixture.height))
        image.lockFocusFlipped(false)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: fixture.width, height: fixture.height)).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fixture.fontSize),
            .foregroundColor: NSColor.black,
        ]
        NSAttributedString(string: fixture.text, attributes: attrs)
            .draw(in: NSRect(x: 16, y: 16, width: fixture.width - 32, height: fixture.height - 32))
        image.unlockFocus()

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw XCTSkip("cgImage conversion failed")
        }

        // 把 CGImage 画进像素缓冲（BGRA little-endian）
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw XCTSkip("base address unavailable")
        }
        let ctx = CGContext(data: base,
                            width: fixture.width,
                            height: fixture.height,
                            bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.interpolationQuality = .high
        ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height))
        return buffer
    }

    // MARK: - 字符准确率

    /// 归一化编辑距离相似度：1 - levenshtein/max(len)。
    /// 忽略空白差异（OCR 的空格插入/丢失不算字符错误）。
    static func characterAccuracy(recognized: String, groundTruth: String) -> Double {
        let a = recognized.filter { !$0.isWhitespace }
        let b = groundTruth.filter { !$0.isWhitespace }
        guard !b.isEmpty else { return a.isEmpty ? 1 : 0 }
        let dist = levenshtein(a, b)
        return max(0, 1 - Double(dist) / Double(b.count))
    }

    private static func levenshtein(_ s: any StringProtocol, _ t: some StringProtocol) -> Int {
        let a = Array(s), b = Array(t)
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
