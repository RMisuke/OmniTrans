# OmniTrans 动画系统架构方案

> 版本: v1.0 | 平台: macOS 14+ | 语言: Swift 5.9

---

## 1. 现有动画系统分析

### 1.1 现状概览

当前项目存在三套相互独立的动画机制：

| 模块 | 文件 | 职责 | 问题 |
|------|------|------|------|
| `GlobalAnimationSystem` | [`AnimationSystem.swift`](../Sources/OmniTrans/Utils/AnimationSystem.swift) | 全局动画模式解析 + AppKit 桥接 | 与 `AppTheme.Motion` 无关联，`AnimationProfile` 几乎未被视图层使用 |
| `AppTheme.Motion` | [`AppTheme+Motion.swift`](../Sources/OmniTrans/Utils/AppTheme+Motion.swift) | 语义化动效令牌 | 仅定义了 9 个 token，缺少 SettingsPanel 所需的交互反馈类动画 |
| `AnimationGate` | [`AnimationGate.swift`](../Sources/OmniTrans/Utils/AnimationGate.swift) | 声明式门控（基于 UserDefaults） | 仅支持全局开关，无法按场景分级控制 |

### 1.2 性能瓶颈

| 问题 | 影响 | 严重程度 |
|------|------|----------|
| 视图层硬编码动画参数 | 无法统一调优，多处 `.spring(response: 0.35, dampingFraction: 0.65)` | 高 |
| 无帧率监控 | 复杂场景下无法感知掉帧 | 中 |
| `NSAccessibilityDisplayShouldReduceMotion` 仅在 `GlobalAnimationSystem` 中检查 | `AppTheme.Motion` 的 token 不自动降级 | 高 |
| 无 stagger/delay 延迟编排 | 列表入场使用 `DispatchQueue.main.asyncAfter` 手动编排 | 中 |
| 无交互式弹簧 | 所有 spring 使用 `spring(duration:bounce:)` 而非物理模型 `interpolatingSpring` | 低 |
| AppKit ↔ SwiftUI 动画不同步 | `NSAnimationContext` 与 SwiftUI `Animation` 独立运行 | 中 |

### 1.3 可扩展性缺陷

1. **新增动效场景需修改多处**：新 token → `AppTheme.Motion` + 视图层代码 + 无障碍降级逻辑
2. **无缓动曲线库**：仅支持内置 `easeInOut` / `spring`，无法使用 CSS 兼容的自定义 cubic-bezier
3. **无动画阶段概念**：无法描述 "入场 → 稳定 → 退场" 的多阶段动画
4. **无上下文感知**：无法根据视图层级 (Glass/Overlay/HUD/Canvas) 自动选择合适的动画参数

---

## 2. 新架构设计

### 2.1 架构分层

```
┌──────────────────────────────────────────────────────────────────┐
│                    声明式配置层 (Declarative)                      │
│  AnimationToken  │  AnimationPhase  │  AnimationContext          │
│  "什么动画"       │  "何时触发"       │  "什么环境下"               │
├──────────────────────────────────────────────────────────────────┤
│                    参数化配置层 (Configuration)                    │
│  EasingCurve  │  SpringModel  │  DurationScale  │  StaggerConfig │
│  "如何缓动"    │  "弹簧参数"    │  "快慢缩放"      │  "延迟编排"    │
├──────────────────────────────────────────────────────────────────┤
│                    执行引擎层 (Execution)                          │
│  AnimationEngine  │  AnimationGate  │  FrameTracker  │  Logger   │
│  "执行动画"        │  "无障碍门控"    │  "帧率监控"     │  "调试"    │
└──────────────────────────────────────────────────────────────────┘
```

### 2.2 核心类型

#### AnimationToken — 声明式动画配置

```swift
struct AnimationToken: Sendable {
    let name: String                    // e.g. "settings.panel.open"
    let easing: EasingCurve             // 缓动曲线
    let duration: Double                // 基础持续时间
    let scale: DurationScale            // 速度缩放 (fast/normal/slow)
    let spring: SpringModel?            // 物理弹簧（可选）
    let accessibilityFallback: Self?    // 无障碍模式下的替代动画
}
```

#### AnimationPhase — 多阶段编排

