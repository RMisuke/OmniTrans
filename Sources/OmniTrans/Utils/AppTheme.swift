import SwiftUI

// MARK: - OmniTrans v0.7 Workspace Design System
//
// Liquid Glass workspace-first design aligned with macOS 26+ HIG.
//
// ## 关键原则
// - **Content First**: 内容为主体，Glass 负责交互层。
// - **System Glass**: 使用系统 Material，不自己绘制玻璃效果。
// - **Floating Controls**: Header 消失，全部控件悬浮。
// - **Minimal Hierarchy**: 5 层 → Canvas / Glass / Overlay / HUD / Notification。
// - **Reduced Chrome**: 无 Card、无 Shadow、无 Divider（内容区）。
//
// ## Token 分类
// - `WorkspaceCanvas*`  — 内容层
// - `Glass*`            — 控件玻璃层
// - `Floating*`         — 悬浮控件
// - `HUD*`              — 底部悬浮胶囊
// - `Overlay*`          — 通知层
enum AppTheme {

    // MARK: - Apple Design System Colors

    /// System accent colour — reads directly from AppKit's `controlAccentColor`.
    static var accentAction: Color { Color(nsColor: .controlAccentColor) }

    /// White text for dark surfaces.
    static let onDark = Color.white

    // MARK: - Text colours (system-native)

    static let textPrimary   = Color(nsColor: .textColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary  = Color(nsColor: .tertiaryLabelColor)

    /// Backward-compatible alias — HIG: system `.tertiaryLabelColor` via `textTertiary`.
    static var textCaptionGray: Color { textTertiary }

    // MARK: - System Materials (no custom glass)

    /// Solid window background — opaque matte for panels.
    static let bgSolid = Color(nsColor: .windowBackgroundColor)

    /// Control background for form rows.
    static let bgControl = Color(nsColor: .controlBackgroundColor)

    // MARK: - Semantic

    static let success = IndicatorColor.success.color
    static let error   = IndicatorColor.error.color
    static let warning = Color.orange

    // MARK: - Backward-compatible aliases

    static let textAccent = accentAction
    static let bgSubtle   = Color(nsColor: .quaternaryLabelColor)
    static let toggleTint = Color(nsColor: .controlAccentColor)

    // MARK: - Hairline (保留用于 Glass 控件边界)

    static let hairline = Color.primary.opacity(0.12)

    // MARK: - Typography（v0.8 可读性优先 Scale）
    //
    // HIG 底线：正文 ≥13pt。旧 Scale 的 8–12pt 角标字体已全部上调。

    /// 角标/徽章最小字号（原 10，低于可读底线）。
    static let fontSizeMicro    = 11.0
    /// 次要说明文字。
    static let fontSizeFine     = 12.0
    /// 说明性文字。
    static let fontSizeCaption  = 13.0
    /// 正文。
    static let fontSizeBody     = 15.0
    /// 标题行。
    static let fontSizeHeadline = 15.0
    /// 页面标题。
    static let fontSizeTitle    = 19.0

    // MARK: - Spacing (8px base)

    static let spaceXXS = 4.0
    static let spaceXS  = 8.0
    static let spaceSM  = 12.0
    static let spaceMD  = 17.0
    static let spaceLG  = 24.0
    static let spaceXL  = 32.0

    // MARK: ── v0.7 Workspace Tokens ──

    /// 工作区画布内边距。
    static let workspaceInset: CGFloat = 16

    /// 工作区内容间距。
    static let contentSpacing: CGFloat = 8

    /// 画布圆角（面板外层统一）。
    static let workspaceCornerRadius: CGFloat = 20

    /// HUD 胶囊圆角。
    static let hudCornerRadius: CGFloat = 16

    // MARK: ── v0.7 Glass Tokens ──

    /// 悬浮控件玻璃材料。
    static let glassControlMaterial: Material = .ultraThinMaterial

    /// 悬浮控件内边距。
    static let glassControlPadding: CGFloat = 8

    /// 悬浮控件圆角。
    static let glassControlRadius: CGFloat = 12

    // MARK: ── v0.7 Legacy aliases (preserve source compatibility) ──

    static let bgThick = Material.ultraThickMaterial

    /// HIG: system `windowBackgroundColor` — adaptive light/dark.
    static var cardSurface: Color { Color(nsColor: .windowBackgroundColor) }

    static let cardBorder = Color.primary.opacity(0.08)

    // Legacy radius
    static let radiusXS  : CGFloat = 5.0
    static let radiusSM  : CGFloat = 8.0
    static let radiusMD  : CGFloat = 11.0
    static let radiusLG  : CGFloat = 18.0
    static let radiusPill: CGFloat = 9999.0
}

// MARK: - Material Policy（v0.8 哑光画布 + 玻璃悬浮件）
//
// 双层模型：内容主体一律实底，半透明模糊仅限悬浮控件白名单。
// 对比度与层级靠排版与留白表达，而非透明度堆叠 —— 减少模糊、提升高级感。
extension AppTheme {
    enum MaterialPolicy {
        /// 内容画布背景 —— 实底 `windowBackgroundColor`，随浅色/深色自适应。
        public static let canvasBackground = Color(nsColor: .windowBackgroundColor)

