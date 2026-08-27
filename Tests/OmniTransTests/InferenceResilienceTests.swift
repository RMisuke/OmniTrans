import XCTest
import CoreVideo
import os
@testable import OmniTrans

// MARK: - 故障注入 Mock

/// E5RT 冷启动式**瞬时**故障：前 `failTimes` 次调用抛 Vision/E5RT 风格错误，
/// 之后恢复正常。复现「ANE 管线未就绪 → 首次失败 → 重试应恢复」场景。
final class FlakyE5RTRecognizer: TextRecognizing, @unchecked Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    private let failTimes: Int

    init(failTimes: Int) { self.failTimes = failTimes }

    var callCount: Int { calls.withLock { $0 } }

    func recognize(_ buffer: CVPixelBuffer, track: LanguageTrack) async throws -> [RecognizedLine] {
        let n = calls.withLock { $0 += 1; return $0 }
        if n <= failTimes {
            // 与真机日志一致的错误形态（Code: 13 = ANE 操作创建失败）
            throw NSError(domain: "com.apple.TextRecognition", code: 13,
                          userInfo: [NSLocalizedDescriptionKey:
                            "e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed (Code: 13)"])
        }
        return [RecognizedLine(text: "hello world", confidence: 0.9,
                               normalizedBoundingBox: CGRect(x: 0, y: 0, width: 0.5, height: 0.1))]
    }
}

/// **永久挂起**且不响应取消：模拟真机观察到的 E5RT 停滞
/// （请求卡住约 40s 才落错，期间 Task.cancel() 无效）。
final class HangingRecognizer: TextRecognizing, @unchecked Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    var callCount: Int { calls.withLock { $0 } }

    func recognize(_ buffer: CVPixelBuffer, track: LanguageTrack) async throws -> [RecognizedLine] {
        _ = calls.withLock { $0 += 1 }
        // 刻意忽略取消：循环 sleep，直到 30s 时限为止（复现 Vision 停滞语义）
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(30) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return []
    }
}

// MARK: - 复现测试

/// 复现并验证 E5RT 冷启动故障下的三层韧性：
/// 1. 瞬时失败 → 自动重试恢复（用户无感）
/// 2. 持续失败 → 有限次尝试后快速返回 nil（不无限等待）
/// 3. 推理挂起 → 真实超时兜底，调用方按时拿到结果（挂起任务弃管）
final class InferenceResilienceTests: XCTestCase {

    /// 测试间共享熔断器状态隔离：超时类测试会向共享 breaker 记录失败，
    /// 不重置会令后续测试被冷却期误拦。
    private func resetSharedBreaker() async {
        await OCRInferenceBreaker.shared.reset()
    }

    /// 小缓冲（400×300 = 120k px < 150k 阈值）→ 走 solo 单轨路径。
    private func makeSmallBuffer() throws -> CVPixelBuffer {
        guard let buf = ImagePreprocessor.createBuffer(width: 400, height: 300) else {
            throw XCTSkip("CVPixelBufferCreate failed")
        }
        return buf
    }

    /// 大缓冲（600×400 = 240k px ≥ 150k 阈值）→ 走双轨竞速路径。
    private func makeLargeBuffer() throws -> CVPixelBuffer {
        guard let buf = ImagePreprocessor.createBuffer(width: 600, height: 400) else {
            throw XCTSkip("CVPixelBufferCreate failed")
        }
        return buf
    }

    // ── 1. 瞬时失败 → 重试恢复 ──

    func testSoloRetryRecoversFromTransientE5RTFailure() async throws {
        await resetSharedBreaker()
        let buffer = try makeSmallBuffer()
        let mock = FlakyE5RTRecognizer(failTimes: 1)
        var strategy = RacingLanguageStrategy(
            recognizer: mock,
            inferenceDeadline: .seconds(5),
            retryBackoff: .milliseconds(10),
            maxAttempts: 3)

        let result = await strategy.recognizeBest(buffer)
        XCTAssertNotNil(result, "瞬时 E5RT 失败后重试必须恢复出结果")
        XCTAssertEqual(mock.callCount, 2, "应恰好调用识别器 2 次（1 失败 + 1 重试成功）")
        XCTAssertEqual(result?.first?.text, "hello world")
    }

    func testRaceRetryRecoversFromTransientE5RTFailure() async throws {
        await resetSharedBreaker()
        let buffer = try makeLargeBuffer()
        let mock = FlakyE5RTRecognizer(failTimes: 2) // en、mixed 两轨首调各失败一次
        var strategy = RacingLanguageStrategy(
            recognizer: mock,
            inferenceDeadline: .seconds(5),
            retryBackoff: .milliseconds(10),
            maxAttempts: 3)

        let result = await strategy.recognizeBest(buffer)
        XCTAssertNotNil(result, "竞速双轨各失败一次后重试必须恢复")
        // 调用数存在合法竞态：en 轨重试成功（第 3 次）即早期采纳并取消 mixed 轨，
        // 但 mixed 轨的重试可能已先发出（第 4 次）—— 3~4 次均正确。
        XCTAssertTrue((3...4).contains(mock.callCount),
                      "应恰为 3~4 次调用（两轨首调 + 合法竞态的重试），实际 \(mock.callCount)")
    }

    // ── 2. 持续失败 → 有限次尝试后快速放弃 ──

