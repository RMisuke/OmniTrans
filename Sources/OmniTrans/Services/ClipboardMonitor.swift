import Cocoa

/// Zero-CPU clipboard monitor — reacts to system notifications instead of polling.
/// On app-switch and pasteboard-distributed-notification events, compares changeCount
/// atomically and fires translation only when new text is detected.
///
/// When the AX accessibility path fails to capture text on hotkey, the HotkeyManager
/// can call `checkNow()` to force a single atomic changeCount comparison — no Timer needed.
@MainActor
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    private var lastChangeCount: Int = 0
    private var isRunning = false
    private var lastTranslationTime: Date = .distantPast
    /// 抑制接下来 N 次自身写入引发的变更事件（审计 M9：替换流程含写入+恢复
    /// 两次写入，单次布尔抑制会漏掉第二次）。
    var suppressCount = 0

    /// 便捷入口：抑制下一次变更。多次置 true 累加计数。
    var suppressNext: Bool {
        get { suppressCount > 0 }
        set { if newValue { suppressCount += 1 } }
    }

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastChangeCount = NSPasteboard.general.changeCount

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
        isRunning = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    var isMonitoring: Bool { isRunning }

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
        guard isRunning else { return }
        guard suppressCount == 0 else { suppressCount -= 1; lastChangeCount = NSPasteboard.general.changeCount; return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard let text = pb.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }

        let now = Date()
        guard now.timeIntervalSince(lastTranslationTime) > 2.0 else { return }
        lastTranslationTime = now

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
