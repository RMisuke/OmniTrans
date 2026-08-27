import Foundation
import os

// MARK: - 推理并发闸门

/// 闸门拒绝错误。
enum InferenceGateError: Error, Equatable {
    /// 排队等待超时 —— 上一次识别仍在进行且超过最大排队时长。
    case busy
}

/// 全局推理并发闸门 —— 同一时刻最多允许 `permits` 个 Vision 推理真正执行。
///
/// ## 为什么需要
/// `withInferenceDeadline` 的弃管语义意味着停滞的 Vision 调用不响应取消，
/// 连续 OCR 时弃管任务不断堆积、占满全局协作执行器队列，新识别的推理任务
/// 排不上队 —— 用户侧表现为「一直在识别中」。闸门把并发变成显式队列：
/// 超过排队时限的请求立即失败，让 UI 能即时给出「引擎繁忙」反馈，
/// 同时把同时压向 ANE 的推理数收敛到常数，避免多请求互踩加剧停滞。
///
/// ## 释放时机（关键设计）
/// 许可在 `withInferenceDeadline` **到点返回时**释放，而非等底层操作自然落错 ——
/// 停滞调用实测可挂 ~40s 才落错，等它会让一次停滞锁死全部后续识别。
/// 弃管操作对 ANE 的残留争抢由 `OCRInferenceBreaker` 的冷却期兜底。
final class OCRInferenceGate: Sendable {

    static let shared = OCRInferenceGate()

    private struct State {
        var permits: Int
        var queue: [(id: UUID, cont: CheckedContinuation<Void, Error>)] = []
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let maxQueueWait: Duration

    init(permits: Int = 2, maxQueueWait: Duration = .seconds(2)) {
        self.lock = OSAllocatedUnfairLock(initialState: State(permits: max(1, permits)))
        self.maxQueueWait = maxQueueWait
    }

    /// 当前排队等待的请求数（诊断用）。
    var queuedCount: Int { lock.withLock { $0.queue.count } }

    /// 获取一个许可；无空闲许可时排队，超过 `maxQueueWait` 或任务被取消则抛错。
    func acquire() async throws {
        // 快路径：有空闲许可直接拿走
        let immediate = lock.withLock { st -> Bool in
            if st.permits > 0 { st.permits -= 1; return true }
            return false
        }
        if immediate { return }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<Void, Error>) in
                let grantedNow = lock.withLock { st -> Bool in
                    if st.permits > 0 { st.permits -= 1; return true }
                    st.queue.append((id, cont))
                    return false
                }
                if grantedNow {
                    cont.resume(returning: ())
                    return
                }
                // 排队超时观察者：到点后尝试摘除自己并抛 busy；
                // 若已被 release 放行/被取消方摘除，removeWaiter 返回 nil，天然幂等。
                let wait = maxQueueWait
                Task.detached(priority: .utility) {
                    try? await Task.sleep(for: wait)
                    if let c = self.removeWaiter(id) {
                        c.resume(throwing: InferenceGateError.busy)
                    }
                }
            }
        } onCancel: {
            self.removeWaiter(id)?.resume(throwing: CancellationError())
        }
    }

    /// 归还许可。若有排队者则直接移交（净许可数不变），否则归还池子。
    func release() {
        let next: CheckedContinuation<Void, Error>? = lock.withLock { st in
            if !st.queue.isEmpty {
                return st.queue.removeFirst().cont
            }
            st.permits += 1
            return nil
        }
        next?.resume(returning: ())
    }

    /// 从队列摘除指定等待者；恰好一方（放行 / 超时 / 取消）能摘到，保证恰好 resume 一次。
    private func removeWaiter(_ id: UUID) -> CheckedContinuation<Void, Error>? {
        lock.withLock { st -> CheckedContinuation<Void, Error>? in
            guard let i = st.queue.firstIndex(where: { $0.id == id }) else { return nil }
            return st.queue.remove(at: i).cont
        }
    }
}

// MARK: - 连续超时熔断

/// 连续超时熔断器 —— 连续多次推理**超时**后进入冷却期，停止继续撞已卡死的管线。
///
/// 只统计 `InferenceDeadlineError`（真实超时弃管）；瞬态快速失败（E5RT Code 13）
/// 和闸门拒绝（busy）不计数 —— 前者重试即可恢复，后者不应因用户连续触发而误熔断。
actor OCRInferenceBreaker {
    static let shared = OCRInferenceBreaker()

    private let tripThreshold: Int
    private let cooldown: Duration

    private var consecutiveTimeouts = 0
    private var cooldownUntil: ContinuousClock.Instant?

    init(tripThreshold: Int = 2, cooldown: Duration = .seconds(10)) {
        self.tripThreshold = tripThreshold
        self.cooldown = cooldown
    }

    /// 当前是否允许发起新的推理尝试（冷却期内返回 false）。
    func allowAttempt() -> Bool {
        if let until = cooldownUntil {
            return ContinuousClock.now >= until
        }
        return true
    }

    /// 记录一次推理超时；连续达到阈值即进入冷却期。
    func recordTimeout() {
        consecutiveTimeouts += 1
        if consecutiveTimeouts >= tripThreshold {
            cooldownUntil = ContinuousClock.now + cooldown
            consecutiveTimeouts = 0 // 冷却结束后重新计数
        }
    }

    /// 记录一次成功 —— 清零计数并解除冷却。
    func recordSuccess() {
        consecutiveTimeouts = 0
        cooldownUntil = nil
    }

    /// 测试辅助：清空状态。
    func reset() {
        consecutiveTimeouts = 0
        cooldownUntil = nil
    }
}