        /// 卡片/表单行表面 —— 实底 `controlBackgroundColor` + hairline 描边。
        public static let cardBackground = Color(nsColor: .controlBackgroundColor)

        /// 悬浮控件条材质（白名单内唯一允许的玻璃）—— 薄雾而非深水。
        public static let floatingControlMaterial: Material = .regularMaterial

        /// 卡片描边。
        public static var cardStroke: Color { AppTheme.hairline }
    }
}

// MARK: - Indicator Colors

extension AppTheme {
    enum IndicatorColor: CaseIterable {
        case loading
        case success
        case error

        var color: Color {
            switch self {
            case .loading: Color(red: 0.980, green: 0.784, blue: 0.000)
            case .success: Color(red: 0.204, green: 0.831, blue: 0.600)
            case .error:   Color(red: 1.000, green: 0.361, blue: 0.376)
            }
        }
    }
}

// MARK: - View Extensions (v0.7 workspace-first)

extension View {

    // ── Legacy (preserved) ──

    func cardStyle(bg: Color = AppTheme.bgControl, cornerRadius: CGFloat = AppTheme.radiusSM) -> some View {
        self.background(bg).cornerRadius(cornerRadius)
    }

    func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: AppTheme.fontSizeHeadline, weight: .semibold))
            .foregroundColor(AppTheme.textPrimary)
    }

    func badgeStyle(_ bg: Color = AppTheme.bgControl) -> some View {
        self
            .font(.system(size: AppTheme.fontSizeCaption, weight: .medium))
            .foregroundColor(AppTheme.textPrimary)
            .padding(.horizontal, AppTheme.spaceXS)
            .padding(.vertical, 3)
            .background(bg)
            .cornerRadius(AppTheme.radiusXS)
    }

    func hintStyle() -> some View {
        self
            .font(.system(size: AppTheme.fontSizeFine))
            .foregroundColor(AppTheme.textTertiary)
    }

    func wordHintBar() -> some View {
        self
            .font(.system(size: AppTheme.fontSizeMicro))
            .foregroundColor(AppTheme.accentAction)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(AppTheme.accentAction.opacity(0.08))
            .cornerRadius(AppTheme.radiusXS)
    }

    func nativeCardStyle() -> some View {
        self
            .padding(AppTheme.spaceMD)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.radiusLG, style: .continuous)
                    .fill(AppTheme.MaterialPolicy.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.radiusLG, style: .continuous)
                            .strokeBorder(AppTheme.MaterialPolicy.cardStroke)
                    )
            )
    }

    /// `nativeCardStyle` + O(1) shadow on the background shape.
    /// Shadow is decoupled from the content container so text changes
    /// don't trigger per-pixel alpha-mask recalculations.
    func nativeCardStyleWithShadow() -> some View {
        self
            .padding(AppTheme.spaceMD)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.radiusLG, style: .continuous)
                    .fill(AppTheme.MaterialPolicy.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.radiusLG, style: .continuous)
                            .strokeBorder(AppTheme.MaterialPolicy.cardStroke)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
            )
    }

    func glassCardStyle() -> some View { nativeCardStyle() }

    func actionButtonStyle() -> some View {
        self
            .font(.system(size: AppTheme.fontSizeBody, weight: .regular))
            .foregroundColor(.white)
            .padding(.horizontal, 22).padding(.vertical, 11)
            .background(Capsule().fill(AppTheme.accentAction))
    }

    func headerDivider() -> some View {
        self.overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.hairline).frame(height: 0.5)
        }
    }

    func keycapStyle() -> some View {
        self
            .font(.system(size: AppTheme.fontSizeFine, weight: .medium, design: .monospaced))
            .foregroundColor(.primary)
            .padding(.horizontal, 3).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.radiusXS)
                    .fill(.quaternary)
                    .shadow(color: .black.opacity(0.1), radius: 0.5, y: 0.5)
            )
    }

    func elegantToggle() -> some View {
        self
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(AppTheme.toggleTint)
    }

    // MARK: ── v0.7 Workspace Extensions ──

    /// 将视图包裹在悬浮 Glass 控件中（用于 Overlay 控件）。
    func glassControl() -> some View {
        self
            .padding(.horizontal, AppTheme.glassControlPadding)
            .padding(.vertical, AppTheme.glassControlPadding * 0.75)
            .background(AppTheme.glassControlMaterial)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.glassControlRadius, style: .continuous))
    }

    /// HUD 胶囊容器（底部悬浮工具条）。
    func hudCapsule() -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.hudCornerRadius, style: .continuous))
    }

    /// 工作区内容标准内边距。
    func workspaceContentPadding() -> some View {
        self.padding(.horizontal, AppTheme.workspaceInset)
    }

    // MARK: ── v0.8 悬浮控件表面（macOS 26 Liquid Glass 渐进增强）──

    /// 悬浮控件表面 —— 白名单内的玻璃使用点。
    /// macOS 26+：系统 Liquid Glass；更早版本：实底 + hairline 描边回退。
    @ViewBuilder
    func floatingControlSurface<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(AppTheme.MaterialPolicy.cardBackground, in: shape)
                .overlay(shape.strokeBorder(AppTheme.MaterialPolicy.cardStroke))
        }
    }

    /// 实底卡片表面（v0.8 默认表面）—— 替代一切内容区毛玻璃。
    func solidCardSurface<S: InsettableShape>(in shape: S) -> some View {
        self
            .background(AppTheme.MaterialPolicy.cardBackground, in: shape)
            .overlay(shape.strokeBorder(AppTheme.MaterialPolicy.cardStroke))
    }

    // MARK: ── v6.5 Liquid Glass 工具栏表面 ──

    /// 工具栏/导航栏 Liquid Glass 表面 —— macOS 26+ 使用系统 Liquid Glass，
    /// 更早版本回退到实底 + hairline 描边。
    /// 适用于：顶栏、底栏、Tab 栏、搜索栏等导航/工具区域。
    @ViewBuilder
    func liquidGlassToolbar<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(Material.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(AppTheme.MaterialPolicy.cardStroke))
        }
    }

    /// Liquid Glass 按钮样式适配 —— macOS 26+ 使用系统 .glass 样式，
    /// 更早版本回退到 borderless + 实底背景。
    @ViewBuilder
    func liquidGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.borderless)
        }
    }

    /// Liquid Glass 突出按钮样式适配 —— macOS 26+ 使用 .glassProminent，
    /// 更早版本回退到 .borderedProminent。
    @ViewBuilder
    func liquidGlassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Animation View Extensions

