import SwiftUI

// MARK: - Staggered Entrance Container

/// 声明式错列入场容器，基于索引自动计算延迟。
///
/// ## 设计意图
///
/// 替代散落在各视图中的硬编码 `.delay(0.04)` / `.delay(0.08)` 和
/// 手动管理的 `@State showXxx` 布尔标志。每个子视图的入场延迟由
/// 公式 `Double(index) * 0.04` 动态计算，确保一致且可预测的错列节奏。
///
/// ## 动画效果
///
/// - **入场**：小幅上移 (6pt) + 淡入，使用 `AppTheme.Motion.fluid`
/// - **门控降级**：经 `.gated` 链式门控，动画关闭时子视图直接以最终
///   状态呈现（opacity 1, offset 0），无动画残留
///
/// ## 使用示例
///
/// ```swift
/// StaggeredEntranceContainer(index: 0) {
///     Text("标题").font(.title)
/// }
/// StaggeredEntranceContainer(index: 1) {
///     Text("副标题").font(.subheadline)
/// }
/// ```
///
/// 若某些 section 被条件隐藏，可使用 `IndexCounter` 动态分配连续索引：
///
/// ```swift
/// let counter = IndexCounter()
/// StaggeredEntranceContainer(index: counter.next) { headerView }
/// if showDetail {
///     StaggeredEntranceContainer(index: counter.next) { detailView }
/// }
/// ```
struct StaggeredEntranceContainer<Content: View>: View {
    /// 错列索引，决定入场延迟：`Double(index) * 0.04`。
    let index: Int

    /// 被包裹的内容。
    @ViewBuilder let content: () -> Content

    /// 内部动画驱动状态 — 仅此视图可见，父容器零开销。
    @State private var isVisible = false

    /// 基于索引的延迟计算。
    private var delay: Double { Double(index) * 0.04 }

    var body: some View {
        content()
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 6)
            .onAppear {
                withAnimation(AppTheme.Motion.fluid.gated?.delay(delay)) {
                    isVisible = true
                }
            }
    }
}

// MARK: - Index Counter

/// 引用类型计数器，用于在 `ViewBuilder` 闭包中动态分配连续索引。
///
/// 在 `ViewBuilder` 内部无法声明可变局部变量，但可以持有引用类型
/// 并调用其 mutating 方法。`IndexCounter` 专为此场景设计。
///
/// ```swift
/// var body: some View {
///     let counter = IndexCounter()
///     VStack {
///         StaggeredEntranceContainer(index: counter.next) { ... }
///         if condition {
///             StaggeredEntranceContainer(index: counter.next) { ... }
///         }
///     }
/// }
/// ```
final class IndexCounter {
    private var value: Int = 0

    /// 返回当前值并将内部计数器加 1。
    var next: Int {
        defer { value += 1 }
        return value
    }
}
