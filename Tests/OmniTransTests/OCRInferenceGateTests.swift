import XCTest
import os
@testable import OmniTrans

// MARK: - 推理并发闸门测试

final class OCRInferenceGateTests: XCTestCase {

    /// 许可耗尽后新请求排队等待；release 后按 FIFO 放行。
    func testAcquireBlocksUntilRelease() async throws {
        let gate = OCRInferenceGate(permits: 1, maxQueueWait: .seconds(5))
        try await gate.acquire()

        let entered = OSAllocatedUnfairLock(initialState: false)
        let worker = Task {
            try await gate.acquire()
            entered.withLock { $0 = true }
            gate.release()
        }

        // 未 release 前 worker 不得进入
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(entered.withLock { $0 }, "无空闲许可时请求应排队等待")
        XCTAssertEqual(gate.queuedCount, 1)

        gate.release()
        try await worker.value
        XCTAssertTrue(entered.withLock { $0 }, "release 后排队的请求应被放行")
    }

    /// 排队超过时限快速失败抛 `busy`，不无限等待。
    func testQueueWaitTimesOutWithBusyError() async throws {
        let gate = OCRInferenceGate(permits: 1, maxQueueWait: .milliseconds(300))
        try await gate.acquire()

        let start = ContinuousClock.now
        do {
            try await gate.acquire()
            XCTFail("许可被占用时 acquire 应抛错而非成功")
        } catch let error as InferenceGateError {
            XCTAssertEqual(error, .busy)
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .seconds(2), "排队超时应按时失败（实际 \(elapsed)）")

        gate.release() // 归还许可
        try await gate.acquire() // 归还后可立即再次获取
        gate.release()
    }

    /// 并发 acquire 不超过 permits 上限。
    func testConcurrentAcquiresRespectPermitLimit() async throws {
        let gate = OCRInferenceGate(permits: 2, maxQueueWait: .seconds(5))
        let inside = OSAllocatedUnfairLock(initialState: 0)
        let peak = OSAllocatedUnfairLock(initialState: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try? await gate.acquire()
                    let current = inside.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    let previousPeak = peak.withLock { $0 }
                    peak.withLock { $0 = max(previousPeak, current) }
                    try? await Task.sleep(for: .milliseconds(50))
                    inside.withLock { $0 -= 1 }
                    gate.release()
                }
            }
        }
        XCTAssertLessThanOrEqual(peak.withLock { $0 }, 2,
                                 "同时在闸门内的任务数不得超过 permits")
    }
}

// MARK: - 连续超时熔断器测试

final class OCRInferenceBreakerTests: XCTestCase {

    func testTripsAfterConsecutiveTimeoutsAndRecoversOnSuccess() async {
        let breaker = OCRInferenceBreaker(tripThreshold: 2, cooldown: .seconds(10))
        await breaker.reset()

        let initialAllowed = await breaker.allowAttempt()
        XCTAssertTrue(initialAllowed)
        await breaker.recordTimeout()
        let allowedAfterOne = await breaker.allowAttempt()
        XCTAssertTrue(allowedAfterOne, "未达阈值不应熔断")

        await breaker.recordTimeout()
        let allowedAfterTwo = await breaker.allowAttempt()
        XCTAssertFalse(allowedAfterTwo, "连续两次超时应触发熔断冷却")

        await breaker.recordSuccess()
        let allowedAfterSuccess = await breaker.allowAttempt()
        XCTAssertTrue(allowedAfterSuccess, "成功后应解除冷却")
    }

    func testCooldownExpiresAfterDuration() async throws {
        let breaker = OCRInferenceBreaker(tripThreshold: 1, cooldown: .milliseconds(80))
        await breaker.reset()

        await breaker.recordTimeout()
        let blockedDuringCooldown = await breaker.allowAttempt()
        XCTAssertFalse(blockedDuringCooldown)
        try await Task.sleep(for: .milliseconds(150))
        let allowedAfterCooldown = await breaker.allowAttempt()
        XCTAssertTrue(allowedAfterCooldown, "冷却期结束后应恢复放行")
    }
}
