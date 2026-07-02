import Cocoa

/// Handles ⌥R shortcut: replaces selected text in the frontmost app
/// with the current translation result via clipboard + simulated Cmd+V.
@MainActor
final class TextReplacementService {
    static let shared = TextReplacementService()

    private init() {}

    /// Backup clipboard, write replacement, simulate paste, restore clipboard.
    func replaceSelectedText(with text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let oldString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulatePaste()

        // Restore original clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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
