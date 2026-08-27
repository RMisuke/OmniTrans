import Foundation

// MARK: - OCR 并发工具

/// 一次性闸门：`tryEnter()` 全生命周期仅第一次返回 true。
/// 用于「超时方 vs 完成方」竞速场景保证 continuation / 清理动作恰好执行一次。
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false

    /// 首次调用返回 true，其后全部返回 false。
    func tryEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if entered { return false }
        entered = true
        return true
    }
}

/// 推理超时错误 —— `withInferenceDeadline` 到点未等到结果时返回。
enum InferenceDeadlineError: Error {
    case exceeded
}

/// 带**真实超时**的推理执行器。
///
/// ## 为什么不用 `withTaskGroup` + 超时子任务（旧实现）
/// 结构化并发要求 `withTaskGroup` 返回前**等待全部子任务结束**。
/// E5RT 冷启动停滞中的 Vision 调用不响应 `Task.cancel()`，
/// 超时子任务到点后整个 group 仍被挂起子任务卡住 —— 兜底形同虚设
/// （真机日志实测停滞 ~40s，用户侧表现为「解析中」永久转圈）。
///
/// ## 本实现的弃管语义
/// 识别操作跑在**非结构化** `Task` 中，超时到点立即向调用方返回
/// `.failure(InferenceDeadlineError.exceeded)`，挂起的操作被弃管
/// （best-effort 取消，待 E5RT 自行落错后自然结束，其结果被丢弃）。
/// 代价是短暂的后台任务滞留，换取调用方**确定性的响应时限**。
///
/// - Parameters:
///   - deadline: 最长等待时间。
///   - operation: 可抛错的异步操作（在后台任务中执行）。
/// - Returns: 成功 / 原始错误 / 超时（`.failure(InferenceDeadlineError.exceeded)`）。
func withInferenceDeadline<T: Sendable>(
    _ deadline: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async -> Result<T, Error> {
    let opTask = Task.detached(priority: .userInitiated) { try await operation() }

    // 外部取消（如新一轮 OCR 接管）→ best-effort 取消被弃管的操作。
    // Vision 停滞期取消可能无效，但正常路径可立即终止推理、释放算力。
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>, Never>) in
            let gate = OnceGate()

            // 超时方：到点抢闸返回，并 best-effort 取消被弃管的操作
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: deadline)
                if gate.tryEnter() {
                    opTask.cancel()
                    continuation.resume(returning: .failure(InferenceDeadlineError.exceeded))
                }
            }

            // 完成方：操作落定后抢闸返回；若超时方/外部取消方已抢先，结果静默丢弃
            Task.detached(priority: .userInitiated) {
                let result: Result<T, Error>
                do {
                    result = .success(try await opTask.value)
                } catch is CancellationError {
                    result = .failure(CancellationError())
                } catch {
                    result = .failure(error)
                }
                if gate.tryEnter() {
                    continuation.resume(returning: result)
                }
            }
        }
    } onCancel: {
        opTask.cancel()
    }
}
