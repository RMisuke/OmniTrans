import SwiftUI
import AppKit

// MARK: - Adaptive Glass Background (macOS 26 Native)

/// High-opacity adaptive background using `.ultraThickMaterial` on
/// macOS 26+ for the premium "Thick Bottom" content canvas, and
/// `.sidebar` + `.behindWindow` on macOS 14+ for Mica fallback.
///
/// ## Material Strategy (DESIGN-apple.md — thick materials)
/// - **macOS 26+**: `.ultraThickMaterial` — heavy blur with high
///   opacity, no light-bleed, solid enough that background content
///   never bleeds through text.
/// - **macOS 14+**: `.sidebar` — deep frosted Mica with identical
///   GPU-compositor performance.
///
/// ## No Low-Opacity Web-Tiles
/// The old `Color.primary.opacity(0.03)` mist layer and specular
/// gradient borders have been removed.  The native material alone
/// provides sufficient premium feel without visual noise.
struct AdaptiveGlassBackground: NSViewRepresentable {

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = resolvedMaterial()
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        view.layer?.cornerRadius = 0
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
