import SwiftUI

// MARK: - OmniTrans Semantic Motion Design System v1.0

extension AppTheme {
    /// 语义化动效系统中心 —— 消除视图层硬编码动画参数。
    ///
    /// ## 设计原则
    /// - **语义命名**：每个 token 描述「在什么场景下使用」而非曲线参数。
    /// - **零分配开销**：全部为 `static let` 常量，无实例化成本。
    /// - **与 ``AnimationEngine`` 协同**：通过 `.resolveGated()` 实现声明式优雅降级。
    /// - **无障碍优先**：所有 token 均设置了 `accessibilityFallback`。
    ///
    /// ## 使用示例
    /// ```swift
    /// // 视图动画
    /// .animation(AppTheme.Motion.panelOpen, value: isVisible)
    ///
    /// // 命令式触发
    /// withAnimation(AppTheme.Motion.tabSelect.resolveGated()) { selectedTab = idx }
    ///
    /// // 列表交错
    /// let stagger = StaggerAnimator(count: 5, baseDelay: 0.05, token: .featureStagger)
    /// .transition(stagger.transition(for: index))
    /// ```
    enum Motion {

        // MARK: ── 面板级 (Panel) ──

        /// **panelOpen** — 窗口/面板入场动画。
        ///
        /// scale 0.92→1.0 + opacity 0→1，平滑 spring 确保面板浮现自然。
        /// 持续时间 0.28s，stiffness 170，damping 17。
        ///
        /// **适用场景**：SettingsPanel 打开、FloatingPanel 弹出、Onboarding 窗口显示。
        static let panelOpen = AnimationToken(
            name: "panel.open",
            easing: .decelerate,
            duration: 0.28,
            spring: .smooth,
            accessibilityFallback: .instant
        )

        /// **panelClose** — 窗口/面板退场动画。
        ///
        /// scale 1.0→0.96 + opacity 1→0，快速加速曲线确保退场不拖沓。
        ///
        /// **适用场景**：SettingsPanel 关闭、FloatingPanel 收起。
        static let panelClose = AnimationToken(
            name: "panel.close",
            easing: .accelerate,
            duration: 0.20,
            accessibilityFallback: .instant
        )

        /// **panelFocus** — 窗口获得焦点时的边框发光。
        ///
        /// 微妙的 opacity pulse，不改变布局。
        ///
        /// **适用场景**：窗口 `.makeKeyAndOrderFront`、标签页聚焦。
        static let panelFocus = AnimationToken(
            name: "panel.focus",
            easing: .standard,
            duration: 0.30,
            spring: .gentle,
            accessibilityFallback: .instant
        )

        // MARK: ── 标签页 (Tab) ──

        /// **tabSelect** — 标签选中态切换。
        ///
        /// 选中指示器滑动 + 文字适度 scale，snappy spring。
        ///
        /// **适用场景**：SettingsPanel 翻译/API/通用/关于 标签切换。
        static let tabSelect = AnimationToken(
            name: "tab.select",
            easing: .sharp,
            duration: 0.25,
            spring: .snappy,
            accessibilityFallback: .instant
        )

        /// **contentCrossfade** — 内容区交叉淡入淡出。
        ///
        /// 旧内容 fadeOut (0.12s) + 新内容 fadeIn + slideUp 6px (0.22s)。
        ///
        /// **适用场景**：标签内容区切换、表单区域条件显隐。
        static let contentCrossfade = AnimationToken(
            name: "content.crossfade",
            easing: .standard,
            duration: 0.25,
            accessibilityFallback: .instant
        )

        // MARK: ── 瞬态微交互 (Snip) ──

        /// **snip** — 瞬时反馈曲线，用于悬浮、按压、微调等高频交互。
        ///
        /// 持续时间短 (0.18s)、snappy spring，确保操作手感干脆不拖沓。
        ///
        /// **适用场景**：按钮 hover 态、tag 选中态、toggle 微动效。
        static let snip = AnimationToken(
            name: "snip",
            easing: .sharp,
            duration: 0.18,
            spring: .snappy,
            accessibilityFallback: .instant
        )

        // MARK: ── 容器过渡 (Fluid) ──