extension View {

    // MARK: ── Shared Card Shadow ──

    /// 统一的卡片阴影，API 卡片与原生词典卡片共享。
    /// 参数与 `animatedTabBar` 的投影保持一致，确保全局视觉协调。
    func cardShadow() -> some View {
        self.shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 2)
    }

    // MARK: ── Button Feedback ──

    /// 按钮按下缩放反馈 — scale 1.0→0.96→1.0 on tap。
    ///
    /// 通过 `ButtonStyle` 的 `isPressed` 环境变量驱动，无额外状态管理。
    func pressableAnimation() -> some View {
        self.buttonStyle(PressableButtonStyle())
    }

    /// 悬停亮度过渡 — 配合 `.onHover` 使用。
    func hoverableAnimation(isHovering: Bool) -> some View {
        self
            .brightness(isHovering ? 0.05 : 0)
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .animation(AppTheme.Motion.buttonHover.resolveGated(), value: isHovering)
    }

    // MARK: ── Enter/Exit Transitions ──

    /// 标准入场过渡：opacity 0→1 + slideUp 6px。
    func entranceTransition() -> some View {
        self.transition(
            .asymmetric(
                insertion: .opacity
                    .combined(with: .offset(y: 6))
                    .animation(AppTheme.Motion.contentCrossfade.resolve().delay(0.05)),
                removal: .opacity
                    .animation(AppTheme.Motion.toggleCollapse.resolve())
            )
        )
    }

    /// 展开折叠过渡：opacity + slide + height。
    func expandableTransition() -> some View {
        self.transition(
            .asymmetric(
                insertion: .opacity
                    .combined(with: .move(edge: .top))
                    .animation(AppTheme.Motion.expandReveal.resolve()),
                removal: .opacity
                    .combined(with: .move(edge: .top))
                    .animation(AppTheme.Motion.expandCollapse.resolve())
            )
        )
    }
}

// MARK: - Pressable Button Style

/// Button style that applies a subtle scale-down on press.
///
/// Uses `scaleEffect` driven by `isPressed` from SwiftUI's button environment.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(AppTheme.Motion.buttonPress.resolveGated(), value: configuration.isPressed)
    }
}
