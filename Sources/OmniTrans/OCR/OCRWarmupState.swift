import Foundation
import Observation

// MARK: - OCR 预热进度状态（SSOT）

/// 进程启动后 ANE 冷启动预热的**共享进度状态**。
/// UI 层（悬浮窗进度条）和快捷键回调都从此单一数据源读取预热状态。
///
/// ## 生命周期
/// - 进程启动时 `isWarmingUp = true`，`progress = 0`
/// - 每次预热尝试后由 `ANEWarmup.run()` 调用 `updateProgress(attempt:)`
/// - 预热成功后调用 `markComplete()`，发送 `OCRWarmupComplete` 通知
/// - 进程退出前状态保持不变（单例生命周期 = 进程生命周期）
@MainActor
@Observable
final class OCRWarmupState {
    static let shared = OCRWarmupState()

    /// 当前是否正在预热。启动即为 `true`，`markComplete()` 后变为 `false`。
    var isWarmingUp: Bool = true

    /// 预热是否以失败告终（达到最大尝试次数仍未成功）。
    var warmupFailed: Bool = false

    /// 预热进度 0.0 → 1.0。
    var progress: Double = 0.0

    /// 当前已完成的尝试次数。
    var currentAttempt: Int = 0

    /// 最大尝试次数（与 `ANEWarmup` 默认值一致）。
    let maxAttempts: Int = 15

    private init() {}

    /// 更新预热进度。每次预热尝试后由 `ANEWarmup.run()` 调用。
    /// - Parameter attempt: 当前尝试次数（0-based，progress = attempt / maxAttempts）。
    func updateProgress(attempt: Int) {
        currentAttempt = attempt
        progress = min(Double(attempt) / Double(maxAttempts), 1.0)
    }

    /// 标记预热成功完成。
    func markComplete() {
        isWarmingUp = false
        warmupFailed = false
        progress = 1.0
        currentAttempt = maxAttempts
        NotificationCenter.default.post(name: .ocrWarmupComplete, object: nil)
    }

    /// 标记预热失败（达到最大尝试次数仍未就绪）。
    /// 用户可通过 OCR 快捷键触发 `retryWarmup()` 重试。
    func markFailed() {
        isWarmingUp = false
        warmupFailed = true
        // progress 保持最后一次尝试的进度，不设为 1.0
        NotificationCenter.default.post(name: .ocrWarmupFailed, object: nil)
    }

    /// 手动重置并触发新一轮预热（用户通过 OCR 快捷键调用）。
    func retryWarmup() {
        guard !isWarmingUp else { return } // 正在预热中，不重复触发
        isWarmingUp = true
        warmupFailed = false
        progress = 0.0
        currentAttempt = 0
        Task.detached(priority: .utility) {
            await OCRCapturePipeline.warmUpANE()
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    /// OCR ANE 预热完成通知。由 `OCRWarmupState.markComplete()` 发送。
    static let ocrWarmupComplete = Notification.Name("OCRWarmupComplete")
    /// OCR ANE 预热失败通知。由 `OCRWarmupState.markFailed()` 发送。
    static let ocrWarmupFailed = Notification.Name("OCRWarmupFailed")
}
