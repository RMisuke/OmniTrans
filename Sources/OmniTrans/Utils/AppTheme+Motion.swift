import SwiftUI

// MARK: - OmniTrans Semantic Motion Design System

extension AppTheme {
    /// 语义化动效系统中心 —— 消除视图层硬编码动画参数。
    ///
    /// ## 设计原则
    /// - **语义命名**：每个 token 描述「在什么场景下使用」而非曲线参数。
    /// - **零分配开销**：全部为 `static let` 常量，无实例化成本。
    /// - **与 ``AnimationGate`` 协同**：配合 `.gated` 属性实现声明式优雅降级。
    ///
    /// ## 使用示例
    /// ```swift
    /// // 声明式链式门控
    /// withAnimation(AppTheme.Motion.fluid.gated) { ... }
    /// .animation(AppTheme.Motion.slow.gated, value: someState)
    /// ```
    enum Motion {

        // MARK: - 瞬态微交互

        /// **snip** — 瞬时反馈曲线，用于悬浮、按压、微调等高频交互。
        ///
        /// 持续时间短 (0.2 s)、反弹小 (0.1)，确保操作手感干脆不拖沓。
        ///
        /// **适用场景**：按钮 hover 态切换、tag 选中态、toggle 微动效。
        static let snip = Animation.spring(duration: 0.2, bounce: 0.1)

        // MARK: - 容器过渡

        /// **fluid** — 标准流体曲线，用于卡片入场、标签页切换等核心容器过渡。
        ///
        /// 持续时间适中 (0.3 s)、反弹柔和 (0.15)，在流畅感与性能之间取得平衡。
        ///
        /// **适用场景**：标签页切换、词典卡片入场、设置面板展开/收起。
        static let fluid = Animation.spring(duration: 0.3, bounce: 0.15)

        // MARK: - 状态演进

        /// **slow** — 柔和演进曲线，用于状态指示灯、Toast 提示的隐显。
        ///
        /// 使用标准 ease-in-out 曲线，0.45 s 持续时间确保状态变化可感知但不突兀。
        ///
        /// **适用场景**：翻译状态灯、成功/错误脉冲、Toast 淡入淡出。
        static let slow = Animation.easeInOut(duration: 0.45)

        // MARK: - 循环脉冲

        /// **breathe** — 异步循环呼吸，仅供无状态叶子节点脉冲使用（零布局依赖）。
        ///
        /// 1.4 s 周期、自动往复，不使用 gradient mask 或 motion blur，
        /// 避免在 Liquid Glass / Mica 背景上触发 GPU 每帧重合成。
        ///
        /// **适用场景**：骨架屏 shimmer、加载指示器脉冲。
        static let breathe = Animation.easeInOut(duration: 1.4).repeatForever(autoreverses: true)

        // MARK: - 循环旋转

        /// **rotate** — 异步循环旋转，菜单栏图标专用。
        ///
        /// 线性匀速 1.8 s 一圈，不自动往复。用于表示「翻译进行中」的持续状态。
        ///
        /// **适用场景**：菜单栏图标旋转指示器。
        static let rotate = Animation.linear(duration: 1.8).repeatForever(autoreverses: false)
    }
}
