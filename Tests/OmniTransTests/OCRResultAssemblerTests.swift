import XCTest
import CoreGraphics
@testable import OmniTrans

/// 覆盖「结果组装器」：置信过滤、空间排序、行拼接、相邻重复去重、坐标映射。
final class OCRResultAssemblerTests: XCTestCase {

    private let appKitRect = CGRect(x: 100, y: 200, width: 800, height: 600)

    private func line(_ text: String,
                      confidence: Float = 0.9,
                      x: CGFloat, y: CGFloat, w: CGFloat = 0.3, h: CGFloat = 0.04) -> RecognizedLine {
        RecognizedLine(text: text, confidence: confidence,
                       normalizedBoundingBox: CGRect(x: x, y: y, width: w, height: h))
    }

    // MARK: - 置信过滤

    func testLowConfidenceLinesFiltered() {
        let result = OCRResultAssembler.assemble([
            line("keep me", confidence: 0.9, x: 0.1, y: 0.5),
            line("drop me", confidence: 0.30, x: 0.1, y: 0.4),
        ], appKitRect: appKitRect)
        XCTAssertEqual(result?.text, "keep me")
        XCTAssertEqual(result?.lines.count, 1)
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(OCRResultAssembler.assemble([], appKitRect: appKitRect))
        // 全部被过滤时也返回 nil
        XCTAssertNil(OCRResultAssembler.assemble(
            [line("x", confidence: 0.01, x: 0, y: 0)], appKitRect: appKitRect))
    }

    // MARK: - 空间排序

    func testLinesOrderedTopToBottomLeftToRight() {
        // 归一化坐标 origin 左下：y 大者在屏幕上方。
        let result = OCRResultAssembler.assemble([
            line("right", x: 0.6, y: 0.9),
            line("left",  x: 0.1, y: 0.9),
            line("top",   x: 0.1, y: 0.8),
            line("bottom", x: 0.1, y: 0.2),
        ], appKitRect: appKitRect)

        // y=0.9 行在最上方（其内 left → right），随后 y=0.8、y=0.2。
        XCTAssertEqual(result?.text, "left right\ntop\nbottom")
    }

    func testSameRowJoinedWithSpaceDifferentRowWithNewline() {
        let result = OCRResultAssembler.assemble([
            line("B", x: 0.5, y: 0.5),
            line("A", x: 0.1, y: 0.5),
            line("C", x: 0.1, y: 0.3),
        ], appKitRect: appKitRect)
        XCTAssertEqual(result?.text, "A B\nC")
    }

    // MARK: - 相邻重复去重

    func testConsecutiveDuplicateRemoved() {
        let result = OCRResultAssembler.assemble([
            line("dup", x: 0.1, y: 0.7),
            line("dup", x: 0.6, y: 0.7),
            line("next", x: 0.1, y: 0.5),
        ], appKitRect: appKitRect)
        XCTAssertEqual(result?.text, "dup\nnext")
    }

    // MARK: - 坐标映射（归一化 → AppKit 全局）

    func testNormalizedBoxMappedToAppKitGlobalFrame() {
        let result = OCRResultAssembler.assemble(
            [line("hello", x: 0.25, y: 0.50, w: 0.25, h: 0.10)],
            appKitRect: appKitRect)

        let frame = result?.lines.first?.appKitFrame
        XCTAssertNotNil(frame)
        // DisplayGeometry 映射：origin 左下，相对捕获区域原点偏移 + 缩放。
        XCTAssertEqual(frame!.minX, appKitRect.minX + 0.25 * appKitRect.width, accuracy: 1.0)
        XCTAssertEqual(frame!.height, 0.10 * appKitRect.height, accuracy: 1.0)
        XCTAssertTrue(appKitRect.contains(frame!))
    }

    // MARK: - 质量评分

    func testQualityScoreWeightsByCharCountAndConfidence() {
        let short = [line("hi", confidence: 0.9, x: 0, y: 0)]
        let long = [
            line("hello world this is longer", confidence: 0.85, x: 0, y: 0),
            line("second line of content", confidence: 0.80, x: 0, y: 0.2),
        ]
        XCTAssertLessThan(OCRResultAssembler.qualityScore(short),
                          OCRResultAssembler.qualityScore(long))
        // 空结果评分为 0
        XCTAssertEqual(OCRResultAssembler.qualityScore([]), 0)
    }

    // MARK: - 平均置信度（竞速仲裁度量）

    func testMeanConfidenceEmptyIsZero() {
        let lines = [
            RecognizedLine(text: "a", confidence: 0.8, normalizedBoundingBox: .zero),
            RecognizedLine(text: "b", confidence: 0.6, normalizedBoundingBox: .zero),
        ]
        XCTAssertEqual(RacingLanguageStrategy.meanConfidence(lines), 0.7, accuracy: 0.001)
        XCTAssertEqual(RacingLanguageStrategy.meanConfidence([]), 0)
    }
}
