import Cocoa

/// Handles ⌥R shortcut: replaces selected text in the frontmost app
/// with the current translation result via clipboard + simulated Cmd+V.
///
/// ## Paste Completion Detection
/// 粘贴**读取**剪贴板不会改变 `changeCount`（只有写入会），因此无法用
/// changeCount 检测"目标已消费"。采用固定宽限期：写入替换文本后记录
/// `postWriteCount`，等待目标应用处理 Cmd+V，宽限期结束若无人写入则恢复
/// 备份；若期间第三方写入（用户复制了新内容）则放弃恢复，避免覆盖。
///
/// ## 并发安全
/// 该方法为 `async`：等待期间通过 `Task.sleep` 挂起，**不阻塞主线程**。
@MainActor
final class TextReplacementService {
    static let shared = TextReplacementService()

    private init() {}

    /// 目标应用处理模拟 Cmd+V 的宽限期（极慢应用可调大）。
    private static let pasteGracePeriod: TimeInterval = 0.5

    /// Backup clipboard, write replacement, simulate paste, restore clipboard.
    func replaceSelectedText(with text: String) async {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let oldString = pasteboard.string(forType: .string)

        // （审计 B2）抑制自身剪贴板监控：替换文本会短暂进入系统剪贴板，
        // 若 clipboard_monitor 开启，ClipboardMonitor 会把这次变更当作新的
        // 划词事件再次触发一次翻译。suppressNext 在下一次 check() 中消费。
        ClipboardMonitor.shared.suppressNext = true

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // 自身写入已使 changeCount 递增 —— 基线必须取写入后的值。
        let postWriteCount = pasteboard.changeCount

        simulatePaste()

        try? await Task.sleep(nanoseconds: UInt64(Self.pasteGracePeriod * 1_000_000_000))

        // 期间有第三方写入 → 不恢复（避免覆盖用户新复制的内容）。
        guard pasteboard.changeCount == postWriteCount else { return }

        ClipboardMonitor.shared.suppressNext = true
        pasteboard.clearContents()
        if let old = oldString {
            pasteboard.setString(old, forType: .string)
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