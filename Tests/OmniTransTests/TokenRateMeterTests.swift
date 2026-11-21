import XCTest
@testable import OmniTrans

// MARK: - P2：token 速率估计

final class TokenRateMeterTests: XCTestCase {

    func testEstimateTokensCJK() {
        XCTAssertEqual(TokenRateMeter.estimateTokens("你好"), 2.0)
        XCTAssertEqual(TokenRateMeter.estimateTokens("こんにちは"), 5.0)  // 假名按 CJK 计
    }

    func testEstimateTokensLatin() {
        XCTAssertEqual(TokenRateMeter.estimateTokens("hello"), 1.25)   // 5 字符 ÷4
        XCTAssertEqual(TokenRateMeter.estimateTokens(""), 0)
    }

    func testEstimateTokensMixed() {
        XCTAssertEqual(TokenRateMeter.estimateTokens("AI你好"), 2.5)    // 2 拉丁 ÷4 + 2 CJK
    }

    func testTTFTRecordedAtFirstBatch() {
        let start = Date()
        var meter = TokenRateMeter(startAt: start)
        _ = meter.feed("early", now: start.addingTimeInterval(0.4))
        XCTAssertEqual(try XCTUnwrap(meter.ttft), 0.4, accuracy: 0.001)
    }

    /// 首个 batch 无可测间隔（rate=nil）；第二个 batch 起产生速率并按 ≤2Hz 节流发布。
    func testRateAndPublishThrottle() {
        let start = Date()
        var meter = TokenRateMeter(startAt: start)

        XCTAssertFalse(meter.feed("aaaa", now: start.addingTimeInterval(0.10)))
        XCTAssertNil(meter.rate)

        XCTAssertTrue(meter.feed("aaaa", now: start.addingTimeInterval(0.20)))
        XCTAssertNotNil(meter.rate)

        // 距上次发布 0.1s < 0.5s → 不发布
        XCTAssertFalse(meter.feed("aaaa", now: start.addingTimeInterval(0.30)))

        // 距上次发布 0.6s ≥ 0.5s → 发布
        XCTAssertTrue(meter.feed("aaaa", now: start.addingTimeInterval(0.80)))
    }

    /// 完成时冻结为整体均值：2 token / 1.0s = 2 tok/s（排除 TTFT）。
    func testFinalRateExcludesTTFT() {
        let start = Date()
        var meter = TokenRateMeter(startAt: start)
        _ = meter.feed("aaaa", now: start.addingTimeInterval(1.0))   // 1 token，首字延迟 1s
        _ = meter.feed("aaaa", now: start.addingTimeInterval(2.0))   // 再 1 token
        XCTAssertEqual(try XCTUnwrap(meter.finalRate()), 2.0, accuracy: 0.01)
    }

    /// 单 batch（非流式）无整体均值 → 不显示标签。
    func testSingleBatchFinalRateNil() {
        let start = Date()
        var meter = TokenRateMeter(startAt: start)
        _ = meter.feed("你好世界", now: start.addingTimeInterval(0.5))
        XCTAssertNil(meter.finalRate())
    }
}