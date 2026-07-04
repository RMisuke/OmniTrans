import SwiftUI

// MARK: - Animation Gate (Cached Preference + Declarative Gating)

/// 动画门控系统：基于 UserDefaults 的静态缓存，消除每帧磁盘 I/O。
///
/// ## 架构
/// - `_enabled` 为静态惰性缓存，仅在 App 启动与用户切换设置时刷新。
/// - `.gated` 属性提供声明式链式门控：动效关闭时自动返回 `nil`，
///   SwiftUI 将回退为 0 耗时硬切状态，无需手写 `if-else` 分支。
/// - `.animationsGated()` 作为容器级兜底，强制移除事务中所有隐式/显式动画。
///
/// ## 使用示例
/// ```swift
/// // 声明式链式门控（推荐）
/// withAnimation(AppTheme.Motion.fluid.gated) { swapTrigger.toggle() }
///
/// // View 级别门控
/// SomeView().animationsGated()
///
/// // 直接查询（用于 computed property 场景）
/// private var pageAnim: Animation? { AppTheme.Motion.slow.gated }
/// ```
enum AnimationGate {
    /// 静态缓存，避免每一帧引发 UserDefaults 磁盘 I/O 开销。
    /// UserDefaults 读取本身是线程安全的，因此此缓存故意不加 `@MainActor`。
    private static var _enabled: Bool = {
        UserDefaults.standard.bool(forKey: "animations_enabled")
    }()

    /// 当前动画开关状态。`true` 表示允许动画播放。
    static var isEnabled: Bool {
        _enabled
    }

    /// 刷新缓存。应在 App 启动时及用户切换「动画效果」设置后调用。
    static func refresh() {
        _enabled = UserDefaults.standard.bool(forKey: "animations_enabled")
    }
}

// MARK: - 声明式链式门控扩展

extension Animation {
    /// 零侵入式门控属性。
    ///
    /// 当 ``AnimationGate/isEnabled`` 为 `true` 时返回 `self`，
    /// 否则返回 `nil`。SwiftUI 在接收 `nil` 动画时会自动回退为瞬时硬切，
    /// 无需在视图层手写 `if-else` 分支。
    ///
    /// ```swift
    /// // 旧写法
    /// .animation(AnimationGate.isEnabled ? .easeInOut(duration: 0.25) : nil, value: page)
    ///
    /// // 新写法
    /// .animation(AppTheme.Motion.slow.gated, value: page)
    /// ```
    var gated: Animation? {
        AnimationGate.isEnabled ? self : nil
    }
}

// MARK: - View 级别容器门控

extension View {
    /// 容器事务级剥离：强制移除当前视图下辖的所有显式与隐式动画事务。
    ///
    /// 当 ``AnimationGate/isEnabled`` 为 `false` 时，将 `.disablesAnimations`
    /// 设为 `true` 并将 `.animation` 置为 `nil`，确保子视图树中无任何动画残留。
    ///
    /// 适用于顶层容器（如 `ContentView`、`SettingsView`）作为兜底保障。
    func animationsGated() -> some View {
        self.transaction { t in
            if !AnimationGate.isEnabled {
                t.disablesAnimations = true
                t.animation = nil
            }
        }
    }
}

