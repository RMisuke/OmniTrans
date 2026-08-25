# 多屏 OCR 取词坐标系统修复

> 版本: v0.9+ | 平台: macOS 14+（macOS 27 已验证）| 相关模块: OCR / ScreenCaptureKit / DisplayGeometry

---

## 1. 问题现象

内置显示器上 OCR 取词正常；**外接显示器位于主屏上方、下方、左侧、右侧任意方向时**，
无法识别或识别区域出现偏移，经常取不到文字。

---

## 2. 根因分析

macOS 存在三套屏幕坐标系，本项目 OCR 两条路径此前在其中**混用**：

| 坐标系 | 来源 | 原点 | Y 方向 |
|---|---|---|---|
| AppKit 全局 | `NSScreen.frame` / `NSEvent.mouseLocation` / `NSWindow.frame` | 主屏 **bottom-left** | 向上 |
| CG 全局 | `CGDisplayBounds` / `SCDisplay.frame` | 主屏 **top-left** | 向下 |
| display-local | `SCStreamConfiguration.sourceRect` | 目标屏 **top-left** | 向下 |

### Bug A（框选 OCR 路径，[`CaptureService.swift`](Sources/OmniTrans/Services/CaptureService.swift)）

`SCDisplay.frame`（top-left）与 `NSScreen.frame`（bottom-left）的 Y 语义相反。
原代码用 **AppKit 坐标**的 `midPoint` 对 **CG 坐标**的 `SCDisplay.frame` 做 `contains`，
多屏下必然失配，落入 `content.displays.first` 兜底 → **永远选中主屏**；随后却用
外接屏的 `NSScreen` 计算 sourceRect，取图区域与目标屏不一致 → 取不到字/取错区域。
单屏时两个坐标系 Y 范围恰好都是 `[0, screenHeight]`，`contains` "碰巧"命中，故内屏正常。

### Bug B/C（鼠标悬停 OCR 路径，[`TextCaptureStrategies.swift`](Sources/OmniTrans/Services/TextCaptureStrategies.swift)）

- `tryCapture()` 用 `cgScreenHeight - mouse.y` 把鼠标坐标翻成 CG 坐标，**假设所有屏幕
  底部对齐于全局 y=0**（依赖主屏布局的硬编码假设），外接屏在上/下/左/右时失配。
- `captureScreen(rect:)` 接收 **CG 坐标** rect，却用 `NSScreen.frame.contains()`（bottom-left）
  选屏，且 `rect.y - screenFrame.y` 是**跨坐标系直接相减**（X 可减、Y 必须翻转）
  → `localCGY` 垂直偏移。

### Bug D（缩放因子）

`config.width/height = Int(sourceRect.width * backingScaleFactor)` 硬乘 `NSScreen.backingScaleFactor`，
在缩放布局 / 混合缩放率下可能与 SCK 输出不一致，且 `Int()` 截断引入 1px 输出偏移。

### Bug E（代码重复）

两处坐标转换逻辑重复且注释与实现自相矛盾，极易再次分叉。

---

## 3. 修复方案：统一坐标转换层

新增独立库 target **`DisplayGeometry`**（[`Sources/DisplayGeometry/DisplayGeometry.swift`](Sources/DisplayGeometry/DisplayGeometry.swift)），
作为全应用**唯一的跨坐标系换算出口**：

1. **屏幕选择不再依赖主屏**：`screen(containing:)` / `nearestScreen(to:)` 用 AppKit 坐标
   匹配 `NSScreen.frame`，点落在屏间间隙时按最小平方距离取最近屏。
2. **displayID 精确关联**：`displayID(for:)` 从 `NSScreenNumber` 取 `CGDirectDisplayID`，
   `scDisplay(in:matching:)` 在 `SCShareableContent` 中按 ID 精确查找 `SCDisplay` ——
   彻底替代 `SCDisplay.frame.contains()` 这类跨坐标系判断。
3. **AppKit 全局 → display-local**：`displayLocalSourceRect(forAppKitGlobal:screenFrame:)`
   在单个屏幕 frame 内完成 Y-flip，兼容负坐标、任意排列方向、混合分辨率/缩放率：
   ```
   localX       = rect.minX - screenFrame.minX
   localBottomY = rect.minY - screenFrame.minY
   localTopY    = screenFrame.height - localBottomY - rect.height
   ```
4. **缩放因子动态化**：`scaleFactor(for:screen:)` 用 `SCDisplay.width / SCDisplay.frame.width`
   （物理像素/逻辑点，与 SCK 输出严格一致），回退 `NSScreen.backingScaleFactor`；
   `outputPixelSize` 四舍五入并钳制 ≥1。
5. **Vision 归一化 → 屏幕坐标**：`appKitGlobalRect(fromVisionNormalized:within:)` 把
   `VNRecognizedTextObservation.boundingBox`（origin 左下、y 向上、0~1）映射为 AppKit 全局
   rect；`windowLocalRect` 再转为目标窗口局部坐标（供原位替换/区域定位）。scale 在推导中
   约去，映射与捕获像素尺寸无关。