    func testSoloRetryExhaustsAndReturnsNilQuickly() async throws {
        await resetSharedBreaker()
        let buffer = try makeSmallBuffer()
        let mock = FlakyE5RTRecognizer(failTimes: .max) // 永远失败
        var strategy = RacingLanguageStrategy(
            recognizer: mock,
            inferenceDeadline: .seconds(5),
            retryBackoff: .milliseconds(10),
            maxAttempts: 2)

        let start = ContinuousClock.now
        let result = await strategy.recognizeBest(buffer)
        let elapsed = ContinuousClock.now - start

        XCTAssertNil(result, "持续失败应返回 nil")
        XCTAssertEqual(mock.callCount, 2, "重试次数应有上限（maxAttempts=2）")
        XCTAssertLessThan(elapsed, .seconds(3), "持续失败必须快速返回，不能拖住调用方")
    }

    // ── 3. 推理挂起 → 真实超时兜底（核心回归项）──

    func testSoloDeadlineAbandonsHungInference() async throws {
        await resetSharedBreaker()
        let buffer = try makeSmallBuffer()
        let mock = HangingRecognizer()
        var strategy = RacingLanguageStrategy(
            recognizer: mock,
            inferenceDeadline: .milliseconds(300),
            retryBackoff: .milliseconds(10),
            maxAttempts: 1) // 单次挂起即可验证超时，避免测试拖长

        let start = ContinuousClock.now
        let result = await strategy.recognizeBest(buffer)
        let elapsed = ContinuousClock.now - start

        XCTAssertNil(result, "挂起的推理超时后应返回 nil 而非永久等待")
        // 挂起 mock 本体 30s 才返回 —— 若超时兜底失效，这里会卡满 30s。
        // 留 1s 余量覆盖 CI 慢机调度。
        XCTAssertLessThan(elapsed, .seconds(1.3),
                          "solo 路径必须有真实超时兜底（实际耗时 \(elapsed)）")
    }

    func testRaceDeadlineReturnsWhenBothTracksHang() async throws {
        await resetSharedBreaker()
        let buffer = try makeLargeBuffer()
        let mock = HangingRecognizer()
        var strategy = RacingLanguageStrategy(
            recognizer: mock,
            inferenceDeadline: .milliseconds(300),
            retryBackoff: .milliseconds(10),
            maxAttempts: 1)

        let start = ContinuousClock.now
        let result = await strategy.recognizeBest(buffer)
        let elapsed = ContinuousClock.now - start

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, .seconds(1.5),
                          "竞速路径双轨挂起时必须按时返回（实际耗时 \(elapsed)）")
    }

    // ── 3.5 超时弃管后不重试（防卡死放大）──

    /// 超时意味着管线大概率已卡死：重试只会把无反馈等待时间翻倍。
    /// 回归项：maxAttempts=2 时超时路径仍应只调用识别器一次。
    func testTimeoutDoesNotAmplifyViaRetry() async throws {
        await resetSharedBreaker()
        defer { Task { await OCRInferenceBreaker.shared.reset() } }

        let buffer = try makeSmallBuffer()
        let mock = HangingRecognizer()
        var strategy = RacingLanguageStrategy(
            recognizer: mock,
            inferenceDeadline: .milliseconds(250),
            retryBackoff: .milliseconds(10),
            maxAttempts: 2) // 刻意允许重试 —— 验证超时路径跳过重试

        let start = ContinuousClock.now
        let result = await strategy.recognizeBest(buffer)
        let elapsed = ContinuousClock.now - start

        XCTAssertNil(result)
        XCTAssertEqual(mock.callCount, 1,
                       "超时弃管后不应重试（实际调用 \(mock.callCount) 次）")
        XCTAssertLessThan(elapsed, .seconds(1.2),
                          "超时 + 不重试应按时返回（实际耗时 \(elapsed)）")
    }

    // ── 4. ANE 预热资源 ──

    func testWarmupSyntheticBufferIsValid() throws {
        guard let buffer = ANEWarmup.makeSyntheticBuffer() else {
            return XCTFail("合成预热缓冲创建失败")
        }
        XCTAssertGreaterThan(CVPixelBufferGetWidth(buffer), 0)
        XCTAssertGreaterThan(CVPixelBufferGetHeight(buffer), 0)
        // 预热图必须非空（纯空缓冲可能被框架短路，跑不到完整网络）
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let first = base.assumingMemoryBound(to: UInt8.self)
        var nonZero = false
        for i in 0..<1024 where first[i] != 0 { nonZero = true; break }
        XCTAssertTrue(nonZero, "预热缓冲应含非零像素（噪声填充）")
    }

    /// 集成冒烟：真实 Vision 预热应最终成功。
    ///
    /// **选通运行**（`OMNITRANS_WARMUP_SMOKE=1` swift test --filter ...）：
    /// E5RT 冷启动停滞时单次真实推理可达 ~60s（真机实测，正是本修复的靶子），
    /// 不适合默认拖慢测试套件；常规回归由 mock 测试覆盖，此项用于显式验证。
    func testWarmupCompletesWithRealVision() async throws {
        guard ProcessInfo.processInfo.environment["OMNITRANS_WARMUP_SMOKE"] == "1" else {
            throw XCTSkip("真实 Vision 预热冒烟测试需设置 OMNITRANS_WARMUP_SMOKE=1")
        }
        await ANEWarmup.run(recognizer: VisionTextRecognizer(),
                            maxAttempts: 2, baseInterval: .milliseconds(100), maxInterval: .milliseconds(200))
    }
}
