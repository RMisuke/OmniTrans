import Cocoa
import SwiftUI

// MARK: - OmniPanel (v0.9 unified window base class)

/// Unified base class for all OmniTrans floating panels.
///
/// ## Material hierarchy
/// ```
/// NSWindow (borderless, non-activating)
///   └── contentView = wrapper (透明 NSView)
///         ├── layer.shadowPath → 圆角投影（masksToBounds=false）
///         └── glassBackdrop (NSVisualEffectView)
///               ├── layer.cornerRadius + masksToBounds → 圆角裁剪
///               └── NSHostingView (SwiftUI, transparent)
/// ```
///
/// ## 关键设计
/// - **wrapper**: 承载阴影，`masksToBounds=false` 允许阴影渲染
/// - **glassBackdrop**: 承载圆角裁剪与毛玻璃材质，`masksToBounds=true`
/// - 两层分离解决 CALayer 上 `masksToBounds` 同时裁剪阴影的 macOS 限制
@MainActor
class OmniPanel: NSPanel {

    // MARK: - Window chrome constants

    /// 统一圆角半径。
    static let panelCornerRadius: CGFloat = 18

    // MARK: - Views

    /// 透明包装视图 — 承载阴影，`masksToBounds=false` 确保阴影不被裁剪。
    private let wrapper = NSView()

    /// 系统毛玻璃底衬 — 承载圆角裁剪与 SwiftUI 内容。
    let glassBackdrop = NSVisualEffectView()

    /// SwiftUI 内容承载视图引用（保留以复用而非重建）。
    private var hostingView: NSHostingView<AnyView>?

    /// The material used for the window background.
    var resolvedBlurMaterial: NSVisualEffectView.Material { .hudWindow }

    // MARK: - Shared initialisation

    init(width: CGFloat, height: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureDefaults()
        configureWrapper()
        configureGlassBackdrop()
        attachDismissBehaviour()
    }

    private func configureDefaults() {
        isFloatingPanel         = true
        level                   = .floating
        collectionBehavior      = [.canJoinAllSpaces, .stationary]
        isOpaque                = false
        backgroundColor         = .clear
        hasShadow               = true   // 窗口服务器分配阴影缓冲区，CALayer 阴影才能渲染到 frame 之外
        isReleasedWhenClosed    = false
        becomesKeyOnlyIfNeeded  = false
    }

    // MARK: - Wrapper (shadow only, no clipping)

    /// 透明 NSView 作为 contentView，承载圆角阴影。
    /// `masksToBounds = false` 是关键——允许阴影渲染到图层边界之外。
    private func configureWrapper() {
        wrapper.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        wrapper.autoresizingMask = [.width, .height]
        wrapper.wantsLayer = true
        guard let wLayer = wrapper.layer else { return }
        wLayer.backgroundColor = NSColor.clear.cgColor
        wLayer.masksToBounds   = false   // ← 阴影必须不被裁剪
        wLayer.shadowColor     = NSColor.black.cgColor
        wLayer.shadowOpacity   = 0.10
        wLayer.shadowOffset    = CGSize(width: 0, height: -8)
        wLayer.shadowRadius    = 20
        wLayer.shadowPath      = CGPath(
            roundedRect: wrapper.bounds,
            cornerWidth: Self.panelCornerRadius,
            cornerHeight: Self.panelCornerRadius,
            transform: nil
        )
        self.contentView = wrapper
    }

    // MARK: - Glass backdrop (rounded corners + material)

    /// NSVisualEffectView 负责圆角裁剪与毛玻璃材质。
    /// `masksToBounds = true` 裁剪子视图到圆角，但不影响 wrapper 的阴影。
    private func configureGlassBackdrop() {
        glassBackdrop.material       = resolvedBlurMaterial
        glassBackdrop.blendingMode   = .behindWindow
        glassBackdrop.state          = .active
        glassBackdrop.frame          = wrapper.bounds
        glassBackdrop.autoresizingMask = [.width, .height]
        glassBackdrop.wantsLayer     = true

        guard let gLayer = glassBackdrop.layer else { return }
        gLayer.cornerRadius    = Self.panelCornerRadius
        gLayer.cornerCurve     = .continuous
        gLayer.masksToBounds   = true
        gLayer.borderColor     = NSColor.white.withAlphaComponent(0.12).cgColor
        gLayer.borderWidth     = 0.5

        wrapper.addSubview(glassBackdrop)

        // 窗口高度变化时同步更新 wrapper 的 shadowPath
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(wrapperFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: wrapper
        )
    }

    @objc private func wrapperFrameDidChange() {
        wrapper.layer?.shadowPath = CGPath(
            roundedRect: wrapper.bounds,
            cornerWidth: Self.panelCornerRadius,
            cornerHeight: Self.panelCornerRadius,
            transform: nil
        )
    }

    // MARK: - SwiftUI embedding

    func embedSwiftUI<Content: View>(_ view: Content) {
        if let existingHV = hostingView {
            // 复用已有 NSHostingView，仅更新 rootView — 避免视图树完全重建
            existingHV.rootView = AnyView(view)
            existingHV.layoutSubtreeIfNeeded()
            return
        }

        glassBackdrop.subviews.forEach { $0.removeFromSuperview() }

        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = glassBackdrop.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        glassBackdrop.addSubview(hosting)
        hostingView = hosting
    }

    /// 更新已嵌入的 SwiftUI 内容根视图。
    /// 如果尚未嵌入则调用 `embedSwiftUI` 创建。
    func updateSwiftUI<Content: View>(_ view: Content) {
        embedSwiftUI(view)
    }

    // MARK: - Dismiss behaviour

    private func attachDismissBehaviour() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLostFocus),
            name: NSWindow.didResignKeyNotification,
            object: self
        )
    }

    func refreshAppearance() {
        let a = NSApp.effectiveAppearance
        self.appearance = nil
        self.appearance = a
        glassBackdrop.appearance = a
    }

    @objc func handleLostFocus() {
        orderOut(nil)
    }

    // MARK: - Key / Main overrides

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func close() { orderOut(nil) }
}