6. **诊断**：`describe(screen:display:)` 输出各屏几何；`DisplayLayoutDebug.dump()` 输出完整
   显示拓扑与 NSScreen↔SCDisplay 关联结果。

---

## 4. 修改文件清单

| 文件 | 改动点 |
|---|---|
| [`Sources/DisplayGeometry/DisplayGeometry.swift`](Sources/DisplayGeometry/DisplayGeometry.swift)（新增） | 坐标互转、displayID 关联、display-local sourceRect、scale 动态化、Vision 映射、诊断工具 |
| [`Package.swift`](Package.swift) | 新增 `DisplayGeometry` 库 target + `DisplayGeometryTests` 测试 target；OmniTrans 依赖 `DisplayGeometry` |
| [`Sources/OmniTrans/Services/CaptureService.swift`](Sources/OmniTrans/Services/CaptureService.swift) | 用 displayID 关联选 display；统一走 DisplayGeometry；删除 `Int(sourceRect.width * scale)` 硬乘 |
| [`Sources/OmniTrans/Services/TextCaptureStrategies.swift`](Sources/OmniTrans/Services/TextCaptureStrategies.swift) | `tryCapture` 不再翻转为 CG 坐标；`captureScreen(appKitRect:)` 复用 DisplayGeometry |
| [`Sources/OmniTrans/Services/OCRSelectionOverlay.swift`](Sources/OmniTrans/Services/OCRSelectionOverlay.swift) | 新增 `OCRResult`/`OCRLineResult`；`performOCR` 返回文本+区域坐标；`beginCapture` 用 DisplayGeometry 选屏；sizeLabel 跟随外接屏缩放 |
| [`Sources/OmniTrans/App.swift`](Sources/OmniTrans/App.swift) | `startOCRSelection` 适配 `OCRResult`；启动时调用 `DisplayLayoutDebug.dump()` |
| [`Tests/DisplayGeometryTests/DisplayGeometryTests.swift`](Tests/DisplayGeometryTests/DisplayGeometryTests.swift)（新增） | 12 个坐标转换单元测试 |

---

## 5. 测试方案

### 5.1 单元测试（`swift test`，已全部通过 ✅）

覆盖场景：

| 测试 | 场景 |
|---|---|
| `testExternalOnRight` | 外接屏在右侧 |
| `testExternalOnLeft` | 外接屏在左侧（负 X 坐标） |
| `testExternalAbove` | 外接屏在主屏上方（Y > 主屏高） |
| `testExternalBelow` | 外接屏在主屏下方（负 Y 坐标） |
| `testDualExternal` | 主屏 + 右侧 + 上方双外接、混合分辨率 |
| `testOutputPixelSize` | 缩放因子 1x / 1.5x / 2x 输出像素 |
| `testAppKitToCGConversion` | AppKit ↔ CG 全局互转 |
| `testVisionNormalizedToAppKit` / `testVisionNormalizedAcrossLayouts` | Vision 归一化 → 屏幕坐标映射 |
| `testWindowLocalRect` | AppKit 全局 → 窗口局部 |
| `testSquaredDistance` | 最近屏选择（替代 NSScreen.main） |
| `testRoundTripWithinMainScreen` | 单屏回归基线 |

### 5.2 集成验证（真实多屏硬件）

1. **启动诊断**：运行 App，查看控制台 `[DisplayLayout]` 输出。确认
   - 各屏 `NSScreen.frame`（bottom-left）与 `SCDisplay.frame`（top-left）正确；
   - 每块屏 `NSScreen ↔ SCDisplay 关联` 均为 `✅ matched`（按 CGDirectDisplayID）。
2. **外接屏四方向逐一验证**：在 系统设置 → 显示器 → 排列 中，把外接屏依次放在主屏
   **上方 / 下方 / 左侧 / 右侧**，每次：
   - 在外接屏上框选一段文字 → 确认 OCR 结果精确；
   - 观察 `[OCR] 📺 ...` 日志中选中屏的 `id`/`frame` 与外接屏一致，`Capturing region` 在
     display-local 范围内。
3. **混合缩放率**：主屏（如 2x Retina）与外接屏（如 1x / 缩放布局 1.5x）混用，重复上述验证。
4. **双外接**：同时接两块外接屏（左右 + 上方等组合），逐一验证每块屏取词。
5. **区域坐标映射**：框选后，`OCRResult.lines` 携带每行文字的 `appKitFrame`
   （AppKit 全局 bottom-left）；用 `DisplayGeometry.windowLocalRect` 转目标窗口局部坐标，
   可用于后续原位替换 / 区域定位。

---

## 6. 关键约定（防止回归）

- **一律用 AppKit 坐标（bottom-left）做所有「选择/框选」逻辑**，只有构造
  `SCStreamConfiguration` / `SCContentFilter` 时才转为 display-local。
- **选屏用 `NSScreen.frame`（AppKit）匹配，选 display 用 `CGDirectDisplayID` 关联**，
  禁止 `SCDisplay.frame.contains(appKitPoint)`。
- **不要直接手写 Y-flip 与缩放乘法**，统一走 `DisplayGeometry`。
