import Cocoa
import os

/// Zero-CPU clipboard monitor — reacts to system notifications instead of polling.
/// On app-switch and pasteboard-distributed-notification events, compares changeCount
/// atomically and fires translation only when new text is detected.
///
/// 线程模型（P0-G3）：通知可能在任意线程投递（DistributedNotificationCenter
/// .deliverImmediately），取词策略在后台线程设置抑制 —— 全部共享状态由
/// OSAllocatedUnfairLock 保护，类本身 nonisolated；UI/翻译派发回主线程。
final class ClipboardMonitor: @unchecked Sendable {
    static let shared = ClipboardMonitor()

    private struct State {
        var lastChangeCount: Int = 0
        var isRunning = false
        var lastTranslationTime: Date = .distantPast
        /// 抑制接下来 N 次自身写入引发的变更事件（审计 M9）。
        var suppressCount = 0
    }
    private let sync = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    /// 便捷入口：抑制下一次变更。多次置 true 累加计数。
    var suppressNext: Bool {
        get { sync.withLock { $0.suppressCount > 0 } }
        set { if newValue { addSuppression(1) } }
    }

    /// 取词流程预置抑制（后台线程安全）。
    func addSuppression(_ n: Int) {
        sync.withLock { $0.suppressCount += n }
    }

    /// 取词流程结束后调用（P0-G3）：把监控基线同步到当前 changeCount
    /// （取词的写入/恢复不再被当作新划词），并回收本次取词预置但未被
    /// 通知消费的抑制计数，避免残留吞掉用户下一次复制。
    func resyncAfterCapture() {
        let count = NSPasteboard.general.changeCount
        sync.withLock { s in
            s.lastChangeCount = count
            if s.suppressCount > 0 { s.suppressCount -= 1 }
        }
    }

    func start() {
        let alreadyRunning: Bool = sync.withLock { s in
            if s.isRunning { return true }
            s.isRunning = true
            s.lastChangeCount = NSPasteboard.general.changeCount
            return false
        }
        guard !alreadyRunning else { return }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(onWorkspaceEvent),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onPasteboardChanged),
            name: NSNotification.Name("com.apple.pasteboard.changed"),
            object: nil, suspensionBehavior: .deliverImmediately
        )
    }

    func stop() {
        sync.withLock { $0.isRunning = false }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    var isMonitoring: Bool { sync.withLock { $0.isRunning } }

    /// Called externally (e.g. from HotkeyManager after AX text-capture fails)
    /// to perform a single atomic clipboard comparison without a Timer loop.
    func checkNow() {
        check()
    }

    @objc private func onWorkspaceEvent(_ notification: Notification) {
        check()
    }

    @objc private func onPasteboardChanged(_ notification: Notification) {
        check()
    }

    private func check() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        let shouldFire: Bool = sync.withLock { s in
            guard s.isRunning else { return false }
            if s.suppressCount > 0 {
                s.suppressCount -= 1
                s.lastChangeCount = current
                return false
            }
            guard current != s.lastChangeCount else { return false }
            s.lastChangeCount = current
            let now = Date()
            guard now.timeIntervalSince(s.lastTranslationTime) > 2.0 else { return false }
            s.lastTranslationTime = now
            return true
        }
        guard shouldFire else { return }

        guard let text = pb.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }

        DispatchQueue.main.async {
            let s = AppState.shared
            guard !s.isTranslating else { return }
            s.resetForNew(text: text)
            if let delegate = NSApplication.shared.delegate as? AppDelegate {
                delegate.showFloatingPanel()
            }
            s.translate()
        }
    }
}