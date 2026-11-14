@preconcurrency import Cocoa
import SwiftUI
@preconcurrency import Dispatch

// MARK: - Close Method

/// 浮动面板关闭策略。
enum CloseMethod: String, CaseIterable, Sendable {
    case clickOutside = "clickOutside"
    case manualEsc    = "manualEsc"

    var displayName: String {
        switch self {
        case .clickOutside: "点击框外"
        case .manualEsc:    "手动关闭"
        }
    }

    /// 从 UserDefaults 读取，默认 `.clickOutside`。
    /// 键名与设置 UI 的 `@AppStorage("dismiss_mode")` 统一（审计 H7：
    /// 旧实现读 "closeMethod" 且取值 "manualEsc" 与 UI 写入的 "manual" 双错配）。
    static var current: CloseMethod {
        switch UserDefaults.standard.string(forKey: "dismiss_mode") {
        case "manual", "manualEsc": return .manualEsc
        default: return .clickOutside
        }
    }
}

extension Notification.Name {
    static let floatingPanelDidShow = Notification.Name("FloatingPanelDidShow")
    static let floatingPanelNeedsHeightUpdate = Notification.Name("FloatingPanelNeedsHeightUpdate")
}

// MARK: - Floating Translation Panel (v1.0)

/// 浮动翻译工作区窗口（OmniPanel 子类，单例）。
///
/// ## v1.0 新增
/// - `CloseMethod` 双模式：点击框外关闭 / Esc 手动关闭。
/// - `keyDown` 拦截 Esc（keyCode 53）。
/// - `windowDidResignKey` 延迟双重确认关闭。
/// - 钉住 (`isPinned`) 在所有关闭路径中优先判断。
@MainActor
final class FloatingPanel: OmniPanel, NSWindowDelegate {
    static let shared = FloatingPanel()

    static let defaultWidth: CGFloat = 420
    static let minHeight: CGFloat = 280
    static let maxHeight: CGFloat = 800

    /// 动态模式下的高度边界（与 `FloatingPanelContent` 共享）。
    static let dynamicMinHeight: CGFloat = 480
    static let dynamicMaxHeight: CGFloat = 800

    /// 关闭策略，从 UserDefaults 动态读取。
    var closeMethod: CloseMethod = .clickOutside

    /// 钉住模式：悬浮于所有窗口之上，忽略任何关闭触发。
    var isPinned = false {
        didSet { level = isPinned ? .screenSaver : .floating }
    }

    /// 未执行的延迟关闭任务（用于取消）。
    private var pendingCloseTask: Task<Void, Never>?

    /// hide/show 代际：hide 动画完成回调校验代际，快速重显后旧回调不再 orderOut（审计 M8）。
    private var hideGeneration: Int = 0

    private var resignKeyObserver: NSObjectProtocol?

