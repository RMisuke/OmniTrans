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
/// - `SettingsPanel`（OmniPanel 子类）保留用于菜单栏下拉场景。
@MainActor
final class WindowManager {

    // MARK: - Managers

    let floating = FloatingWindowManager.shared
    let settingsWindow = SettingsWindowManager.shared

    /// 菜单栏下拉设置面板（OmniPanel 子类，保留兼容）。
    let settingsPanel = SettingsPanel()

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

    // MARK: - Settings (菜单栏 NSPanel)

    private func refreshSettingsPanelContent() {
        settingsPanel.setContent(
            SettingsPanelContent(state: AppState.shared)
        )
    }

    func showSettingsPanel() {
        refreshSettingsPanelContent()
        positionSettingsBelowMenuBar()
        settingsPanel.show()
    }

    func hideSettingsPanel() {
        settingsPanel.orderOut(nil)
    }

    // MARK: - Positioning

    private func positionSettingsBelowMenuBar() {
        guard let screen = NSScreen.main else {
            settingsPanel.center()
            return
        }
        let pw = SettingsPanel.panelWidth
        let ph = SettingsPanel.panelHeight
        var ox = screen.frame.midX - pw / 2
        var oy = screen.frame.maxY - ph - 4
        if ox < screen.frame.minX + 8 { ox = screen.frame.minX + 8 }
        if ox + pw > screen.frame.maxX - 8 { ox = screen.frame.maxX - pw - 8 }
        if oy < screen.frame.minY + 40 { oy = screen.frame.minY + 40 }
        settingsPanel.setFrame(
            NSRect(x: ox, y: oy, width: pw, height: ph),
            display: false
        )
    }

    // MARK: - Teardown

    func dismissAll() {
        floating.hide(animated: false)
        settingsPanel.orderOut(nil)
    }
}
