import Cocoa
import SwiftUI

// MARK: - Floating Window Manager (v1.0)

/// 管理浮动翻译工作区窗口的生命周期与关闭策略。
///
/// ## 架构
/// - 使用 `FloatingPanel.shared`（OmniPanel 子类，单例）。
/// - 读取 `UserDefaults.closeMethod` 动态配置面板关闭行为。
/// - 每次 `show()` 时注入最新 SwiftUI 内容并应用关闭策略。
/// - 钉住状态 + 高度管理 + 鼠标定位均通过 Manager 编排。
@MainActor
final class FloatingWindowManager {
    static let shared = FloatingWindowManager()

    private let panel = FloatingPanel.shared

    /// 固定模式代理。
    var isPinned: Bool {
        get { panel.isPinned }
        set { panel.isPinned = newValue }
    }

    var isVisible: Bool { panel.isVisible }
    var currentHeight: CGFloat { panel.frame.height }

    static let minHeight: CGFloat = FloatingPanel.minHeight
    static let maxHeight: CGFloat = FloatingPanel.maxHeight
    static let defaultWidth: CGFloat = FloatingPanel.defaultWidth

    private var didSetup = false

    private init() {}

    // MARK: - Show

    func show(nearMouse: Bool = true) {
        // 每次显示时应用最新关闭策略
        panel.applyCloseMethod(CloseMethod.current)

        if !didSetup {
            let state = AppState.shared
            panel.embedSwiftUI(
                FloatingPanelContent(state: state)
                    .environment(state.session)
                    .withTheme()
            )
            didSetup = true
        }

        panel.show(nearMouse: nearMouse)

        // 🔴 #1: 每次显示后重新计算高度（onAppear 仅首次触发）
        recalculateHeight()
    }

    /// 在面板显示后触发高度重新计算。
    /// 由于 `onAppear` 仅首次触发，每次 `show()` 后必须显式调用此方法
    /// 以确保面板根据已有内容调整到正确高度。
    func recalculateHeight() {
        // 将高度更新推迟到下一个 runloop，确保面板 frame 已稳定
        Task { @MainActor in
            let panelSize = UserDefaults.standard.string(forKey: "panel_size") ?? "default"
            guard panelSize == "dynamic" else {
                let h = panel.heightForMode(panelSize)
                panel.updateHeight(h, animate: true)
                return
            }
            // 动态模式下：重置 chrome 标记 → 发送高度更新信号
            // 具体高度计算由 FloatingPanelContent 的 scheduleHeightUpdate 执行
            NotificationCenter.default.post(name: .floatingPanelNeedsHeightUpdate, object: nil)
        }
    }

    // MARK: - Hide

    func hide(animated: Bool = true) {
        if animated {
            panel.hide()
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Dynamic Height

    func updateHeight(_ target: CGFloat, animated: Bool = true) {
        panel.updateHeight(target, animate: animated)
    }
}
