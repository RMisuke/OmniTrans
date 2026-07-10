import Cocoa
import SwiftUI

// MARK: - Settings Window Manager (v2.0 — NSVisualEffectView + Dynamic Sizing)

/// 管理独立的标准 macOS 首选项窗口。
///
/// ## 架构（v2.0）
/// - **Layer 0**: `NSVisualEffectView` 作为 `contentView`，使用 `.behindWindow`
///   blending 模式提供系统级毛玻璃。状态跟随窗口激活态自动 `.active` / `.inactive`。
/// - **Layer 1**: `NSHostingView`（SwiftUI 内容）作为 `glassBackdrop` 的透明子视图。
/// - **动态尺寸**: 切换 Tab 时通过 `intrinsicContentSize` 驱动
///   `NSWindow.setFrame` 带弹性动画自适应宽度/高度。
/// - 窗口入场/退场动画通过 [`AnimationEngine`](Sources/OmniTrans/Utils/AnimationSystem.swift) 执行。
///
/// ## 生命周期
/// - Lazy-created on first invocation.
/// - Closed → `nil`; next open recreates fresh.
@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()

    private var window: NSWindow?
    private let config = WindowConfig.settings

    /// 窗口当前是否可见。
    var isVisible: Bool { window?.isVisible ?? false }

    func close() {
        window?.close()
    }

    /// 系统毛玻璃底衬。作为 `contentView`，跟随窗口激活态自动变暗。
    private var glassBackdrop: NSVisualEffectView?

    /// SwiftUI 内容承载视图。
    private var hostingView: NSHostingView<AnyView>?

    /// 焦点监听 token，用于激活态切换。
    private var keyObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Show / Focus

    func show() {
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: config.width, height: config.height),
            styleMask: config.styleMask,
            backing: .buffered,
            defer: false
        )
        config.apply(to: w)

        // ── Layer 0: NSVisualEffectView 作为 contentView ──
        let glass = config.makeGlassBackdrop()
        w.contentView = glass
        self.glassBackdrop = glass

        // ── Layer 1: SwiftUI 内容作为透明子视图 ──
        let rootView = AnyView(
            SettingsPanelContent(state: AppState.shared)
                .withTheme()
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        // ── masksToBounds 强制所有子图层在 hostingView 边界内裁剪。
        //     防止分段选择器 (Segmented Picker) 的蓝色选中滑块在
        //     动画期间溢出圆角边框或覆盖纵向分割线。
        hosting.layer?.masksToBounds = true
        // ── 像素网格对齐：强制图层按屏幕物理像素点渲染，
        //     关闭次像素抗锯齿以消除分段选择器蓝色滑块
        //     在非整数宽度下产生的 0.5px 边缘溢出毛刺。
        hosting.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        hosting.layer?.allowsEdgeAntialiasing = false
        glass.addSubview(hosting)
        // ── 将 hostingView 接入响应链，使窗口能正确识别激活状态。
        //     否则 NSVisualEffectView 的状态切换无法传递到 SwiftUI 控件，
        //     导致分段选择器 (Segmented Picker) 始终显示为 inactive 灰色。
        glass.autoresizesSubviews = true
        w.makeFirstResponder(hosting)
        self.hostingView = hosting

        // ── 窗口激活态跟踪 → 毛玻璃自动变暗 ──
        observeActivation(for: w, glass: glass)

        w.delegate = SettingsWindowDelegate.shared

        // ── 动画入场 ──
        applyEntranceAnimation(to: w)

        window = w
    }

    // MARK: - 激活态跟踪

    /// 监听窗口的 `didBecomeKey` / `didResignKey`，
    /// 将 `NSVisualEffectView.state` 在 `.active` / `.inactive` 之间切换。
    /// 失焦时毛玻璃自动暗沉，无需额外重绘——由系统合成器硬件处理。
    private func observeActivation(for window: NSWindow, glass: NSVisualEffectView) {
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in glass.state = .active }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in glass.state = .inactive }
        }
    }

    /// 驱动窗口尺寸自适应——当 SwiftUI 内容变化时，
    /// 通过 `intrinsicContentSize` 相应调整 NSWindow frame。
    func updateWindowSize(animated: Bool = true) {
        guard let w = window, let hosting = hostingView else { return }
        // 强制重新计算 intrinsic size
        hosting.invalidateIntrinsicContentSize()
        let ideal = hosting.intrinsicContentSize
        guard ideal.width > 0, ideal.height > 0 else { return }

        let newFrame = NSRect(
            x: w.frame.midX - ideal.width / 2,
            y: w.frame.midY - ideal.height / 2,
            width: max(config.width, ideal.width),
            height: max(config.height, ideal.height)
        )

        if animated, AnimationGate.isEnabled, !AnimationEngine.isReducedMotion {
            AnimationEngine.animateAppKit(AppTheme.Motion.panelOpen) {
                w.setFrame(newFrame, display: true)
            }
        } else {
            w.setFrame(newFrame, display: true)
        }
    }

    // MARK: - 入场动画

    private func applyEntranceAnimation(to window: NSWindow) {
        guard AnimationGate.isEnabled, !AnimationEngine.isReducedMotion else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.alphaValue = 1
            return
        }

        window.setFrame(
            NSRect(x: window.frame.midX - window.frame.width * 0.46,
                   y: window.frame.midY - window.frame.height * 0.46,
                   width: window.frame.width * 0.92,
                   height: window.frame.height * 0.92),
            display: false
        )
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let original = NSRect(
            x: window.frame.midX - window.frame.width / 0.92 * 0.5,
            y: window.frame.midY - window.frame.height / 0.92 * 0.5,
            width: window.frame.width / 0.92,
            height: window.frame.height / 0.92
        )

        AnimationEngine.animateAppKit(AppTheme.Motion.panelOpen) {
            window.setFrame(original, display: true)
            window.alphaValue = 1
        }
    }

    // MARK: - Close

    fileprivate func didClose() {
        // 清理焦点监听
        if let o = keyObserver { NotificationCenter.default.removeObserver(o) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        keyObserver = nil
        resignObserver = nil

        guard let w = window else { return }

        if AnimationGate.isEnabled, !AnimationEngine.isReducedMotion {
            let shrunken = NSRect(
                x: w.frame.midX - w.frame.width * 0.48,
                y: w.frame.midY - w.frame.height * 0.48,
                width: w.frame.width * 0.96,
                height: w.frame.height * 0.96
            )
            AnimationEngine.animateAppKit(AppTheme.Motion.panelClose) {
                w.setFrame(shrunken, display: true)
                w.alphaValue = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                self?.window = nil
            }
        } else {
            window = nil
        }
    }
}

// MARK: - Window Delegate

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate, @unchecked Sendable {
    static let shared = SettingsWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            SettingsWindowManager.shared.didClose()
        }
    }
}
