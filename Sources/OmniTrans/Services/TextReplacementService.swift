import Cocoa

/// Handles ⌥R shortcut: replaces selected text in the frontmost app
/// with the current translation result via clipboard + simulated Cmd+V.
///
/// ## Paste Completion Detection
/// Instead of a fixed 0.5 s delay, the service polls `NSPasteboard.changeCount`
/// until it changes (indicating the target app has consumed the clipboard),
/// then restores the original content.  Falls back after 2 s to avoid hanging.
///
/// ## 并发安全
/// 该方法为 `async`：轮询期间通过 `Task.sleep` 挂起，**不阻塞主线程**。
/// （旧实现使用 `Thread.sleep` 在 `@MainActor` 上自旋，可冻结 UI 最长 2 秒。）
@MainActor
final class TextReplacementService {
    static let shared = TextReplacementService()

    private init() {}

    /// Maximum time to wait for paste completion before restoring clipboard.
    private static let pasteTimeout: TimeInterval = 2.0

    /// Polling interval when waiting for paste completion.
    private static let pollInterval: TimeInterval = 0.05
    /// Backup clipboard, write replacement, simulate paste, restore clipboard.
    func replaceSelectedText(with text: String) async {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let oldString = pasteboard.string(forType: .string)
        let oldChangeCount = pasteboard.changeCount

        // （审计 B2）抑制自身剪贴板监控：替换文本会短暂进入系统剪贴板，
        // 若 clipboard_monitor 开启，ClipboardMonitor 会把这次变更当作新的
        // 划词事件再次触发一次翻译。suppressNext 在下一次 check() 中消费。
        ClipboardMonitor.shared.suppressNext = true

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulatePaste()

        // Wait for pasteboard changeCount to advance, then restore.
        // If the target app consumes the clipboard, changeCount increments.
        // Fall back after pasteTimeout to avoid indefinite blocking.
        // 轮询用 `Task.sleep` 挂起，主线程可继续响应其它事件。
        let deadline = CACurrentMediaTime() + Self.pasteTimeout
        var restored = false
        while CACurrentMediaTime() < deadline {
            if pasteboard.changeCount != oldChangeCount {
                pasteboard.clearContents()
                if let old = oldString {
                    pasteboard.setString(old, forType: .string)
                }
                restored = true
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }

        if !restored {
            // Timeout guard: restore original clipboard anyway.
            pasteboard.clearContents()
            if let old = oldString {
                pasteboard.setString(old, forType: .string)
            }
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 0x09 // 'v'

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
