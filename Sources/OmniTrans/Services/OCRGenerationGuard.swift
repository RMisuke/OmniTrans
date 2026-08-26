import Foundation
import os

/// OCR 代际守卫 —— 单调递增代际号，用于丢弃过期的 OCR 异步回调。
///
/// 背景：OCR-A 处理中（overlay 已 dismiss、`window == nil`）用户再次触发新
/// OCR-B，`beginCapture` 会覆盖 `onComplete`。若无代际校验，OCR-A 完成时会
/// 把结果串给 B 的闭包，造成重复弹窗 / 状态错乱。每次 `beginCapture` 递增
/// 代际，回调前用 `isValid` 校验即可静默丢弃过期结果（方案 C）。
///
/// 线程安全：`OSAllocatedUnfairLock`（Swift 6 推荐锁），可从 Carbon 事件线程、
/// `MainActor`、后台 `Task` 安全调用。
final class OCRGenerationGuard: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)

    /// 递增并返回最新代际号（首次返回 1）。
    @discardableResult
    func next() -> Int {
        lock.withLock { state in
            state += 1
            return state
        }
    }

    /// 当前最新代际号。
    var current: Int {
        lock.withLock { $0 }
    }

    /// 代际是否仍为最新（过期代际返回 `false`）。
    func isValid(_ generation: Int) -> Bool {
        lock.withLock { $0 == generation }
    }
}
