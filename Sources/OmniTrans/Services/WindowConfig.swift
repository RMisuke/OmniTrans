import Cocoa
import SwiftUI

// MARK: - Window Configuration v2.0

/// 可复用的窗口配置结构，封装 NSWindow 样式、尺寸、毛玻璃工厂。
///
/// ## v2.0 变更
/// - 新增 `makeGlassBackdrop()`：创建 `NSVisualEffectView` 替代 SwiftUI Material，
///   使用 `.behindWindow` blending + `.active` 状态，跟随窗口焦点自动变暗。
/// - `makeHostingView` 保留，用于不需要 NSVisualEffectView 的窗口（如 Onboarding）。
struct WindowConfig: Sendable {
    let width: CGFloat
    let height: CGFloat
    let styleMask: NSWindow.StyleMask
    let title: String
    let cornerRadius: CGFloat

    // MARK: - 预设

    /// 标准首选项窗口配置。
    static let settings = WindowConfig(
        width: 460, height: 540,
        styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
        title: "OmniTrans 首选项",
        cornerRadius: 20
    )

    // MARK: - NSWindow 配置

    @MainActor
    func apply(to window: NSWindow) {
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
    }

    // MARK: - Layer 0: NSVisualEffectView 毛玻璃底衬

    /// 创建系统级毛玻璃底衬视图。
    ///
    /// - `.behindWindow`: 采样窗口后方桌面/应用内容。
    /// - `.active`: 初始激活态——窗口 `didBecomeKey` 后由 Manager 切换。
    /// - 圆角通过 `maskImage` 实现，确保玻璃材质也被裁剪。
    @MainActor
    func makeGlassBackdrop() -> NSVisualEffectView {
        let glass = NSVisualEffectView()
        glass.frame = NSRect(x: 0, y: 0, width: width, height: height)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = cornerRadius
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        return glass
    }

    // MARK: - Layer 1: NSHostingView

    /// 创建 SwiftUI 内容承载视图。
    /// 圆角裁剪由 glassBackdrop (NSVisualEffectView) 统一负责，
    /// 此层仅需透明背景。
    @MainActor
    func makeHostingView<Content: View>(rootView: Content) -> NSHostingView<Content> {
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        return hosting
    }
}