```swift
enum AnimationPhase: Sendable {
    case entrance                      // 入场
    case interactive                   // 交互中
    case emphasis                      // 强调反馈
    case exit                          // 退场
}
```

#### EasingCurve — 缓动曲线

```swift
struct EasingCurve: Sendable {
    let c1x, c1y, c2x, c2y: Double   // CSS cubic-bezier 控制点
    // 预设：
    static let standard        = EasingCurve(0.25, 0.1, 0.25, 1.0)   // CSS ease
    static let decelerate      = EasingCurve(0.0, 0.0, 0.2, 1.0)     // 减速
    static let accelerate      = EasingCurve(0.4, 0.0, 1.0, 1.0)     // 加速
    static let sharp           = EasingCurve(0.4, 0.0, 0.6, 1.0)     // 锐利
}
```

#### SpringModel — 物理弹簧

```swift
struct SpringModel: Sendable {
    let mass: Double           // 质量 (default: 1.0)
    let stiffness: Double      // 刚度 (default: 170)
    let damping: Double        // 阻尼 (default: 15)
    let initialVelocity: Double // 初速度 (default: 0)
}
```

### 2.3 统一解析管线

```
用户代码调用
    │
    ▼
AnimationToken 查找 (AppTheme.Motion.xxx)
    │
    ▼
AnimationGate 检查
    ├── reducedMotion → accessibilityFallback
    ├── userDisabled   → .instant
    └── enabled        → 继续
    │
    ▼
DurationScale 应用 (全局速度偏好)
    │
    ▼
SwiftUI Animation / AppKit NSAnimationContext 执行
```

---

## 3. SettingsPanel 动画清单

### 3.1 面板级动画

| 交互 | 阶段 | Token | 描述 |
|------|------|-------|------|
| 窗口打开 | entrance | `windowOpen` | scale 0.92→1.0 + opacity 0→1，0.28s spring |
| 窗口关闭 | exit | `windowClose` | scale 1.0→0.96 + opacity 1→0，0.2s easeIn |
| 窗口聚焦 | emphasis | `windowFocus` | 边框 shader pulse |

### 3.2 标签页切换

| 交互 | 阶段 | Token | 描述 |
|------|------|-------|------|
| 标签点击 | interactive | `tabSelect` | 选中指示器 slide + 文字加粗过渡，0.25s spring |
| 内容区切换 | entrance | `contentCrossfade` | 旧内容 fadeOut 0.15s → 新内容 fadeIn + slideUp 8px，0.25s |

### 3.3 开关类 (Toggle)

| 交互 | 阶段 | Token | 描述 |
|------|------|-------|------|
| Toggle 切换 | interactive | `toggleSwitch` | 系统 switch 自带 + 关联内容区 height transition |
| 关联内容显隐 | entrance/exit | `toggleReveal` | 条件内容 slideDown + opacity，0.25s spring |

### 3.4 滑块类 (Slider)

| 交互 | 阶段 | Token | 描述 |
|------|------|-------|------|
| 滑块拖动 | interactive | `sliderDrag` | 值标签 scale 1.0→1.08→1.0 pulse |
| 滑块释放 | emphasis | `sliderSettle` | 值标签 settle 回原位，0.15s spring |
| 描述文本切换 | interactive | `textCrossfade` | 描述文本 opacity crossfade，0.2s |

### 3.5 按钮类 (Button)

| 交互 | 阶段 | Token | 描述 |
|------|------|-------|------|
| 按钮按下 | interactive | `buttonPress` | scale 1.0→0.96→1.0，0.1s spring |
| 按钮悬停 | interactive | `buttonHover` | 背景色过渡 + 轻微 brightness 变化，0.15s |
| "默认" 按钮 | emphasis | `resetButton` | 轻微 glow pulse，0.3s |

### 3.6 热键录制

| 交互 | 阶段 | Token | 描述 |
|------|------|-------|------|
| 开始录制 | entrance | `recordingStart` | 录制指示器 pulse 呼吸动画 |
| 录制完成 | emphasis | `recordingComplete` | 绿色 flash + scale bounce |
| 取消录制 | exit | `recordingCancel` | 红色 flash + dissolve |

### 3.7 高级选项

| 交互 | 阶段 | Token | 描述 |
|------|------|-------|------|
| 展开 | entrance | `expandReveal` | height expand + opacity fadeIn + slideDown，0.3s spring |
| 折叠 | exit | `expandCollapse` | height collapse + opacity fadeOut，0.2s easeIn |

