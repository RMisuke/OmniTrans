import Cocoa
import SwiftUI

// MARK: - Window Manager (v1.0)

/// 全局窗口生命周期协调器。
///
/// AppDelegate 通过此 Manager 调用高层语义（show/hide/dismiss），
/// 不再直接操作具体的 NSPanel / NSWindow 实例。
///
/// ## v1.0 变更
/// - 浮动面板由 [`FloatingWindowManager`](Sources/OmniTrans/Services/FloatingWindowManager.swift) 管理，
///   不再使用 `FloatingPanel.shared`（OmniPanel 子类）。
/// - 首选项窗口由 [`SettingsWindowManager`](Sources/OmniTrans/Services/SettingsWindowManager.swift) 管理。
/// ## v0.8 收敛
/// - 删除 `SettingsPanel`（菜单栏下拉面板）死代码路径 ——
///   窗口层收敛为两条路径：浮动面板 + 独立首选项窗口。
@MainActor
final class WindowManager {

    // MARK: - Managers

    let floating = FloatingWindowManager.shared
    let settingsWindow = SettingsWindowManager.shared

    // MARK: - Floating Panel

    func showFloating(nearMouse: Bool = true) {
        floating.show(nearMouse: nearMouse)
    }

    func hideFloating() {
        floating.hide()
    }

    // MARK: - Settings (独立 NSWindow)

    func showSettings() {
        settingsWindow.show()
    }

    func hideSettings() {
        // SettingsWindowManager's window closes via delegate
    }

    func toggleSettings() {
        if settingsWindow.isVisible {
            settingsWindow.close()
        } else {
            settingsWindow.show()
        }
    }

    // MARK: - Teardown

    func dismissAll() {
        floating.hide(animated: false)
    }
}
