import SwiftUI

// MARK: - Indicator Mode

/// 三色状态机枚举，描述翻译面板顶部的状态指示灯模式。
enum IndicatorMode: Sendable {
    case none
    /// 翻译进行中 — 黄色呼吸脉冲
    case yellow
    /// 翻译成功 — 绿色常亮
    case green
    /// 翻译失败 — 红色常亮
    case red
}

// MARK: - Isolated Indicator View (Zero-Invalidation Leaf)

/// 自包含的状态指示灯视图，将呼吸动画的 `@State` 严格限定在叶子节点内部。
///
/// ## 性能架构
///
/// 旧实现中 `breathPhase` 和 `displayOpacity` 作为 `@State` 驻留在
/// `FloatingTranslationView` 内部，导致每次动画帧（60/120 Hz）都会触发
/// 整个 `FloatingTranslationView.body` 重计算，连带 `AdaptiveGlassBackground`
/// 的 Liquid Glass 合成器重绘。
///
/// 新实现将全部动画状态下沉到此独立视图中：
/// - `@State private var breathPhase` — 仅此视图可见
/// - `@State private var displayOpacity` — 仅此视图可见
/// - 动画 tick 仅无效化此叶节点，父容器布局零开销
///
/// ## 门控降级
///
/// 所有动画均使用 `AppTheme.Motion.*.gated` 链式门控。
/// 当用户关闭「动画效果」时，颜色切换为瞬时硬切，呼吸脉冲不启动。
struct IsolatedIndicatorView: View {
    /// 当前模式，由父视图传入。
    let mode: IndicatorMode

    // MARK: - Internal Animation State

    @State private var displayOpacity: Double = 0
    @State private var breathPhase: Double = 0

    private let dragBarHeight: CGFloat = 12

    // MARK: - Derived Color

    private var indicatorColor: Color {
        switch mode {
        case .yellow: AppTheme.IndicatorColor.loading.color
        case .green:  AppTheme.IndicatorColor.success.color
        case .red:    AppTheme.IndicatorColor.error.color
        case .none:   .clear
        }
    }

    // MARK: - Body

    var body: some View {
        HStack {
            Spacer()
            ZStack {
                // Base capsule — always visible
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 36, height: 5)

                // Inner glow — tight to the capsule
                Capsule()
                    .fill(indicatorColor)
                    .frame(width: 36, height: 5)
                    .blur(radius: 3)
                    .opacity(displayOpacity * 0.9)

                // Outer halo — elliptical, matches capsule shape
                Capsule()
                    .fill(indicatorColor.opacity(0.35))
                    .frame(width: 38, height: 6)
                    .blur(radius: 5)
                    .opacity(displayOpacity * 0.85)
            }
            .frame(width: 50, height: dragBarHeight)
            .clipped()
            .shadow(
                color: displayOpacity > 0.01
                    ? indicatorColor.opacity(0.25 * displayOpacity)
                    : .clear,
                radius: 6, y: 0
            )
            Spacer()
        }
        .frame(height: dragBarHeight)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .animation(AppTheme.Motion.slow.gated, value: mode)
        .onChange(of: mode) { oldMode, newMode in
            transition(from: oldMode, to: newMode)
        }
        .onAppear {
            displayOpacity = mode == .none ? 0 : breathOpacity()
        }
    }

    // MARK: - Transition Logic

    /// 处理模式切换时的动画过渡。逻辑与原实现完全一致，
    /// 但动画曲线已替换为语义化 token。
    private func transition(from old: IndicatorMode, to new: IndicatorMode) {
        if new == .none {
            withAnimation(AppTheme.Motion.slow.gated) { displayOpacity = 0 }
            stopBreathing()
        } else if old == .none {
            withAnimation(AppTheme.Motion.slow.gated) { displayOpacity = breathOpacity() }
            if new == .yellow { startBreathing() }
        } else if old == .yellow && new != .yellow {
            stopBreathing()
            withAnimation(AppTheme.Motion.slow.gated) { displayOpacity = 1.0 }
        } else if old != .yellow && new == .yellow {
            withAnimation(AppTheme.Motion.slow.gated) { displayOpacity = breathOpacity() }
            startBreathing()
        } else {
            withAnimation(AppTheme.Motion.slow.gated) { displayOpacity = 1.0 }
        }
    }

    // MARK: - Breathing Animation

    /// 将 `breathPhase` 映射到 `[0.5, 1.0]` 区间，
    /// 与外层 glow opacity 叠加后产生 0.5 ↔ 1.0 的柔和呼吸效果。
    private func breathOpacity() -> Double {
        0.5 + 0.5 * breathPhase
    }

    /// 启动呼吸循环动画。使用 `AppTheme.Motion.breathe`，
    /// 经 `.gated` 门控后若动画关闭则自动跳过。
    private func startBreathing() {
        breathPhase = 0
        withAnimation(AppTheme.Motion.breathe.gated) {
            breathPhase = 1.0
        }
    }

    /// 停止呼吸，重置相位。
    private func stopBreathing() {
        breathPhase = 0
    }
}