        /// **fluid** — 标准流体曲线，用于容器入场、标签页切换等核心容器过渡。
        ///
        /// 持续时间适中 (0.30s)、smooth spring，在流畅感与性能之间取得平衡。
        ///
        /// **适用场景**：内容区切换、面板展开/收起。
        static let fluid = AnimationToken(
            name: "fluid",
            easing: .standard,
            duration: 0.30,
            spring: .smooth,
            accessibilityFallback: .instant
        )

        // MARK: ── 状态演进 (Slow) ──

        /// **slow** — 柔和演进曲线，用于状态指示灯、Toast 提示的隐显。
        ///
        /// 使用标准 ease-in-out 曲线，0.40s 持续时间确保状态变化可感知但不突兀。
        ///
        /// **适用场景**：翻译状态灯、成功/错误脉冲、Toast 淡入淡出。
        static let slow = AnimationToken(
            name: "slow",
            easing: .easeInOut,
            duration: 0.40,
            accessibilityFallback: .instant
        )

        // MARK: ── 开关 (Toggle) ──

        /// **toggleReveal** — 开关关联内容的展开/收起。
        ///
        /// height expand + opacity + slideDown，smooth spring。
        ///
        /// **适用场景**：语境感知开关展开上下文滑块、高级选项展开、自定义提示词区域。
        static let toggleReveal = AnimationToken(
            name: "toggle.reveal",
            easing: .decelerate,
            duration: 0.25,
            spring: .smooth,
            accessibilityFallback: .instant
        )

        /// **toggleCollapse** — 开关关联内容的折叠。
        ///
        /// 比展开略快 (0.18s)，accelerate curve，减少用户等待感。
        ///
        /// **适用场景**：关闭开关时关联选项收起。
        static let toggleCollapse = AnimationToken(
            name: "toggle.collapse",
            easing: .accelerate,
            duration: 0.18,
            accessibilityFallback: .instant
        )

        // MARK: ── 滑块 (Slider) ──

        /// **sliderValuePulse** — 滑块值标签的数值变化 pulse。
        ///
        /// scale 1.0→1.10→1.0，snappy spring，0.12s。
        ///
        /// **适用场景**：温度滑块数值标签、上下文强度标签、Max Tokens 数值。
        static let sliderValuePulse = AnimationToken(
            name: "slider.valuePulse",
            easing: .sharp,
            duration: 0.12,
            spring: .snappy,
            accessibilityFallback: .instant
        )

        /// **sliderTextCrossfade** — 滑块关联描述文本切换。
        ///
        /// opacity 0→1，0.18s，流畅但不抢眼。
        ///
        /// **适用场景**：上下文强度描述文本切换 (最低/较低/默认/较高/最高)。
        static let sliderTextCrossfade = AnimationToken(
            name: "slider.textCrossfade",
            easing: .standard,
            duration: 0.18,
            accessibilityFallback: .instant
        )

        // MARK: ── 按钮 (Button) ──

        /// **buttonPress** — 按钮按下反馈。
        ///
        /// scale 1.0→0.96→1.0，snappy spring，0.10s。
        ///
        /// **适用场景**：所有按钮点击反馈 (scale on press)。
        static let buttonPress = AnimationToken(
            name: "button.press",
            easing: .sharp,
            duration: 0.10,
            spring: .snappy,
            accessibilityFallback: .instant
        )

        /// **buttonHover** — 按钮悬停过渡。
        ///
        /// 背景色/亮度过渡，0.15s，gentle spring。
        ///
        /// **适用场景**：按钮 hover 态、标签 hover 态、热键录制按钮 hover。
        static let buttonHover = AnimationToken(
            name: "button.hover",
            easing: .standard,
            duration: 0.15,
            spring: .gentle,
            accessibilityFallback: .instant
        )

        /// **resetEmphasis** — "默认"/"恢复默认" 按钮的轻量 glow。
        ///
        /// 短暂 opacity pulse + scale，0.25s，表示值已重置。
        ///
        /// **适用场景**：温度默认按钮、Max Tokens 默认按钮、快捷键默认按钮、Prompt 恢复默认。
        static let resetEmphasis = AnimationToken(
            name: "button.reset",
            easing: .decelerate,
            duration: 0.25,
            spring: .gentle,
            accessibilityFallback: .instant
        )