### 3.8 表单验证

| 交互 | 阶段 | Token | 描述 |
|------|------|-------|------|
| 数值越界 | emphasis | `fieldError` | 输入框边框 shake + 红色 flash |
| 保存成功 | emphasis | `fieldSuccess` | 绿色 check pulse |

### 3.9 About 页面

| 交互 | 阶段 | Token | 描述 |
|------|------|-------|------|
| 图标入场 | entrance | `iconEntrance` | scale 0.8→1.0 + opacity，0.35s spring，delay 0.1s |
| 特性列表 | entrance | `featureStagger` | 每条 staggered slideIn，0.05s 间隔 |
| 按钮悬停 | interactive | `buttonHover` | 下划线 slide |

---

## 4. 无障碍设计标准

### 4.1 强制规则

| 规则 | 实现 |
|------|------|
| `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` | `AnimationEngine.resolve()` 最高优先级返回 `.instant` |
| 用户手动关闭动画 (`animations_enabled` = false) | `AnimationGate` 全局门控 |
| 动画持续时间 ≤ 400ms（WCAG 2.3.3） | 所有 token 的 duration 已在此范围内 |
| 无纯颜色传达信息 | 动画始终伴随 opacity/size/position 变化 |
| 无闪烁频率 > 3Hz | `breathe` token 周期 1.4s = 0.71Hz |

### 4.2 优雅降级策略

```
reducedMotion = true
    ├── entrance/exit  → instant (0s)
    ├── emphasis/pulse → instant
    ├── interactive    → instant
    └── breathe/rotate → instant

userDisabled = true
    ├── 所有 Animation? → nil (SwiftUI 自动硬切)
    └── 所有 NSAnimationContext → duration: 0
```

---

## 5. 性能保障

### 5.1 帧率目标

- 所有动画 60fps 目标
- 使用 SwiftUI `Animation` 而非 `Timer`/`CADisplayLink` 驱动
- 避免 `GeometryReader` 在动画路径中（触发高频布局）
- opacity 和 transform 动画利用 GPU 合成层，避免触发 layout pass

### 5.2 优化策略

| 策略 | 说明 |
|------|------|
| `drawsAsynchronously` | `NSWindow` 开启异步绘制 |
| `canDrawConcurrently` | `NSView` 并发绘制 |
| `CATransaction.setDisableActions(true)` | 主题切换时禁用隐式动画 |
| 避免 `.mask` 和 `.blur` | 这些触发离屏渲染，用 opacity 替代 |
| Stagger 延迟上限 | 总数 × 间隔 ≤ 0.5s，避免用户等待 |

### 5.3 帧率监控 (FrameTracker)

```swift
actor FrameTracker {
    func reportFrame(duration: CFTimeInterval)   // Metal 回调
    var currentFPS: Int { get }
    var isThrottling: Bool { get }               // < 45fps → true

    func adaptiveQuality() -> DurationScale {
        if isThrottling { return .fast }          // 自动加速以维持帧率
        return .normal
    }
}
```

---

## 6. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `docs/animation-architecture.md` | 新建 | 本架构方案文档 |
| `Sources/OmniTrans/Utils/AnimationSystem.swift` | 重写 | 统一动画引擎核心（AnimationToken、EasingCurve、SpringModel、AnimationEngine） |
| `Sources/OmniTrans/Utils/AnimationGate.swift` | 增强 | 增加 per-token 门控、stagger 编排器 |
| `Sources/OmniTrans/Utils/AppTheme+Motion.swift` | 重写 | 扩展为完整的 SettingsPanel 语义 token 集 |
| `Sources/OmniTrans/Utils/AppTheme.swift` | 微调 | 增加动画相关 View extension |
| `Sources/OmniTrans/Utils/ThemeEngine.swift` | 增强 | 集成动画系统配置 |
| `Sources/OmniTrans/Views/SettingsPanelContent.swift` | 重写 | 全面集成动画 |
| `Sources/OmniTrans/Services/SettingsWindowManager.swift` | 增强 | 窗口打开/关闭动画 |
| `Sources/OmniTrans/Services/SettingsPanel.swift` | 微调 | 面板层级动画支持 |
