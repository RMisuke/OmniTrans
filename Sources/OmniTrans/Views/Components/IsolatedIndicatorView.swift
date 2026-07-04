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
/// 所有动画状态下沉到此独立视图中：
/// - `@State private var breathPhase` — 仅此视图可见
/// - `@State private var displayOpacity` — 仅此视图可见
/// - 动画 tick 仅无效化此叶节点，父容器布局零开销
///
/// ## 门控降级
///
/// 所有动画均使用 `AppTheme.Motion.*.gated` 链式门控。
/// 当用户关闭「动画效果」时，颜色切换为瞬时硬切，呼吸脉冲不启动。
///
/// ## 动画冲突解决 (V0.6)
///
/// 移除了视图级 `.animation(.slow, value: mode)` 修饰符，避免与
/// `withAnimation(AppTheme.Motion.breathe)` 产生隐式动画覆盖。
/// 所有动画现在仅通过 `transition(from:to:)` 中的显式 `withAnimation`
/// 触发，确保呼吸脉冲不被 `.slow` 曲线干扰。
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

                // Inner glow
                Capsule()
                    .fill(indicatorColor)
                    .frame(width: 36, height: 5)
                    .blur(radius: 3)
                    .opacity(displayOpacity * 0.9)

                // Outer halo
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
        .onChange(of: mode) { oldMode, newMode in
            transition(from: oldMode, to: newMode)
        }
        .onAppear {
            displayOpacity = mode == .none ? 0 : breathOpacity()
            if mode == .yellow { startBreathing() }
        }
    }

    // MARK: - Transition Logic

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
            displayOpacity = breathOpacity()
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

    /// 启动呼吸循环动画。使用 `withTransaction` 强制启用动画，
    /// 绕过父视图 `.animationsGated()` 施加的全局动画禁用事务。
    private func startBreathing() {
        breathPhase = 0
        var transaction = Transaction(animation: AppTheme.Motion.breathe.gated)
        transaction.disablesAnimations = false
        withTransaction(transaction) {
            breathPhase = 1.0
        }
    }

    /// 停止呼吸，重置相位。
    private func stopBreathing() {
        breathPhase = 0
    }
}
