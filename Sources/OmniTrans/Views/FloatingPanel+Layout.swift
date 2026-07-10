import CoreGraphics
import SwiftUI

// MARK: - FloatingPanel Layout Constants

/// FloatingPanel 专有布局常量集。
///
/// ## 设计目标
/// - 集中管理所有魔法数字，消除视图层散落的硬编码值。
/// - 提供语义化命名，降低维护认知负荷。
/// - 与 `AppTheme` 系统的通用 token 互补（AppTheme 放全局 token，此处放面板专有 layout）。
enum FloatingPanelLayout {

    // MARK: - Window

    /// 面板默认宽度。
    static let panelWidth: CGFloat = 420

    /// 面板理想宽度。
    static let panelIdealWidth: CGFloat = 460

    /// 面板最小高度。
    static let panelMinHeight: CGFloat = 280

    /// 面板默认高度（未指定 mode 时的回退值）。
    static let panelDefaultHeight: CGFloat = 460

    // MARK: - Height by Mode

    /// "small" 模式高度。
    static let heightSmall: CGFloat = 320

    /// "large" 模式高度。
    static let heightLarge: CGFloat = 620

    /// "dynamic" 模式最小高度。
    static let heightDynamicMin: CGFloat = 480

    /// "dynamic" 模式最大高度。
    static let heightDynamicMax: CGFloat = 800

    // MARK: - Margins & Padding

    /// 顶部栏与底部栏水平内边距。
    static let barHorizontalPadding: CGFloat = 12

    /// 顶部栏与底部栏垂直内边距。
    static let barVerticalPadding: CGFloat = 8

    /// 输入卡片水平外间距（距面板边缘）。
    static let inputCardHorizontalOuter: CGFloat = 16

    /// 输入卡片垂直外间距。
    static let inputCardVerticalOuter: CGFloat = 4

    /// 输入卡片内边距（AppTheme.spaceMD 别名）。
    static let inputCardInnerPadding: CGFloat = 17

    /// 输入卡片间距。
    static let inputCardSpacing: CGFloat = 8

    /// 底部栏底部间距。
    static let bottomBarBottom: CGFloat = 12

    // MARK: - Icon Sizes

    /// 应用图标尺寸。
    static let appIconSize: CGFloat = 18

    /// 状态指示灯尺寸。
    static let statusDotSize: CGFloat = 8

    /// 图钉按钮尺寸。
    static let pinButtonSize: CGFloat = 22

    /// 工具栏按钮尺寸。
    static let toolbarBtnSize: CGFloat = 22

    // MARK: - Font Sizes

    /// 顶部栏标签字号。
    static let topBarLabelSize: CGFloat = 11

    /// 供应商菜单字号。
    static let providerMenuSize: CGFloat = 9

    /// 底部栏按钮字号。
    static let bottomBarLabelSize: CGFloat = 10

    // MARK: - Result Area

    /// 译文卡片最小高度。
    static let resultMinHeight: CGFloat = 80

    /// 非动态模式下译文卡片最大高度。
    static let resultMaxHeightFixed: CGFloat = 280

    /// 译文正文行高计算字号（系统 15pt）。
    static let resultBodyFontSize: CGFloat = 15

    // MARK: - History

    /// 历史列表最大高度。
    static let historyListMaxHeight: CGFloat = 250

    /// 历史卡片字号。
    static let historyCardLabelSize: CGFloat = 12

    /// 历史卡片内容字号。
    static let historyCardContentSize: CGFloat = 11

    // MARK: - Editor

    /// TextEditor 默认垂直 containerInset。
    /// NSTextView default vertical inset ≈ 8pt，但 TextEditor 实测约 6pt。
    static let textContainerVerticalInset: CGFloat = 6

    /// 输入框翻译模式最小行数。
    static let inputMinLines: Int = 3

    /// 输入框翻译模式最大行数。
    static let inputMaxLines: Int = 5

    // MARK: - Text Layout

    /// 文本布局水平内边距总和 = `.padding(.horizontal, 16)` × 2。
    static let textHorizontalPadding: CGFloat = 32

    /// 滚动指示器宽度。
    static let scrollIndicatorWidth: CGFloat = 34

    /// 文本可用宽度 = 面板宽度 - 水平内边距 - 滚动指示器。
    static var textLayoutWidth: CGFloat {
        panelWidth - textHorizontalPadding - scrollIndicatorWidth
    }

    // MARK: - Chrome Height

    /// Chrome 高度合理范围下限。
    static let chromeMin: CGFloat = 120

    /// Chrome 高度合理范围上限。
    static let chromeMax: CGFloat = 300

    /// Chrome 高度初始估算值（topBar ~36pt + inputCard ~120pt + bottomBar ~50pt + 间距）。
    static let chromeInitialEstimate: CGFloat = 180

    // MARK: - Transitions

    /// 默认内容区过渡类型 — 仅定义「什么」变换，动画「速度」由
    /// `AppTheme.Motion.contentSwap` Token 在 `.animation()` 修饰符中指定。
    static var defaultContentTransition: AnyTransition {
        .opacity.combined(with: .move(edge: .bottom))
    }

    // MARK: - API Probe

    /// API 连通性探测最小间隔（秒）。
    static let apiProbeMinInterval: TimeInterval = 30
}