        // MARK: ── 热键录制 (Hotkey Recording) ──

        /// **recordingPulse** — 录制中的呼吸动画。
        ///
        /// 循环 opacity pulse，1.2s 周期，表示正在等待按键。
        ///
        /// **适用场景**：热键录制指示器 "按下组合键…"。
        static let recordingPulse = AnimationToken(
            name: "recording.pulse",
            easing: .easeInOut,
            duration: 1.2,
            accessibilityFallback: .instant
        )

        /// **recordingComplete** — 录制完成确认。
        ///
        /// 绿色 flash + scale bounce，0.25s，bouncy spring。
        ///
        /// **适用场景**：热键录制成功后键位标签更新动画。
        static let recordingComplete = AnimationToken(
            name: "recording.complete",
            easing: .sharp,
            duration: 0.25,
            spring: .bouncy,
            accessibilityFallback: .instant
        )

        /// **recordingCancel** — 录制取消反馈。
        ///
        /// 红色短暂 flash，0.15s，表示录制已中止。
        ///
        /// **适用场景**：热键录制取消按钮点击后状态恢复。
        static let recordingCancel = AnimationToken(
            name: "recording.cancel",
            easing: .accelerate,
            duration: 0.15,
            accessibilityFallback: .instant
        )

        // MARK: ── 高级选项 (Advanced) ──

        /// **expandReveal** — 内容区展开。
        ///
        /// height expand + opacity + slide down，0.30s，smooth spring。
        ///
        /// **适用场景**：高级选项展开、卡片详情展开。
        static let expandReveal = AnimationToken(
            name: "expand.reveal",
            easing: .decelerate,
            duration: 0.30,
            spring: .smooth,
            accessibilityFallback: .instant
        )

        /// **expandCollapse** — 内容区折叠。
        ///
        /// 比展开快 (0.20s)，加速曲线。
        ///
        /// **适用场景**：高级选项折叠。
        static let expandCollapse = AnimationToken(
            name: "expand.collapse",
            easing: .accelerate,
            duration: 0.20,
            accessibilityFallback: .instant
        )

        // MARK: ── 表单验证 (Form Validation) ──

        /// **fieldError** — 输入字段错误抖动。
        ///
        /// 水平 shake + 红色边框 flash，0.35s。
        ///
        /// **适用场景**：数值越界、API Key 格式错误。
        static let fieldError = AnimationToken(
            name: "field.error",
            easing: .sharp,
            duration: 0.35,
            spring: SpringModel(mass: 1.0, stiffness: 500, damping: 12),
            accessibilityFallback: .instant
        )

        /// **fieldSuccess** — 输入字段保存确认。
        ///
        /// 绿色 check flash，0.25s，gentle spring。
        ///
        /// **适用场景**：配置保存成功提示。
        static let fieldSuccess = AnimationToken(
            name: "field.success",
            easing: .decelerate,
            duration: 0.25,
            spring: .gentle,
            accessibilityFallback: .instant
        )

        // MARK: ── About 页面 (About) ──

        /// **iconEntrance** — 图标入场动画。
        ///
        /// scale 0.8→1.0 + opacity，0.35s，bouncy spring。
        ///
        /// **适用场景**：About 页应用图标、Onboarding 图标。
        static let iconEntrance = AnimationToken(
            name: "about.iconEntrance",
            easing: .decelerate,
            duration: 0.35,
            spring: .bouncy,
            accessibilityFallback: .instant
        )

        /// **featureStagger** — 特性列表交错入场。
        ///
        /// 每条 slideUp 6px + opacity，配合 `StaggerAnimator` 使用。
        /// 基础延迟 0.05s，总计 ≤ 0.25s。
        ///
        /// **适用场景**：About 页特性列表、Onboarding 功能列表。
        static let featureStagger = AnimationToken(
            name: "about.featureStagger",
            easing: .decelerate,
            duration: 0.22,
            spring: .gentle,
            accessibilityFallback: .instant
        )

        // MARK: ── 浮动面板 (FloatingPanel) ──

