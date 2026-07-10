import Cocoa
import SwiftUI

// MARK: - Settings Panel (v0.9 → v1.0)

/// Menu-bar settings panel — inherits shared lifecycle from ``OmniPanel``.
///
/// Unlike the FloatingPanel, this panel:
/// - Has a fixed size (460 × 540)
/// - Positions below the menu bar
/// - Uses `.sidebar` material (standard macOS settings appearance)
/// - Does not support pinning or drag
/// - **v1.0**: Added animation-aware show/hide via `AnimationEngine`
@MainActor
final class SettingsPanel: OmniPanel {

    // MARK: - Dimensions

    static let panelWidth: CGFloat = 460
    static let panelHeight: CGFloat = 540

    // MARK: - Init

    init() {
        super.init(width: Self.panelWidth, height: Self.panelHeight)
        isMovableByWindowBackground = false
        // Enable async drawing for animation performance
        isOpaque = false
        backgroundColor = .clear
    }

    /// Settings panels use `.sidebar` material — the standard macOS settings look.
    override var resolvedBlurMaterial: NSVisualEffectView.Material { .sidebar }

    // MARK: - Content

    /// Replace or set the SwiftUI content inside the glass backdrop.
    func setContent<Content: View>(_ view: Content) {
        embedSwiftUI(view)
    }

    // MARK: - Show

    /// Show the panel with optional entrance animation via `AnimationEngine`.
    ///
    /// **Safety**: `alphaValue` is always at least 1 after this call.  The
    /// animation path sets it to 0 first, then animates to 1; on the
    /// reduced-motion / disabled path it stays at the default 1.
    func show() {
        makeKeyAndOrderFront(nil)
        invalidateShadow()

        guard AnimationGate.isEnabled, !AnimationEngine.isReducedMotion else {
            alphaValue = 1  // ensure visible on reduced-motion path
            return
        }

        alphaValue = 0
        AnimationEngine.animateAppKit(AppTheme.Motion.panelOpen) {
            self.alphaValue = 1
        }
    }

    /// Hide the panel with optional exit animation.
    func hide(animated: Bool = true) {
        guard animated, AnimationGate.isEnabled, !AnimationEngine.isReducedMotion else {
            orderOut(nil)
            return
        }
        AnimationEngine.animateAppKit(AppTheme.Motion.panelClose) {
            self.alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.orderOut(nil)
        }
    }
}
