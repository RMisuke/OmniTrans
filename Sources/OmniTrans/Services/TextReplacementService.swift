import Cocoa

/// Handles ⌥R shortcut: replaces selected text in the frontmost app
/// with the current translation result via clipboard + simulated Cmd+V.
///
/// ## Paste Completion Detection
/// Instead of a fixed 0.5 s delay, the service polls `NSPasteboard.changeCount`
/// until it changes (indicating the target app has consumed the clipboard),
/// then restores the original content.  Falls back after 2 s to avoid hanging.
@MainActor
final class TextReplacementService {
    static let shared = TextReplacementService()

    private init() {}

    /// Maximum time to wait for paste completion before restoring clipboard.
    private static let pasteTimeout: TimeInterval = 2.0

    /// Polling interval when waiting for paste completion.
    private static let pollInterval: TimeInterval = 0.05

    /// Backup clipboard, write replacement, simulate paste, restore clipboard.
    func replaceSelectedText(with text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let oldString = pasteboard.string(forType: .string)
        let oldChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulatePaste()

        // Wait for pasteboard changeCount to advance, then restore.
        // If the target app consumes the clipboard, changeCount increments.
        // Fall back after pasteTimeout to avoid indefinite blocking.
        let deadline = CACurrentMediaTime() + Self.pasteTimeout
        var restored = false
        while CACurrentMediaTime() < deadline {
            // Small blocking spin is acceptable here — this is a direct
            // response to a user hotkey action (< 2 frames at 60 fps).
            if pasteboard.changeCount != oldChangeCount {
                pasteboard.clearContents()
                if let old = oldString {
                    pasteboard.setString(old, forType: .string)
                }
                restored = true
                break
            }
            Thread.sleep(forTimeInterval: Self.pollInterval)
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
