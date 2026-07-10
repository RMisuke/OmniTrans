# OmniTrans 窗口架构设计规范 v2.0

> 版本: v2.0 | 平台: macOS 14+ | 语言: Swift 5.9

---

## 1. v1.0 → v2.0 变更摘要

| v1.0 | v2.0 | 收益 |
|------|------|------|
| SwiftUI `.regularMaterial` 作为全窗底板 | AppKit `NSVisualEffectView`（`.behindWindow` blending） | 系统级硬件合成，跟随窗口激活态自动变暗，零重绘开销 |
| 依赖 safeArea 提供标题栏间距 | 显式 `.padding(.top, 28)` 保护垫 | 全屏/刘海屏场景下 safeArea 可能归零，不再依赖系统值 |
| 硬材质 `zIndex(1)` 遮断 Tab 栏 | 线性渐变 Alpha 遮罩（8pt 羽化淡隐） | 滚动内容进入 Tab 区时高对比度平滑消隐，无硬边界 |
| 固定 `460×540` 尺寸 | `minWidth/minHeight` + `NSHostingView.intrinsicContentSize` 驱动 | 窗口按内容自适应，带弹性动画 |

---

## 2. 图层模型 v2.0

```
┌─────────────────────────────────────────────────────────────┐
│                   NSWindow (宿主)                              │
│  backgroundColor: .clear    ← 透明，由 Layer 0 提供像素        │
│  isOpaque: false            ← 允许圆角外侧透明                  │
│  isMovableByWindowBackground: true ← 全窗可拖拽                │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ contentView = NSVisualEffectView (Layer 0)                │ │
│  │  material: .hudWindow                                     │ │
│  │  blendingMode: .behindWindow                              │ │
│  │  state: .active / .inactive ← 跟随窗口焦点自动切换          │ │
│  │  cornerRadius: 20, masksToBounds: true                    │ │
│  │                                                           │ │
│  │  ┌─────────────────────────────────────────────────────┐ │ │
│  │  │ NSHostingView (Layer 1) — 透明子视图                  │ │ │
│  │  │  backgroundColor: .clear                              │ │ │
│  │  │  SwiftUI 内容 → 梯度遮罩 + 安全区保护垫                 │ │ │
│  │  └─────────────────────────────────────────────────────┘ │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. 材质选择规范

| 场景 | 材质 | 原因 |
|------|------|------|
| 全窗底板（Layer 0） | `NSVisualEffectView(.hudWindow, .behindWindow)` | 系统硬件合成，失焦自动变暗 |
| 卡片内容区 | `.regularMaterial` | inline card surface |

---

## 4. 窗口配置模板

```swift
struct WindowConfig {
    let width, height: CGFloat
    let styleMask: NSWindow.StyleMask
    let title: String
    let cornerRadius: CGFloat

    func apply(to window: NSWindow) { ... }
    func makeGlassBackdrop() -> NSVisualEffectView { ... }
    func makeHostingView(rootView:) -> NSHostingView { ... }
}
```

---

## 5. SwiftUI 内容根模板

```swift
VStack(spacing: 0) {
    // Tab 栏 + 安全区保护垫
    VStack { tabBar; Divider() }
        .padding(.top, 28)   // 显式 28pt，不依赖 safeArea

    // 内容区 + 梯度遮罩
    ScrollView { content }
        .mask(
            VStack {
                LinearGradient(clear→white, 8pt)  // 顶部羽化淡隐
                Color.white
            }
        )
}
.frame(minWidth: 460, minHeight: 540)
.clipShape(RoundedRectangle(20))
```

---

## 6. 梯度遮罩原理

```
ScrollView 内容滚动方向 ↑
         │
    ┌────┴────┐  ← y=0 (ScrollView 顶部)
    │  clear  │     透明：内容在此区域完全不可见
    │   ↕     │     8pt 渐变区间
    │  white  │     不透明：内容正常渲染
    ├─────────┤  ← y=8
    │  white  │
    │  white  │     内容区正常可见
    │  ...    │
    └─────────┘
```

当卡片向上滚动进入 Tab 栏底部 8pt 区域时，Alpha 从 1.0 平滑过渡到 0.0，实现无硬边界的羽化消隐。这比 v1.0 的 `zIndex(1)` + 硬材质遮挡方案更符合 macOS HIG 的"内容在毛玻璃下方滑入消失"的视觉语言。

---

## 7. 动态尺寸

- `NSHostingView.intrinsicContentSize` 由 SwiftUI 内容自动计算
- Tab 切换时调用 `SettingsWindowManager.updateWindowSize(animated: true)`
- `NSWindow.setFrame` 在 `AnimationEngine.animateAppKit(AppTheme.Motion.panelOpen)` 中执行
- 最小尺寸由 `WindowConfig.width/height` 保证

---

## 8. 激活态跟踪

```swift
// SettingsWindowManager 自动注册通知
NotificationCenter.default.addObserver(
    forName: NSWindow.didBecomeKeyNotification, ...
) { _ in glass.state = .active }

NotificationCenter.default.addObserver(
    forName: NSWindow.didResignKeyNotification, ...
) { _ in glass.state = .inactive }
```

`NSVisualEffectView.state` 切换由系统合成器硬件处理，不触发任何 CPU 重绘——这是用 AppKit 原生组件替代 SwiftUI Material 的关键性能收益。