        /// **panelAppear** — 浮动面板入场。
        ///
        /// scale 0.97→1.0 + opacity 0→1 + offsetY 6→0，refined spring。
        /// 0.25s，柔和阻尼确保入场优雅不突兀。
        ///
        /// **适用场景**：FloatingPanel 从菜单栏弹出时显隐。
        static let panelAppear = AnimationToken(
            name: "panel.appear",
            easing: .decelerate,
            duration: 0.25,
            spring: .refined,
            accessibilityFallback: .instant
        )

        /// **panelHide** — 浮动面板退场 (AppKit alpha 动画)。
        ///
        /// 加速曲线 0.18s，确保退场不拖沓。用于 `NSAnimationContext`。
        ///
        /// **适用场景**：FloatingPanel.hide() 的 alphaValue 动画。
        static let panelHide = AnimationToken(
            name: "panel.hide",
            easing: .accelerate,
            duration: 0.18,
            accessibilityFallback: .instant
        )

        /// **panelResize** — 浮动面板高度动态变化 (AppKit frame 动画)。
        ///
        /// ease-in-out 曲线 0.22s，同步更新 shadowPath 避免阴影跳变。
        ///
        /// **适用场景**：FloatingPanel.updateHeight() 的 frame 动画。
        static let panelResize = AnimationToken(
            name: "panel.resize",
            easing: .easeInOut,
            duration: 0.22,
            accessibilityFallback: .instant
        )

        // MARK: ── 内容过渡 (Content Swap) ──

        /// **contentSwap** — 中间区域内容切换过渡。
        ///
        /// opacity + move(edge: .bottom)，gentle spring 0.30s。
        /// 更高阻尼确保过渡柔和，不产生视觉跳跃感。
        ///
        /// **适用场景**：翻译中 ↔ 译文 ↔ 词典 ↔ 错误 ↔ 历史搜索 切换。
        static let contentSwap = AnimationToken(
            name: "content.swap",
            easing: .standard,
            duration: 0.30,
            spring: .gentle,
            accessibilityFallback: .instant
        )

        // MARK: ── 微交互 (Micro Interaction) ──

        /// **pinToggle** — 图钉按钮旋转 (0°↔45°) + 图标切换。
        ///
        /// gentle spring 0.30s，高阻尼让旋转柔和精致不突兀。
        ///
        /// **适用场景**：FloatingPanel 顶栏 pinButton 状态切换。
        static let pinToggle = AnimationToken(
            name: "pin.toggle",
            easing: .sharp,
            duration: 0.30,
            spring: .gentle,
            accessibilityFallback: .instant
        )

        /// **brainPulse** — 上下文感知大脑图标脉冲 (scale 1.0↔1.25)。
        ///
        /// gentle spring 0.20s，柔和回弹让脉冲反馈精致不扰人。
        ///
        /// **适用场景**：ContextAware 按钮 toggle 时的图标微脉冲。
        static let brainPulseAnim = AnimationToken(
            name: "brain.pulse",
            easing: .sharp,
            duration: 0.20,
            spring: .gentle,
            accessibilityFallback: .instant
        )

        /// **clearFade** — 清除按钮淡入淡出 (opacity 0↔1)。
        ///
        /// ease-out 曲线 0.20s，单向淡出简洁不抢眼。
        ///
        /// **适用场景**：输入框清除按钮 (xmark) 的显隐。
        static let clearFade = AnimationToken(
            name: "clear.fade",
            easing: .easeOut,
            duration: 0.20,
            accessibilityFallback: .instant
        )

        /// **cardExpand** — 供应商卡片双击展开/折叠。
        ///
        /// smooth spring 0.30s (response) + 0.80 damping，
        /// 手感柔和不僵硬，适合卡片内容的展开收起。
        ///
        /// **适用场景**：ProviderSettingsView 卡片双击展开/折叠。
        static let cardExpand = AnimationToken(
            name: "card.expand",
            easing: .decelerate,
            duration: 0.30,
            spring: SpringModel(mass: 1.0, stiffness: 150, damping: 17),
            accessibilityFallback: .instant
        )

        // MARK: ── 输入区 (Input) ──

        /// **inputExpand** — 输入框高度弹性变化。
        ///
        /// gentle spring 0.30s，高阻尼减少回弹，让高度过渡平顺自然。
        ///
        /// **适用场景**：TextEditor 在单行/多行模式间的高度帧变化。
        static let inputExpand = AnimationToken(
            name: "input.expand",
            easing: .standard,
            duration: 0.30,
            spring: .gentle,
            accessibilityFallback: .instant
        )

