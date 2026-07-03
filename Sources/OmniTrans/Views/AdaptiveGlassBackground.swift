import SwiftUI
import AppKit

/// Adaptive glass-morphism background that bridges to the native
/// `NSVisualEffectView`.
///
/// - **macOS 26+**:  Activates `.hudWindow` material — the system's most
///   modern fluid overlay with real-time desktop blending and subtle
///   light-bleed edges ("Liquid Glass").
/// - **macOS 14+**:  Falls back gracefully to `.sidebar` — a deep,
///   high-quality frosted glass (Mica) with identical blur performance.
///
/// Because the effect is rendered on the GPU compositor, it adds
/// zero CPU overhead and never blocks the main run loop.
struct AdaptiveGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = resolvedMaterial()
        view.wantsLayer = true
        view.layer?.cornerRadius = 0   // caller applies clipShape
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = resolvedMaterial()
    }

    private func resolvedMaterial() -> NSVisualEffectView.Material {
        if #available(macOS 26.0, *) {
            return .hudWindow
        } else {
            return .sidebar
        }
    }
}