    private init() {
        super.init(width: Self.defaultWidth, height: 380)
        isMovableByWindowBackground = true
        delegate = self

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillMove),
            name: NSWindow.willMoveNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMove),
            name: NSWindow.didMoveNotification, object: self
        )
    }

    @objc private func windowWillMove() { AppState.isUserDraggingWindow = true }
    @objc private func windowDidMove()   { AppState.isUserDraggingWindow = false }

    deinit {
        pendingCloseTask?.cancel()
        // resignKeyObserver 是 non-Sendable 类型，不能从 nonisolated deinit 直接访问，
        // 使用 String-based 移除绕过类型系统限制。
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: self)
    }

    // MARK: - Close (pin gate)

    /// Overrides parent's `handleLostFocus` — the parent unconditionally
    /// calls `orderOut(nil)` on `didResignKeyNotification`, which ignores
    /// pin state and close method. Route to the policy-aware path so
    /// manualEsc / pinned / 0.1s debounce are all respected (审计 H7).
    @objc override func handleLostFocus() {
        windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: self))
    }

    override func close() {
        guard !isPinned else { return }
        hide()
    }

    /// 应用当前关闭策略配置。
    func applyCloseMethod(_ method: CloseMethod) {
        closeMethod = method
        switch method {
        case .clickOutside:
            observeResignKey()
        case .manualEsc:
            removeResignKeyObserver()
        }
    }

    // MARK: - Esc Key (manualEsc)

    override func keyDown(with event: NSEvent) {
        if closeMethod == .manualEsc, event.keyCode == 53, isKeyWindow {
            close()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Click Outside (clickOutside)

    /// 窗口失去焦点时触发。0.1s 延迟后双重确认再关闭，
    /// 避免系统弹出上下文菜单或辅助面板导致的误关。
    func windowDidResignKey(_ notification: Notification) {
        guard closeMethod == .clickOutside, !isPinned else { return }
        cancelPendingClose()

        pendingCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
            guard let self, !Task.isCancelled,
                  self.closeMethod == .clickOutside, !self.isPinned,
                  !self.isKeyWindow, !NSApp.isActive else { return }
            self.close()
        }
    }

    private func observeResignKey() {
        guard resignKeyObserver == nil else { return }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: self, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: self))
            }
        }
    }

    private func removeResignKeyObserver() {
        if let o = resignKeyObserver { NotificationCenter.default.removeObserver(o) }
        resignKeyObserver = nil
        cancelPendingClose()
    }

    private func cancelPendingClose() {
        pendingCloseTask?.cancel()
        pendingCloseTask = nil
    }

    // MARK: - Sizing

    func heightForMode(_ mode: String) -> CGFloat {
        switch mode {
        case "small":   return 320
        case "large":   return 620
        case "dynamic": return Self.dynamicMinHeight
        default:        return 460
        }
    }

    // MARK: - Show

    func show(nearMouse: Bool = true) {
        // 递增代际使任何进行中的 hide 完成回调失效（审计 M8）
        hideGeneration += 1
        let h = heightForMode(UserDefaults.standard.string(forKey: "panel_size") ?? "default")
        let w = Self.defaultWidth

        // Use the screen where the mouse currently is (multi-display support)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main

        if nearMouse, let screen {
            var o = NSPoint(x: mouse.x + 8, y: mouse.y - h - 8)
            let v = screen.visibleFrame
            if o.x + w > v.maxX { o.x = v.maxX - w - 8 }
            if o.y < v.minY   { o.y = mouse.y + 24 }
            if o.x < v.minX   { o.x = v.minX + 8 }
            setFrame(NSRect(x: o.x, y: o.y, width: w, height: h), display: false)
        } else {
            setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: w, height: h), display: false)
        }

        alphaValue = 1.0
        makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .floatingPanelDidShow, object: nil)
    }

    // MARK: - Hide

    func hide() {
        cancelPendingClose()
        hideGeneration += 1
        let generation = hideGeneration
        Task { await TTSManager.shared.stop() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AppTheme.Motion.panelHide.appKitDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // 动画期间若已重新 show（代际递增），放弃 orderOut（审计 M8）
                guard self.hideGeneration == generation else { return }
                self.orderOut(nil)
                // 刻意不做内存清理：面板隐藏是高频路径，malloc_zone_pressure_relief
                // 会把 Vision 内部缓冲反复「清零」，下次 OCR 重新冷建（连续识别卡死主因之一）。
                // 清理职责收归 MemoryPurgeHelper 的系统内存压力事件。
            }
        }
    }

    // MARK: - Dynamic Height

    /// 动态更新窗口高度。
    ///
    /// - 保持窗口底部锚定（向上扩展 / 向下收缩）。
    /// - 动画块内同步更新 `shadowPath`，避免阴影与框体不同步。
    /// - 用户拖拽窗口时跳过，避免交互冲突。
    func updateHeight(_ targetHeight: CGFloat, animate: Bool = true) {
        guard !AppState.isUserDraggingWindow else { return }

        let clamped = max(Self.minHeight, min(Self.maxHeight, targetHeight))
        let w = Self.defaultWidth
        var newFrame = frame
        newFrame.origin.y += newFrame.size.height - clamped
        newFrame.size = NSSize(width: w, height: clamped)

        guard newFrame.size != frame.size else { return }

        if animate {
            let newPath = CGPath(
                roundedRect: CGRect(origin: .zero, size: newFrame.size),
                cornerWidth: Self.panelCornerRadius,
                cornerHeight: Self.panelCornerRadius,
                transform: nil
            )
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = AppTheme.Motion.panelResize.appKitDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                animator().setFrame(newFrame, display: true)
                // 同步动画 shadowPath，避免阴影瞬间跳变
                contentView?.layer?.shadowPath = newPath
            } completionHandler: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.contentView?.layoutSubtreeIfNeeded()
                }
            }
        } else {
            setFrame(newFrame, display: true)
        }
    }
}