        // MARK: ── 状态灯 (Status) ──

        /// **statusFade** — 状态指示灯淡入淡出 (opacity 0↔1)。
        ///
        /// ease-in-out 0.50s，平缓过渡让用户可感知状态变化。
        ///
        /// **适用场景**：statusIndicator（绿/黄/红）的显隐。
        static let statusFade = AnimationToken(
            name: "status.fade",
            easing: .easeInOut,
            duration: 0.50,
            accessibilityFallback: .instant
        )

        /// **statusBreathingDuration** — 状态灯呼吸循环的单次周期。
        ///
        /// 配合 `repeatForever(autoreverses: true)` 使用。
        static let statusBreathingDuration: TimeInterval = 0.55

        /// **statusBreathing** — 状态灯呼吸脉冲动画。
        ///
        /// 使用 ease-in-out + `statusBreathingDuration` 时长，
        /// 搭配 `.repeatForever(autoreverses: true)` 实现持续呼吸效果。
        ///
        /// **适用场景**：statusIndicator 的 scale + opacity 呼吸循环。
        static var statusBreathing: Animation {
            Animation.easeInOut(duration: statusBreathingDuration)
        }

        /// **statusGlow** — 状态灯光晕脉冲 (shadow radius + opacity)。
        ///
        /// ease-in-out 0.50s，随呼吸同步变化。
        ///
        /// **适用场景**：statusIndicator 的 shadow(color:radius:) 过渡。
        static let statusGlow = AnimationToken(
            name: "status.glow",
            easing: .easeInOut,
            duration: 0.50,
            accessibilityFallback: .instant
        )

        // MARK: ── 循环动画 (Looping) ──

        /// **breathe** — 异步循环呼吸，仅供无状态叶子节点脉冲使用（零布局依赖）。
        ///
        /// 1.4s 周期、自动往复，避免在 Glass 背景上触发 GPU 每帧重合成。
        ///
        /// **适用场景**：骨架屏 shimmer、加载指示器脉冲。
        static let breathe = Animation.easeInOut(duration: 1.4).repeatForever(autoreverses: true)

        /// **rotate** — 异步循环旋转，菜单栏图标专用。
        ///
        /// 线性匀速 1.8s 一圈，不自动往复。
        ///
        /// **适用场景**：菜单栏图标旋转指示器。
        static let rotate = Animation.linear(duration: 1.8).repeatForever(autoreverses: false)

        // MARK: ── 循环 Token (新) ──

        /// **indeterminateProgress** — 不确定进度指示器。
        ///
        /// 线性循环，1.5s 一圈，用于加载状态。
        ///
        /// **适用场景**：API 测试中、翻译加载中。
        static let indeterminateProgress = AnimationToken(
            name: "progress.indeterminate",
            easing: .linear,
            duration: 1.5,
            accessibilityFallback: .instant
        )

        // MARK: ── 遗留兼容 (Legacy) ──

        /// 工作区过渡（保留向后兼容）。
        static let workspaceTransition = fluid

        /// 工作区 reveal（保留向后兼容）。
        static let workspaceReveal = AnimationToken(
            name: "workspace.reveal",
            easing: .decelerate,
            duration: 0.35,
            spring: SpringModel(mass: 1.0, stiffness: 160, damping: 18),
            accessibilityFallback: .instant
        )

        /// HUD 显隐（保留向后兼容）。
        static let hudVisibility = AnimationToken(
            name: "hud.visibility",
            easing: .easeInOut,
            duration: 0.25,
            accessibilityFallback: .instant
        )

        /// Glass 附着（保留向后兼容）。
        static let glassAttach = AnimationToken(
            name: "glass.attach",
            easing: .decelerate,
            duration: 0.25,
            spring: SpringModel(mass: 1.0, stiffness: 200, damping: 22),
            accessibilityFallback: .instant
        )

        /// Glass 分离（保留向后兼容）。
        static let glassDetach = AnimationToken(
            name: "glass.detach",
            easing: .easeIn,
            duration: 0.18,
            accessibilityFallback: .instant
        )
    }
}
