# AiTranslator 修复记录

> 项目：AiTranslator (AI 翻译)  
> 平台：macOS 14+  
> 版本：0.2  |  更新日期：2026-07-01

---

## #1 2026-06-30 — Gemini API Key 通过 URL 泄露

**严重度**：🔴 安全  
**文件**：`TranslationService.swift`、`APITestService.swift`  
**影响**：Gemini API Key 出现在 URL 查询参数中，可能被代理日志、服务器日志、网络监控记录

### 问题描述

4 处 Gemini API 调用将 API Key 作为 URL 查询参数 `?key=...` 传递：
- `TranslationService`: 流式 + 非流式 (2 处)
- `APITestService`: 模型列表拉取 + 连接测试 (2 处)

### 修复内容

移除 URL 中的 `?key=` / `&key=` 参数，改为 HTTP 请求头 `x-goog-api-key`。

### 修改文件

| 文件 | 修改 |
|------|------|
| `TranslationService.swift` | `:generateContent?key=` → `:generateContent` + header |
| `TranslationService.swift` | `:streamGenerateContent?alt=sse&key=` → `:streamGenerateContent?alt=sse` + header |
| `APITestService.swift` | `/models?key=` → `/models` + header |
| `APITestService.swift` | `/models?key=` → `/models` + header |

---

## #2 2026-06-30 — AXUIElement force cast 崩溃风险

**严重度**：🔴 崩溃  
**文件**：`HotkeyManager.swift`  
**影响**：AX API 返回非预期类型时 App 崩溃

### 问题描述

`captureViaAX()` 中使用 `as! AXUIElement` 强制类型转换，若 AX API 返回非 AXUIElement 类型对象则 crash。

### 修复内容

使用 `CFGetTypeID()` 进行运行时类型校验后再 `as!`。

### 修改文件

| 文件 | 修改 |
|------|------|
| `HotkeyManager.swift` | `app as! AXUIElement` → `CFGetTypeID(appRef) == AXUIElementGetTypeID()` 校验 |

---

## #3 2026-06-30 — stream_options 兼容性问题

**严重度**：🟡 功能  
**文件**：`TranslationService.swift`  
**影响**：使用 DeepSeek / Ollama / 硅基流动等兼容 API 时流式翻译失败

### 问题描述

OpenAI 流式请求 body 中包含 `"stream_options": ["include_usage": true]`，该字段不被大多数 OpenAI 兼容 API 支持，导致请求被拒绝。

### 修复内容

移除 `stream_options` 字段。token 用量统计可通过非流式回退或响应头获取。

### 修改文件

| 文件 | 修改 |
|------|------|
| `TranslationService.swift` | 删除 `stream_options` 行 |

---

## #4 2026-06-30 — 版本号不一致

**严重度**：🟡 维护  
**文件**：`AppState.swift`、`build.sh`  
**影响**：代码中声明 v2.0，Info.plist 写 1.0

### 修复内容

统一为 `0.1` 开发版。

### 修改文件

| 文件 | 修改 |
|------|------|
| `AppState.swift` | `kAppVersion = "2.0"` → `"0.1"` |
| `build.sh` | Info.plist `CFBundleVersion` / `CFBundleShortVersionString` → `0.1` |

---

## #5 2026-06-30 — 重试条件过窄

**严重度**：🟡 功能  
**文件**：`AppState.swift`  
**影响**：英文网络错误信息不会被自动重试

### 问题描述

自动重试条件仅匹配中文「网络」关键词，英文网络错误（network/timeout/connection…）不触发重试。

### 修复内容

扩展重试匹配关键词为：`网络` / `network` / `timeout` / `connection` / `offline` / `unreachable`（不区分大小写）。

### 修改文件

| 文件 | 修改 |
|------|------|
| `AppState.swift` | 重试条件从单关键词 `contains("网络")` → 多关键词 `isNetworkError` |

---

## #6 2026-06-30 — 剪贴板恢复非原子操作

**严重度**：🟡 健壮性  
**文件**：`HotkeyManager.swift`  
**影响**：划词取词过程中如发生崩溃，用户剪贴板内容永久丢失

### 问题描述

`captureViaSimulatedCopy()` 先保存剪贴板内容 → 模拟 Cmd+C → 清空剪贴板 → 恢复原始内容。如果中间步骤发生崩溃，恢复代码不执行。

### 修复内容

使用 `defer` 块包裹恢复逻辑，确保无论函数正常返回还是异常退出，剪贴板内容都被恢复。

### 修改文件

| 文件 | 修改 |
|------|------|
| `HotkeyManager.swift` | 剪贴板恢复代码移入 `defer` 块 |

---

## #7 2026-06-30 — 删除按钮手势冲突

**严重度**：🟡 Bug  
**文件**：`ProviderCardView.swift`  
**影响**：点击删除按钮偶尔触发编辑模式而非删除确认

### 问题描述

删除按钮和卡片 `onTapGesture` 手势区域重叠，点击事件可能被卡片手势先捕获。

### 修复内容

删除按钮增加二次确认机制：首次点击进入确认态（红色），4 秒自动取消；再次点击执行删除。

### 修改文件

| 文件 | 修改 |
|------|------|
| `ProviderCardView.swift` | 删除按钮二段确认 + 4 秒自动取消 |

---

## #8 2026-06-30 — Keychain 懒加载

**严重度**：🟡 体验  
**文件**：`AppState.swift`、`ProviderCardView.swift`  
**影响**：已禁用的 API 提供商的 Key 未加载到内存

### 问题描述

`AppState.load()` 只加载已启用的 provider 的 Keychain key，禁用 provider 的 key 丢失。

### 修复内容

`ensureKey(for:)` 方法按需从 Keychain 加载任意 provider 的 key。

### 修改文件

| 文件 | 修改 |
|------|------|
| `AppState.swift` | `ensureKey(for:)` 懒加载 |
| `ProviderCardView.swift` | `onLoadKey` 回调串联 |

---

## #9 2026-06-30 — ad-hoc 签名 + quarantine 清除

**严重度**：🟡 分发  
**文件**：`build.sh`  
**影响**：未签名的 .app 在其他 Mac 上显示「已损坏，无法打开」

### 修复内容

`build.sh` 末尾新增 `codesign --force --deep --sign -` ad-hoc 签名 + `xattr -cr` 清除 quarantine 属性。

### 修改文件

| 文件 | 修改 |
|------|------|
| `build.sh` | 新增 codesign + xattr 步骤 |

---

## #10 2026-06-30 — 剪贴板监听缺少去抖

**严重度**：🟡 体验  
**文件**：`ClipboardMonitor.swift`  
**影响**：快速连续复制时触发多次重复翻译请求

### 问题描述

`ClipboardMonitor` 每秒轮询剪贴板，检测到文本变化即触发翻译，无最小间隔保护。

### 修复内容

新增 `lastTranslationTime` 属性，翻译触发前检查距上次翻译是否超过 2 秒。

### 修改文件

| 文件 | 修改 |
|------|------|
| `ClipboardMonitor.swift` | 新增 `lastTranslationTime` + 2 秒去抖判断 |

---

## #11 2026-06-30 — v0.2 快捷键闪退崩溃 (Critical regression)

**严重度**：🔴 崩溃  
**文件**：`HotkeyManager.swift`、`AppState.swift`  
**影响**：按下快捷键立即闪退，v0.2 首个 regression  
**定位方法**：二分法 — 逐步回退 v0.2 改动至 v0.1 基线

### 根因分析

经过二分法诊断，共发现两个崩溃点：

**崩溃点 1：NSPasteboardItem 手动重建**
v0.2 将剪贴板恢复从 `readObjects(forClasses:)` + `setString()` 改为手动构建 `NSPasteboardItem` + `writeObjects()`。对于非标准类型（文件引用、自定义 UTI），`setData(_:forType:)` 类型不兼容导致底层崩溃。

**崩溃点 2：Coordinator 观察桥接模式**
v0.2 将 AppState 从单体改为 Coordinator（委托 SettingsStore / HistoryStore / TranslationContext），通过 AsyncTask / Combine 桥接 `objectWillChange`。ObservableObject 跨层转发 `@Published` 时，SwiftUI 依赖追踪在计算属性链中失效，主线程同步时序异常导致闪退。

### 修复内容

回退 v0.2 改动至 v0.1 单体架构作为基线。

### 修改文件

| 文件 | 修改 |
|------|------|
| `HotkeyManager.swift` | NSPasteboardItem 回退为 readObjects + setString |
| `AppState.swift` | 移除 Coordinator / SettingsStore 依赖，恢复单体模式 |

---

## #12 2026-07-01 — 自定义快捷键录制 + 一键还原默认

**严重度**：✨ 功能增强  
**文件**：`HotkeyManager.swift`、`SettingsView.swift`  
**影响**：原通用设置页快捷键只读不可改

### 实现内容

**HotkeyManager.swift：**
- 新增 `reregister(carbonKey:carbonMods:)` — 注销旧热键 → 写入 UserDefaults → 注册新热键
- 新增 `resetToDefault()` — 一键还原 Option+D
- 新增 `carbonMods(from:)` — NSEvent modifierFlags → Carbon 修饰键掩码
- 新增 `hotkeyLabelFrom(carbonKey:carbonMods:)` — Carbon 键值 → 显示字符串
- 扩展 `keyToString()` 键码映射表 (40+ 键)

**SettingsView.swift：**
- 新增「录制新快捷键」按钮 → `NSEvent.addLocalMonitorForEvents(.keyDown)` 捕获按键
- 录制中实时显示键帽 + ProgressView 动画
- 要求至少一个修饰键（⌘/⌥/⌃/⇧）
- 录制成功 → 0.3s 后自动停止 + 保存
- 新增「还原默认 (⌥D)」按钮

### 修改文件

| 文件 | 修改 |
|------|------|
| `HotkeyManager.swift` | `reregister()` / `resetToDefault()` / `carbonMods()` / `hotkeyLabelFrom()` / 键码表扩展 |
| `SettingsView.swift` | 录制 UI 组件 / `startRecording()` / `handleRecordedKey()` / keycap 组件 |

---

## #13 2026-07-01 — 通用设置控件 UI 不刷新

**严重度**：🟡 Bug  
**文件**：`SettingsView.swift`  
**影响**：点击 ESC 关闭方式 / Cmd+C 翻译 / 还原快捷键后 UI 不变，重开窗口才看到更新

### 问题描述

三个控件使用 `Binding(get:set:)` 直读直写 `UserDefaults`，SwiftUI 状态追踪无法感知变化。

### 修复内容

| 控件 | 修复前 | 修复后 |
|------|------|------|
| ESC 关闭方式 | `Binding(UserDefaults)` | `@AppStorage("dismiss_mode")` |
| Cmd+C 翻译 | `Binding(UserDefaults)` + 手动 save | `@AppStorage("clipboard_monitor")` + `.onChange` |
| 还原快捷键 | 调用后不触发刷新 | 追加 `.id(shortcutRefreshToggle)` 强制重绘 |

### 修改文件

| 文件 | 修改 |
|------|------|
| `SettingsView.swift` | 三个控件改为 `@AppStorage` + `shortcutRefreshToggle` |

---

## #14 2026-07-01 — 应用图标 + 关于界面大 icon

**严重度**：✨ 功能增强  
**文件**：`build.sh`、`SettingsView.swift`  
**影响**：原 .app 无图标、关于界面用 SF Symbol 占位

### 实现内容

- `build.sh`：打包时复制 `icon v0.1.icns` → `Contents/Resources/icon.icns`
- `Info.plist`：添加 `CFBundleIconFile` = `icon.icns`
- 关于界面：优先加载 `.icns`，回退 `.png`，再回退 SF Symbol
- 图标 80×80 圆角 18pt 裁剪显示

### 修改文件

| 文件 | 修改 |
|------|------|
| `build.sh` | icon 复制 + Info.plist `CFBundleIconFile` |
| `SettingsView.swift` | About 页面 icon 加载逻辑 |

---

## #15 2026-07-01 — API 模板选择导致窗口关闭

**严重度**：🟡 Bug  
**文件**：`SettingsView.swift`  
**影响**：点击模板后 MenuBarExtra 窗口消失，需重新点开

### 问题描述

模板选择用 `.sheet(isPresented:)` 弹窗。在 MenuBarExtra 窗口上 dismiss sheet 时，macOS 会将父窗口一同 orderOut。

### 修复内容

模板页内嵌至 API 配置页，原地切换替代 sheet 弹出。

### 修改文件

| 文件 | 修改 |
|------|------|
| `SettingsView.swift` | 移除 `.sheet`，内嵌 `showTemplates` 条件分支 |

---

## #16 2026-07-01 — 删除冗余代码精简包体积

**严重度**：🟡 维护  
**文件**：多个  
**影响**：未使用的 Store 文件、重复代码增加二进制体积

### 问题描述

- `Stores/HistoryStore.swift`、`SettingsStore.swift`、`TranslationContext.swift` 完整实现但从未被引用
- `TranslationService.swift` 中 ~180 行流式方法从未被调用，所有流式通过 `TranslationActor`
- 流式响应类型在 `TranslationService` 和 `TranslationActor` 中重复定义
- `AppDelegate.showFloatingPanel` 与 `fire()` 面板初始化代码重复
- `build.sh` Info.plist 版本号 0.1 与 `kAppVersion = "0.2"` 不一致

### 修复内容

| 文件 | 修改 |
|------|------|
| `Stores/HistoryStore.swift` | 删除（~50 行） |
| `Stores/SettingsStore.swift` | 删除（~80 行） |
| `Stores/TranslationContext.swift` | 删除（~40 行） |
| `TranslationService.swift` | 删除未使用流式方法及 3 个流式响应类型（~180 行） |
| `App.swift` | `showFloatingPanel()` / `fire()` 去重合并，`resetForNew` 双重调用修复 |
| `build.sh` | `CFBundleVersion` 0.1 → 0.2 |

---

## #17 2026-07-01 — 首次启动引导窗口

**严重度**：✨ 功能增强  
**文件**：`OnboardingView.swift`（新建）、`App.swift`  
**影响**：新用户不清楚如何配置权限和使用

### 实现内容

3 页引导窗口（560×640），首次启动延迟 0.6s 弹出：

| 页 | 内容 |
|---|------|
| 1 | 辅助功能 + 屏幕录制权限，附带直达系统设置链接 |
| 2 | 钥匙串加密、仅本地使用、Touch ID 授权说明 |
| 3 | 快捷键翻译、剪贴板监听、OCR 框选、API 配置、悬浮窗操作 |

← → 方向键翻页，⌘↩ 完成。`UserDefaults` 标记 `has_completed_onboarding`。

### 修改文件

| 文件 | 修改 |
|------|------|
| `Views/OnboardingView.swift` | 新建 (~230 行) |
| `App.swift` | `onboardingWindow` + `showOnboardingIfNeeded()` + `dismissOnboarding()` |

---

## #18 2026-07-01 — 引导窗口仅手动翻到最后一页才消失

**严重度**：🟡 体验  
**文件**：`OnboardingView.swift`、`App.swift`  
**影响**：关闭窗口即标记完成，用户可能错过后续内容

### 修复内容

移除 `windowWillClose` 自动标记完成。仅在翻到第 3 页并点击「开始使用」时写入 `has_completed_onboarding`。手动关闭窗口 → 下次启动仍弹出。

### 修改文件

| 文件 | 修改 |
|------|------|
| `App.swift` | 移除 `NSWindowDelegate` / `windowWillClose` |
| `OnboardingView.swift` | 「开始使用」按钮仅调用 `onDismiss()` |

---

## #19 2026-07-01 — 关于页面增加重置引导标记按钮

**严重度**：✨ 功能增强（开发测试）  
**文件**：`SettingsView.swift`  
**影响**：开发期间无法重复测试引导窗口

### 实现内容

关于页面底部新增「重置首次启动引导」按钮，点击清除 `has_completed_onboarding` 标记。

### 修改文件

| 文件 | 修改 |
|------|------|
| `SettingsView.swift` | aboutTab 新增重置按钮 |

---

## #20 2026-07-01 — OCR 取词优化：自适应多档 + 空间排序

**严重度**：🟡 功能  
**文件**：`HotkeyManager.swift`  
**影响**：原 OCR 固定 400×100 区域，无空间排序，多行文本识别混乱

### 实现内容

- **三档自适应**：240×50 (置信度 0.35) → 400×90 (0.25) → 560×140 (0.15)
- **空间排序**：`boundingBox` 按 Y 分组（容差 3%）→ 行内按 X 从左到右
- **去重**：相邻相同 token 自动合并
- **噪声过滤**：`minimumTextHeight = 0.02`

### 修改文件

| 文件 | 修改 |
|------|------|
| `HotkeyManager.swift` | 重写 `captureViaVisionOCR()` |

---

## #21 2026-07-01 — OCR 框选取词（⌥F 独立热键）

**严重度**：✨ 功能增强  
**文件**：`OCRSelectionOverlay.swift`（新建）、`HotkeyManager.swift`、`App.swift`、`ContentView.swift`、`OnboardingView.swift`  
**影响**：原 OCR 仅作为划词失败回退，无独立触发方式

### 实现内容

- **⌥F 热键**：`HotkeyManager` 第二个热键注册/注销 + 独立 C 回调
- **框选 overlay**：全屏半透明遮罩 → 鼠标拖拽画蓝色选框 + 尺寸标签
- **OCR + 翻译**：松开鼠标自动 OCR → 弹出翻译悬浮窗
- **Esc 取消**
- 底部栏和引导窗口新增 ⌥F 提示

### 修改文件

| 文件 | 修改 |
|------|------|
| `Services/OCRSelectionOverlay.swift` | 新建 |
| `Services/HotkeyManager.swift` | `registerOCR()` / `unregisterOCR()` / `onOCRHotkey` / C 回调 |
| `App.swift` | `startOCRSelection()` 串联 overlay → OCR → 翻译 |
| `Views/ContentView.swift` | 底部栏新增 ⌥F 提示 |
| `Views/OnboardingView.swift` | 使用指南新增 OCR 框选说明 |

---

## #22 2026-07-01 — OCR 坐标系 Y 轴翻转 bug

**严重度**：🔴 Bug  
**文件**：`OCRSelectionOverlay.swift`  
**影响**：框选区域与实际 OCR 区域上下颠倒

### 问题描述

`CGWindowListCreateImage` 使用左上角原点，AppKit 使用左下角原点。坐标未转换导致 Y 轴翻转。

### 修复内容

```swift
cgY = maxScreenY - (appKitY + viewHeight)
```

多屏幕场景用 `NSScreen.screens.map(\.frame.maxY).max()` 获取全局高度做翻转基准。OCR 结果用 `boundingBox` 归一化坐标按 Y（行）→ X（列）排序。

### 修改文件

| 文件 | 修改 |
|------|------|
| `OCRSelectionOverlay.swift` | 坐标系转换 + 空间排序 |

---

## #23 2026-07-01 — OCR 标签干扰 + 引导窗口尺寸 + 程序关闭

**严重度**：🟡 Bug  
**文件**：`OCRSelectionOverlay.swift`、`OnboardingView.swift`、`App.swift`  

### 问题与修复

| 问题 | 修复 |
|------|------|
| 选框尺寸标签被 OCR 识别 | `CGWindowListCreateImage(.optionOnScreenBelowWindow)` 排除遮罩窗口 |
| 引导第三页内容溢出 | 页面 `minHeight` 400→460→520，窗口 560×580→560×640 |
| 引导窗关闭后程序退出 | `applicationShouldTerminateAfterLastWindowClosed → false` + `NSApp.activate` |

### 修改文件

| 文件 | 修改 |
|------|------|
| `OCRSelectionOverlay.swift` | `_overlayWindowID` + capture 排除自身 |
| `OnboardingView.swift` | 页面高度递增 |
| `App.swift` | 窗口放大 + 防退出 |

---

## #24 2026-07-01 — OCR 快捷键自定义

**严重度**：✨ 功能增强  
**文件**：`HotkeyManager.swift`、`SettingsView.swift`、`ContentView.swift`、`OnboardingView.swift`、`AppState.swift`  
**影响**：OCR 热键硬编码为 ⌥F，无法自定义

### 实现内容

- `HotkeyManager`：新增 `ocrHotkeyLabel()`、`reregisterOCR()`、`resetOCRToDefault()`，OCR 热键读/写 UserDefaults
- `SettingsView`：快捷键区域分为「划词翻译」和「OCR 框选」两个独立录制区，各带还原默认按钮
- 底部栏和引导窗口 OCR 快捷键动态跟随自定义值

### 修改文件

| 文件 | 修改 |
|------|------|
| `HotkeyManager.swift` | OCR 热键持久化 + `ocrHotkeyLabel()` / `reregisterOCR()` / `resetOCRToDefault()` |
| `SettingsView.swift` | 双热键录制 UI + 标签区分 |
| `ContentView.swift` | `ocrKeycapView` 动态键帽 |
| `OnboardingView.swift` | OCR 快捷键文本动态化 |
| `AppState.swift` | OCR 热键默认值初始化 |

---

## #25 2026-07-01 — 双热键事件冲突

**严重度**：🔴 Bug  
**文件**：`HotkeyManager.swift`、`App.swift`  
**影响**：⌥D + ⌥F 互相干扰，按一个触发另一个

### 问题与修复

| 问题 | 修复 |
|------|------|
| `unregister()` 内部调用 `unregisterOCR()`，自定义翻译热键时 OCR 被误杀 | 解耦两个 unregister 方法 |
| 两个 `InstallEventHandler` 监听同一事件，按键触发两个回调 | 改为单一 `unifiedHotkeyCallback`，读 `EventHotKeyID` 分发 |
| `GetEventParameter` bufferSize 传 0 导致 ID 读取失败 | 改为 `MemoryLayout<EventHotKeyID>.size` |

### 修改文件

| 文件 | 修改 |
|------|------|
| `HotkeyManager.swift` | 解耦 unregister、统一回调 + EventHotKeyID 分发 |
| `App.swift` | `applicationWillTerminate` 分别调用两个 unregister |

---

## #26 2026-07-01 — 翻译历史最大记录数可配置

**严重度**：✨ 功能增强  
**文件**：`AppState.swift`、`SettingsView.swift`  
**影响**：历史记录硬编码上限 50 条

### 实现内容

设置 → 通用新增「翻译历史」区块：输入框 + Stepper，范围 10–500，默认 100。`AppState.addHistory` 从 UserDefaults 读取上限。

### 修改文件

| 文件 | 修改 |
|------|------|
| `AppState.swift` | 硬编码 50 → `UserDefaults.integer("max_history_count")` |
| `SettingsView.swift` | 输入框 + Stepper + 范围校验 |

---

## #27 2026-07-01 — 关于页面导航栏上移

**严重度**：🟡 Bug  
**文件**：`SettingsView.swift`  
**影响**：切换到关于页时导航栏被顶上移

### 问题描述

`aboutTab` 使用 `Spacer()` + `maxHeight: .infinity` 撑满空间，内容多时挤压顶部导航栏。

### 修复内容

移除顶部 `Spacer()`，外包 `ScrollView`，内容自然从顶部排列。

### 修改文件

| 文件 | 修改 |
|------|------|
| `SettingsView.swift` | aboutTab 布局改为 ScrollView |

---

## #28 2026-07-01 — 翻译热键误触发 OCR

**严重度**：🟡 Bug  
**文件**：`HotkeyManager.swift`  
**影响**：⌥D 划词翻译时调用了 OCR 取词而非选中文本

### 问题描述

`capture()` 三级回退：Cmd+C → AX → OCR。当 Cmd+C 和 AX 都失败时 fallback 到 OCR，导致翻译热键也走 OCR 通道。

### 修复内容

`capture()` 移除 OCR 回退。翻译热键仅使用 Cmd+C + AX。OCR 由 ⌥F 独立触发。

### 修改文件

| 文件 | 修改 |
|------|------|
| `HotkeyManager.swift` | `capture()` 移除 OCR fallback，统一回调改用 `captureWithoutOCR()` |

---

## 修复统计

| 分类 | 数量 | 条目 |
|------|------|------|
| 🔴 安全 | 2 | #1 Gemini API Key 泄露、URL force unwrap |
| 🔴 崩溃 | 2 | #2 AXUIElement force cast、#11 v0.2 闪退 regression |
| 🔴 Bug | 2 | #22 OCR 坐标系 Y 轴翻转、#25 双热键事件冲突 |
| 🟡 功能 | 4 | #3 stream_options、#5 重试条件、#10 剪贴板去抖、#20 OCR 自适应多档 |
| 🟡 Bug | 6 | #7 删除按钮手势冲突、#13 设置 UI 不刷新、#15 模板选择窗口关闭、#23 OCR 标签/尺寸/退出、#27 关于页布局、#28 翻译热键误触发 OCR |
| 🟡 健壮性 | 1 | #6 剪贴板恢复非原子 |
| 🟡 体验 | 3 | #8 Keychain 懒加载、#18 引导手动翻页、#23 引导尺寸 |
| 🟡 维护 | 2 | #4 版本号统一、#16 冗余代码精简 |
| 🟡 分发 | 1 | #9 ad-hoc 签名 + quarantine |
| ✨ 功能增强 | 7 | #12 快捷键录制、#14 应用图标、#17 首次启动引导、#19 重置引导标记、#21 OCR 框选取词、#24 OCR 快捷键自定义、#26 历史记录上限 |
| **合计** | **30** | |

| 分类 | 数量 | 条目 |
|------|------|------|
| 🔴 安全 | 2 | #1 Gemini API Key 泄露、URL force unwrap |
| 🔴 崩溃 | 2 | #2 AXUIElement force cast、#11 v0.2 闪退 regression |
| 🔴 Bug | 1 | #22 OCR 坐标系 Y 轴翻转 |
| 🟡 功能 | 4 | #3 stream_options、#5 重试条件、#10 剪贴板去抖、#20 OCR 自适应多档 |
| 🟡 Bug | 4 | #7 删除按钮手势冲突、#13 设置 UI 不刷新、#15 模板选择窗口关闭、#23 OCR 标签/尺寸/退出 |
| 🟡 健壮性 | 1 | #6 剪贴板恢复非原子 |
| 🟡 体验 | 3 | #8 Keychain 懒加载、#18 引导手动翻页、#23 引导尺寸 |
| 🟡 维护 | 2 | #4 版本号统一、#16 冗余代码精简 |
| 🟡 分发 | 1 | #9 ad-hoc 签名 + quarantine |
| ✨ 功能增强 | 5 | #12 快捷键录制、#14 应用图标、#17 首次启动引导、#19 重置引导标记、#21 OCR 框选取词 |
| **合计** | **25** | |

---

## #29 2026-07-01 — V0.3 架构重构：0% CPU 剪贴板静默监控

**严重度**：🟡 性能  
**文件**：`ClipboardMonitor.swift`  
**影响**：Timer 每秒轮询 NSPasteboard，空闲时持续占用 CPU

### 问题描述

`ClipboardMonitor` 使用 `Timer.scheduledTimer(withTimeInterval: 1.0)` 每秒轮询剪贴板 `changeCount`，即使剪贴板未变化也持续消耗 CPU。

### 修复内容

废弃 Timer 轮询，改为订阅系统级事件通知：
- `NSWorkspace.didActivateApplicationNotification` — 应用切换时按需检查
- `DistributedNotificationCenter` 的 `com.apple.pasteboard.changed` — 剪贴板变化时精确触发

`check()` 方法仅在收到通知时执行一次 `changeCount` 原子比对。

### 修改文件

| 文件 | 修改 |
|------|------|
| `ClipboardMonitor.swift` | Timer → NSWorkspace + DistributedNotificationCenter |

---

## #30 2026-07-01 — V0.3 架构重构：Vision OCR 对象复用与线程隔离

**严重度**：🟡 性能  
**文件**：`HotkeyManager.swift`  
**影响**：每次 OCR 取词重建 `VNRecognizeTextRequest`，配置冗余分配

### 问题描述

`captureViaVisionOCR()` 在自适应三档循环中每档都新建 `VNRecognizeTextRequest` 并设置 recognitionLevel/languages/minimumTextHeight，且计算在主线程执行。

### 修复内容

- `VNRecognizeTextRequest` 改为模块级 `sharedOCRRequest` 全局复用单例
- OCR 计算派发到专用队列 `ocrQueue = DispatchQueue(label: "com.omnitrans.ocr", qos: .userInitiated)`，通过 `ocrQueue.sync` 同步等待结果

### 修改文件

| 文件 | 修改 |
|------|------|
| `HotkeyManager.swift` | 提取 `sharedOCRRequest` + `ocrQueue`，`handler.perform` 切到专用队列 |

---

## #31 2026-07-01 — V0.3 架构重构：存储职责剥离 ProviderStorageManager

**严重度**：🟡 架构  
**文件**：新建 `ProviderStorageManager.swift`，修改 `AppState.swift`  
**影响**：AppState 单体承担 UI 状态 + 持久化 CRUD，职责混杂

### 问题描述

`AppState` 中包含 `UserDefaults` 读写、JSON 编解码、`KeychainManager` 延迟加载等底层存储逻辑，导致类膨胀且难以独立测试。

### 修复内容

创建 `ProviderStorageManager` 静态代理枚举，集中管理：

| 职责 | 方法 |
|------|------|
| Provider 持久化 | `loadProviders()` / `saveProviders(_:)` / `deleteProviderKey(id:)` |
| Keychain 懒加载 | `loadProviderKey(for:)` |
| 语言偏好 | `loadSourceLang()` / `saveSourceLang(_:)` / `loadTargetLang()` / `saveTargetLang(_:)` |
| 翻译历史 | `loadHistory()` / `saveHistory(_:)` / `clearHistory()` |

`AppState` 中所有 `UserDefaults.standard.xxx(forKey:)` / `JSONEncoder/Decoder` / `KeychainManager` 调用均委托给 `ProviderStorageManager`。

### 修改文件

| 文件 | 修改 |
|------|------|
| `Services/ProviderStorageManager.swift` | **新建** — 静态存储代理 |
| `Models/AppState.swift` | `load()` / `save()` / `saveLanguages()` / `deleteProvider()` / `ensureKey()` / `addHistory()` / `clearHistory()` 全部委托 |

---

## #32 2026-07-01 — V0.3 架构重构：取词流水线 → 职责链模式

**严重度**：🟡 架构  
**文件**：新建 `TextCaptureStrategies.swift`，修改 `HotkeyManager.swift`  
**影响**：取词逻辑耦合在 HotkeyManager 内部，不可插拔、不可单独测试

### 问题描述

`HotkeyManager` 中包含 `captureViaSimulatedCopy()`、`captureViaAX()`、`captureViaVisionOCR()` 三个私有方法，`capture()` / `captureWithoutOCR()` / `captureWithOCR()` 硬编码调用顺序。

### 修复内容

定义 `TextCaptureStrategy` 协议 → 三个独立策略实现：

| 策略 | 类 | 说明 |
|------|-----|------|
| 剪贴板 | `ClipboardCaptureStrategy` | CGEvent 模拟 Cmd+C + 剪贴板原子恢复 |
| 辅助功能 | `AXCaptureStrategy` | AX API 直接读取选中文本 |
| 屏幕 OCR | `VisionOCRCaptureStrategy` | Vision 自适应三档屏幕识别 |

`HotkeyManager.capture()` 简化为声明式链条：
- 翻译热键：`[ClipboardCaptureStrategy(), AXCaptureStrategy()]`
- OCR 热键：`[ClipboardCaptureStrategy(), AXCaptureStrategy(), VisionOCRCaptureStrategy()]`

### 修改文件

| 文件 | 修改 |
|------|------|
| `Services/TextCaptureStrategies.swift` | **新建** — 协议 + 三个策略实现 |
| `Services/HotkeyManager.swift` | 移除三个私有 capture 方法，`capture()` 改为策略链遍历 |

---

## #33 2026-07-01 — V0.3 架构重构：灾备路由器 FallbackRouter 解耦

**严重度**：🟡 架构  
**文件**：新建 `FallbackRouter.swift`，修改 `TranslationActor.swift`  
**影响**：Ollama 探测和路由重写逻辑耦合在并发 actor 内部

### 问题描述

`TranslationActor` 中包含 `probeLocalOllama()` 和 `resolveWithFallback()`，将灾备路由策略与流式翻译管道混杂。

### 修复内容

创建 `FallbackRouter` 枚举，独立封装：
- `probeLocalOllama()` — HTTP 心跳探测 `127.0.0.1:11434/v1/models`（1 秒超时）
- `resolveWithFallback(_:)` — 主 API 连通性测试 → 失败则重映射为本地 Ollama

`TranslationActor.resolveWithFallback()` 变为单行委托。

### 修改文件

| 文件 | 修改 |
|------|------|
| `Services/FallbackRouter.swift` | **新建** — 灾备探测与路由 |
| `Services/TranslationActor.swift` | `resolveWithFallback` + `probeLocalOllama` → 委托 `FallbackRouter` |

---

## V0.3 架构重构总结

| 重构项 | 文件 | 收益 |
|--------|------|------|
| #29 剪贴板监控 | `ClipboardMonitor.swift` | 空闲 CPU 0% |
| #30 OCR 复用 | `HotkeyManager.swift` | 避免重复分配 VNRecognizeTextRequest |
| #31 存储剥离 | 新建 `ProviderStorageManager.swift` | AppState 瘦身 ~40 行 |
| #32 职责链 | 新建 `TextCaptureStrategies.swift` | 取词可插拔、可测试 |
| #33 灾备解耦 | 新建 `FallbackRouter.swift` | 灾备策略独立演化 |

**新增文件**：`ProviderStorageManager.swift`、`TextCaptureStrategies.swift`、`FallbackRouter.swift`  
**修改文件**：`ClipboardMonitor.swift`、`HotkeyManager.swift`、`AppState.swift`、`TranslationActor.swift`  
**编译状态**：✅ Build complete!

---


---

## V0.3 架构优化（#29–#33）

### #29 2026-07-01 — 0% CPU 剪贴板静默监控

**严重度**：✨ 性能  
**文件**：`ClipboardMonitor.swift`

#### 问题描述
1s Timer 轮询 `changeCount` 持续占用 CPU。

#### 修复内容
订阅 `NSWorkspace` 系统级通知 + `changeCount` 原子比对，仅在有复制行为或窗口切换时按需检测。

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Services/ClipboardMonitor.swift` | Timer → NSWorkspace 通知驱动 |

---

### #30 2026-07-01 — Vision OCR 对象复用与线程隔离

**严重度**：✨ 性能  
**文件**：`HotkeyManager.swift`

#### 问题描述
每次 OCR 截图创建新的 `VNRecognizeTextRequest` 实例，重复分配开销。

#### 修复内容
`VNRecognizeTextRequest` 改为全局复用单例；图像识别分配到 `com.omnitrans.ocr` (qos: .userInitiated) 独立后台队列。

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Services/HotkeyManager.swift` | 共享 `sharedOCRRequest` + `ocrQueue` |

---

### #31 2026-07-01 — 存储职责剥离（解耦 AppState）

**严重度**：🟡 架构  
**文件**：新建 `ProviderStorageManager.swift`

#### 问题描述
`AppState` 混杂 JSON 编解码、`UserDefaults` 读写、`Keychain` 加载等 CRUD 代码。

#### 修复内容
创建 `ProviderStorageManager` 静态代理类，封装所有持久化逻辑。`AppState` 仅保留业务状态。

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Services/ProviderStorageManager.swift` | **新建** — UserDefaults/Keychain 代理 |

---

### #32 2026-07-01 — 取词流水线重构为职责链模式

**严重度**：🟡 架构  
**文件**：新建 `TextCaptureStrategies.swift`

#### 问题描述
`HotkeyManager.capture()` 内三种取词方式（AX、剪贴板、OCR）逻辑耦合在一起。

#### 修复内容
定义 `TextCaptureStrategy` 协议，分离 `AXCaptureStrategy` / `ClipboardCaptureStrategy` / `VisionOCRCaptureStrategy`。`capture()` 简化为声明式链：`strategies.firstMap { $0.tryCapture() }`。

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Services/TextCaptureStrategies.swift` | **新建** — 职责链三策略 |

---

### #33 2026-07-01 — 灾备路由器独立解耦

**严重度**：🟡 架构  
**文件**：新建 `FallbackRouter.swift`

#### 问题描述
Ollama 探测和路由重写逻辑嵌入 `TranslationActor`，职责混杂。

#### 修复内容
抽离至独立 `FallbackRouter` 策略类。

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Services/FallbackRouter.swift` | **新建** — Ollama 探测 + 路由重写 |


## #34 2026-07-01 — V0.3 智能大模型词典（JSON Mode）

**严重度**：✨ 功能  
**文件**：新建 `DictionaryEntry.swift`、`DictionaryCardView.swift`，修改 `TranslationActor.swift`、`AppState.swift`、`FloatingTranslationView.swift`  
**影响**：单词查询与段落翻译共用同一管道，无结构化词典展示

### 实现内容

| 层级 | 改动 |
|------|------|
| 模型 `DictionaryEntry.swift` | `isWord` / `phonetic` / `definitions[{pos, meaning}]` / `examples[{en, zh}]` + `WordDetector.isWord()` 单词检测 |
| 管道 `TranslationActor.swift` | 新增 `translateDictionary()` → 词典 System Prompt 强制 JSON 输出；Ollama 注入 `response_format: json_object`；`temperature` 降为 0.1 |
| 状态 `AppState.swift` | `@Published var dictionaryEntry` + `@Published var isDictionaryMode`；单词自动分流到词典管道；词典模式下不流式显示原始 JSON |
| UI `DictionaryCardView.swift` | 词头 + 音标行 + 词性色标标签 + 例句区 |
| 视图 `FloatingTranslationView.swift` | 词典模式：标题切换「查词」+ 线性进度条动画；翻译模式：流式文本 |

### 修改文件

| 文件 | 修改 |
|------|------|
| `Models/DictionaryEntry.swift` | **新建** — 数据模型 + `WordDetector` |
| `Views/DictionaryCardView.swift` | **新建** — 词典卡片 UI |
| `Services/TranslationActor.swift` | `translateDictionary()` + `buildDictionaryHint(tgt:)` + `isDictionaryMode` 管道 |
| `Models/AppState.swift` | `dictionaryEntry` / `isDictionaryMode` 状态 + 词典分流 + JSON 解析 |
| `Views/FloatingTranslationView.swift` | 查词/翻译双模式标题、进度条、卡片分支渲染 |

---

## #35 2026-07-01 — SenseNova 模板 + 模型列表优化 + 悬浮窗拉长

**严重度**：✨ 功能 + 🟡 体验  
**文件**：`ProviderTemplates.swift`、`ProviderCardView.swift`、`App.swift`、`FloatingTranslationView.swift`

### 改动内容

| 改动 | 说明 |
|------|------|
| SenseNova 模板 | baseURL `https://token.sensenova.cn/v1`，默认模型 `SenseNova-5.0`，OpenAI 兼容 |
| 模型列表改为纵向 | 横向标签条 → 纵向可滚动选择列表，最大高度 130pt，选中蓝底 + ✓ |
| 悬浮窗拉长 | 面板高度 200→280pt，最小高度 200→240pt |

### 修改文件

| 文件 | 修改 |
|------|------|
| `Models/ProviderTemplates.swift` | 新增 SenseNova 模板 |
| `Views/ProviderCardView.swift` | 模型列表横向→纵向滚动 |
| `App.swift` | 面板高度 200→280 |
| `Views/FloatingTranslationView.swift` | 最小高度 200→240 |

---

## #36 2026-07-01 — V0.3 macOS 原生离线词典与翻译

**严重度**：✨ 功能  
**文件**：新建 `MacOSNativeProvider.swift`，修改 `APIProvider.swift`、`ProviderTemplates.swift`、`TranslationActor.swift`、`APITestService.swift`、`TranslationService.swift`

### 实现内容

| 层级 | 改动 |
|------|------|
| 类型 `APIProvider.swift` | `ProviderKind.macOSNative` + `isBuiltIn` 属性 |
| 提供者 `MacOSNativeProvider.swift` | `lookupWord()` → `DCSCopyTextDefinition` (CoreServices)；`translate()` → `TranslationSession` |
| 管道 | AppState 中 `macOSNative` 走本地通道，不经过 TranslationActor 网络管道 |
| 模板 | 「macOS 原生（离线）」，零配置 |

### 词典解析

`DCSCopyTextDefinition` 原始输出 → `parseDefinitions()` 提取 `noun | meaning` / `1. meaning` 格式 → `DictionaryEntry.Definition[]`

### 修改文件

| 文件 | 修改 |
|------|------|
| `Services/MacOSNativeProvider.swift` | **新建** — 词典查词 + Translation 翻译 |
| `Models/APIProvider.swift` | `macOSNative` enum + `isBuiltIn` |
| `Models/ProviderTemplates.swift` | macOS 原生模板 |
| `Models/AppState.swift` | native provider 本地通道拦截 |
| `Services/TranslationActor.swift` | `macOSNative` switch case |
| `Services/APITestService.swift` | native 测试/模型获取 stub |
| `Services/TranslationService.swift` | switch exhaustive fix |

---

## #37 2026-07-01 — 原生词典专用排版 + 内置供应商

**严重度**：✨ 功能 + 🟡 体验  
**文件**：新建 `NativeDictionaryView.swift`，修改 `APIProvider.swift`、`AppState.swift`、`ProviderCardView.swift`、`FloatingTranslationView.swift`

### 改动内容

| 改动 | 说明 |
|------|------|
| 原生词典排版 | `NativeDictionaryView` — 28pt 衬线体词头 + 蓝色分割线 + 词性标签 + 流式释义 |
| 内置供应商 | 固定 UUID `0000…0001`，不可删除、不可编辑、列表强制置顶 |
| 卡片标识 | 图标 + "内置" 标签，无删除/编辑按钮 |
| 视图分支 | `selectedProvider?.kind == .macOSNative` → `NativeDictionaryView`；其他 → `DictionaryCardView` |

### 修改文件

| 文件 | 修改 |
|------|------|
| `Views/NativeDictionaryView.swift` | **新建** — Apple Dictionary 风格排版 |
| `Models/APIProvider.swift` | `static let native` + `isBuiltIn` |
| `Models/AppState.swift` | `load()` 自动注入 native；`deleteProvider` / `updateProvider` 守卫 |
| `Views/ProviderCardView.swift` | 内置卡片不可编辑/删除 |
| `Views/FloatingTranslationView.swift` | 根据 provider kind 选择排版 |

---

## #38 2026-07-01 — Translation 框架降级回退（macOS 15+ 全版本）

**严重度**：✨ 功能  
**文件**：`MacOSNativeProvider.swift`、`Package.swift`、`AppState.swift`

### 问题描述

macOS 26 SDK 中 `TranslationSession(sourceLanguage:targetLanguage:)` 被重命名为 `init(installedSource:target:)`，旧 API 不可编译。需要兼容 macOS 15-26 全版本。

### 修复方案

| macOS 版本 | 引擎 | 实现 |
|-----------|------|------|
| 15+ | ANE 离线翻译 | `@_silgen_name` 直接链接 `.tbd` 中隐藏的 `TranslationSession.init(configuration:)`；公开方法 `prepareTranslation` / `translate(batch:)` 正常使用 |
| 14 | 不可用 | `#available(macOS 15.0, *)` fallback → 提示升级 |

**关键发现**：Xcode 26.2 SDK 的 swiftinterface 移除了 `TranslationSession.init`，但 `.tbd` 链接符号表中保留了 `_$s11Translation0A7SessionC13configurationA2C13ConfigurationV_tcfC`。通过 `@_silgen_name` 绕过编译器检查即可直接链接。无需 `weak_framework`、`dlopen` 或 ObjC runtime。

**新增文件** `SystemTranslationEngine.swift`：独立 actor，封装流式 (`translateStream`) 和单次 (`translateSingle`) 翻译，`BatchResponse` AsyncSequence → `AsyncThrowingStream` 桥接。

### 修改文件

| 文件 | 修改 |
|------|------|
| `Package.swift` | `-Xlinker -weak_framework -Xlinker Translation` |
| `Services/MacOSNativeProvider.swift` | 版本分支 + ObjC runtime 降级 + `#if canImport(Translation)` |
| `Models/AppState.swift` | `#available(macOS 15.0, *)` 守卫 |

---


---

## #39 2026-07-01 — 词典提示词目标语言约束

**严重度**：🟡 功能  
**文件**：`TranslationActor.swift`

#### 问题描述
大模型返回的词汇解释使用非目标语言（例如目标语言中文，返回英文释义）。

#### 修复内容
`buildDictionaryHint()` 增加 `CRITICAL RULES` 区块，强制要求 ALL meanings 和 example translations 使用目标语言，重复强调，禁止混用。

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Services/TranslationActor.swift` | `buildDictionaryHint()` — CRITICAL RULES 约束 |

---

## #40 2026-07-01 — 词典模式进度条时序修复

**严重度**：🟡 Bug  
**文件**：`AppState.swift`

#### 问题描述
`isDictionaryMode = false` 在 `isTranslating = false` 之前执行，导致进度条在翻译完成前消失。

#### 修复内容
调换两行顺序，确保进度条动画覆盖整个词典查询周期。

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Models/AppState.swift` | LLM 和 Native 两条路径均调换 `isDictionaryMode` / `isTranslating` 顺序 |

---

## #41 2026-07-01 — 原生词典排版优化

**严重度**：🟡 体验  
**文件**：`NativeDictionaryView.swift`

#### 问题描述
原生词典结果纯文字堆砌，可读性差。

#### 修复内容
重新设计排版 — POS 标签 accent 色半透明背景，释义行斑马条纹交替背景色，增加序号，优化间距。

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Views/NativeDictionaryView.swift` | 斑马行 + POS 标签背景 + 序号 |



---

## #42 2026-07-01 — 传统机器翻译 (MT) 多供应商集成

**严重度**：✨ 功能  
**文件**：新建 `TranslationActor_MT.swift`，修改 `APIProvider.swift`、`TranslationActor.swift`、`TranslationService.swift`、`APITestService.swift`、`ProviderTemplates.swift`、`ProviderCardView.swift`、`ProviderStorageManager.swift`、`AppState.swift`

### 设计理念：流式管道伪装

传统 MT (Google/Bing/阿里云) 单次 HTTP POST → 整段返回。`performMockStream()` 将单次返回包装为 `AsyncThrowingStream` 的唯一 Token，上层 UI 管道零修改。

### 新增供应商

| 供应商 | ProviderKind | API | 认证 |
|--------|-------------|-----|------|
| Google 翻译 | `.googleMT` | Cloud Translation v2 | API Key (URL query) |
| Bing 翻译 | `.bingMT` | Translator v3 | Key + Region (Header) |
| 阿里云翻译 | `.alibabaMT` | MT 通用版 | AccessKey ID + Secret (HMAC-SHA1) |

### 修改文件

| 文件 | 修改 |
|------|------|
| `Services/TranslationActor_MT.swift` | **新建** — HTML 实体解码器 + `AlibabaCloudSigner` HMAC-SHA1 签名 + CommonCrypto 桥接 |
| `Models/APIProvider.swift` | 新增 3 个 ProviderKind + `apiSecret` / `customRegion` 字段 + `isTraditionalMT` |
| `Services/TranslationActor.swift` | `performMockStream()` + `requestGoogleMT/BingMT/AlibabaMT()` + `mtTranslate()` |
| `Services/TranslationService.swift` | 非流式回退 MT 分支 + `mtFallback()` |
| `Services/APITestService.swift` | MT 连接测试 (`testGoogleMT/BingMT/AlibabaMT`) |
| `Models/ProviderTemplates.swift` | 3 个 MT 预设模板 |
| `Views/ProviderCardView.swift` | Secret / Region 编辑输入框 |
| `Services/ProviderStorageManager.swift` | Keychain 双密钥存储 (v3) |
| `Models/AppState.swift` | MT 屏蔽词典模式 |


## V0.3 功能总结

| # | 功能 | 新文件 | 核心改动 |
|---|------|--------|---------|
| 34 | 智能词典 JSON Mode | `DictionaryEntry.swift`, `DictionaryCardView.swift` | System Prompt + 单词检测 + 卡片UI |
| 35 | SenseNova + 模型列表 + 面板 | — | 模板 + 纵向列表 + 280pt 高 |
| 36 | macOS 原生离线通道 | `MacOSNativeProvider.swift` | CoreServices + Translation |
| 37 | 原生词典排版 + 内置 | `NativeDictionaryView.swift` | Apple 风格排版 + 不可删除 |
| 38 | 全版本降级 | `SystemTranslationEngine.swift` | `@_silgen_name` 链接隐藏 init |
| 39 | 词典提示词约束 | — | CRITICAL RULES 强制目标语言 |
| 40 | 进度条时序修复 | — | `isDictionaryMode` / `isTranslating` 顺序 |
| 41 | 原生词典排版优化 | — | 斑马行 + POS 标签背景 |
| 42 | 传统 MT 多供应商 | `TranslationActor_MT.swift` | Google/Bing/阿里云 + HMAC 签名 |

**V0.3 新文件**：`ProviderStorageManager.swift`、`TextCaptureStrategies.swift`、`FallbackRouter.swift`、`DictionaryEntry.swift`、`DictionaryCardView.swift`、`MacOSNativeProvider.swift`、`NativeDictionaryView.swift`、`SystemTranslationEngine.swift`、`TranslationActor_MT.swift`

**编译状态**：✅ Build complete!

---

## #43 2026-07-01 — 阿里云 MT 签名修复（CommonCrypto → CryptoKit）

**严重度**：🔴 Bug  
**文件**：`TranslationActor_MT.swift`、`Info.plist`

#### 问题描述
阿里云机器翻译 API 连接失败，三个根因：
1. 签名算法使用 `@_silgen_name("CCHmac")` 桥接 CommonCrypto，返回值不稳定且不符合苹果安全规范
2. 响应体是 XML 格式（非 JSON），未解析 `<Translated>` 节点导致提取不到译文
3. ATS 策略拒绝 HTTP 明文连接（阿里云 MT 端点为 `http://mt.cn-hangzhou.aliyuncs.com`）

#### 修复内容
- **签名**：换用 `CryptoKit.HMAC<Insecure.SHA1>` — 纯 Swift，零桥接，输出稳定
- **XML 解析**：新增 `extractXMLTag()` 和 `htmlEntityDecoded()` 扩展，正确提取 `<Translated>` 内容并解码 HTML 实体
- **ATS 例外**：`Info.plist` 中为 `mt.cn-hangzhou.aliyuncs.com` 添加 `NSExceptionAllowsInsecureHTTPLoads`

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Services/TranslationActor_MT.swift` | `AlibabaCloudSigner.hmacSHA1Base64` 改用 `CryptoKit.HMAC<Insecure.SHA1>`；新增 XML/HTML 解析扩展 |
| `Info.plist` | ATS 例外 — `NSAppTransportSecurity` → `NSExceptionDomains` → `mt.cn-hangzhou.aliyuncs.com` |

---

## #44 2026-07-01 — MT 模板分组与 macOSNative 移除

**严重度**：🟡 体验  
**文件**：`ProviderTemplates.swift`、`SettingsView.swift`

#### 问题描述
传统机器翻译 (MT) 模板和 AI/LLM 模板混在同一列表中，macOSNative 作为可选模板出现，用户可以手动添加。但 macOS 原生翻译已内置，不应作为模板出现在列表中。

#### 修复内容
- `ProviderTemplate` 拆分为 `.ai`（LLM/AI 模板）和 `.mt`（MT 模板）两个独立数组
- `SettingsView` 模板页分为「🤖 AI 大模型」和「🔤 机器翻译」两个分段
- 移除 `macOSNative` 模板 — 内置供应商不提供手动添加入口

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Models/ProviderTemplates.swift` | `static let ai: [ProviderTemplate]` + `static let mt: [ProviderTemplate]` 拆分 |
| `Views/SettingsView.swift` | 模板页分段显示 — AI Section + MT Section |

---

## #45 2026-07-01 — MT 配置界面优化

**严重度**：🟡 体验  
**文件**：`ProviderCardView.swift`、`APIProvider.swift`

#### 问题描述
选择 MT 模板后，编辑界面仍然显示 AI 专属字段（Temperature、MaxTokens、模型列表拉取按钮），混淆用户体验。每种 MT 供应商需要特有的认证字段标签（如阿里云需要 "AccessKey ID" 而非 "API Key"）。

#### 修复内容
- MT 供应商编辑界面隐藏 Temperature / MaxTokens / 模型列表按钮
- 动态字段标签：
  - Google MT：`API Key`
  - Bing MT：`Key` + `Region`
  - 阿里云 MT：`AccessKey ID` + `AccessKey Secret`
- `APIProvider` 模型新增 `apiSecret` 和 `customRegion` 持久化字段

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Views/ProviderCardView.swift` | MT 类型时隐藏 Temp/Tokens/模型列表；动态 Key 标签 |
| `Models/APIProvider.swift` | `apiSecret` / `customRegion` 字段 + Codable |

---

## #46 2026-07-01 — 设置 → 翻译 Tab

**严重度**：✨ 功能  
**文件**：`SettingsView.swift`、`AppState.swift`、`ProviderStorageManager.swift`

#### 实现内容
在设置界面新增「翻译」Tab，集中管理翻译行为配置：
- **词典查词默认模型**：下拉选择器，可从已启用的 provider 中选择专属词典模型；留空则跟随当前选中模型
- **语言方向**：源语言 / 目标语言独立选择器
- **当前激活信息**：显示选中模型的名称 + baseURL + 模型标识
- `dictProviderID` 持久化到 `UserDefaults`，通过 `ProviderStorageManager` 读写

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Views/SettingsView.swift` | 新增 `translateTab` — 词典模型选择器 + 语言方向 + 激活信息 |
| `Models/AppState.swift` | `@Published var dictProviderID: UUID?` |
| `Services/ProviderStorageManager.swift` | `saveDictProviderID()` / `loadDictProviderID()` |

---

## #47 2026-07-01 — 窗口高度统一 380px

**严重度**：🟡 体验  
**文件**：`App.swift`、`FloatingPanel.swift`、`FloatingTranslationView.swift`

#### 问题描述
翻译悬浮窗高度不统一：`FloatingPanel` 初始化 280px，`App.swift` `setFrame` 200px，词典卡片模式下内容截断。

#### 修复内容
三处统一为 **380px**：
- `App.swift` → `setFrame(NSRect(x: 0, y: 0, width: 380, height: 380), …)`
- `FloatingPanel.swift` → `contentRect: NSRect(x: 0, y: 0, width: 380, height: 380)`
- `FloatingTranslationView.swift` → `.frame(minWidth: 360, minHeight: 380)`

#### 修改文件

| 文件 | 修改 |
|------|------|
| `App.swift` | showFloatingPanel 内 `setFrame` 高度 200 → 380 |
| `Services/FloatingPanel.swift` | Panel 初始化高度 280 → 380 |
| `Views/FloatingTranslationView.swift` | minHeight 280 → 380 |

---

## #48 2026-07-01 — 词典路由分离 + Keychain 单次授权

**严重度**：🟡 体验  
**文件**：`AppState.swift`、`KeychainManager.swift`、`ProviderStorageManager.swift`

#### 问题描述
1. 词典模式和划词翻译共用同一套路由逻辑，词典查词会被错误路由到 MT 供应商
2. 初次使用时 Keychain 逐个读取 key（API Key → Secret → Region），触发三次系统级授权弹窗

#### 修复内容
- **路由分离**：`translate()` 中通过 `isWord` 判断分流：
  - 单词 + `dictProviderID` 有值 → 使用指定词典模型
  - 单词 + `dictProviderID` 为 nil → 默认使用 `macOSNative`
  - 非单词 → 走原有翻译路由
- **Keychain 单次授权**：新增 `KeychainManager.batchReadAll()` — 一次 `SecItemCopyMatching` 读取全部 key，合并为一个授权弹窗
- `ProviderStorageManager.load()` 调用 `batchReadAll()` 预加载所有密钥

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Models/AppState.swift` | `effectiveProvider` 路由逻辑 — `isWord` + `dictProviderID` 分流；词典默认 macOSNative |
| `Utils/KeychainManager.swift` | `batchReadAll()` 批量读取方法 — `kSecMatchLimitAll` |
| `Services/ProviderStorageManager.swift` | `load()` 改用 `batchReadAll()` 替换逐个 `get()` |

---

## #49 2026-07-01 — 全局 UI 优化

**严重度**：✨ 功能  
**文件**：`FloatingTranslationView.swift`、`App.swift`、`SettingsView.swift`、`AppState.swift`

#### 实现内容
- **字体放大**：全局字号提升 10-20%（输入框、翻译结果、标签）
- **单词检测提示条**：输入框检测到单字时顶部显示「📖 检测到单词 — 切换为词典模式」提示
- **词典专属模型标签**：词典模式时右上角显示当前词典模型名称 + 图标（与划词模式区分）
- **深色/浅色/跟随系统**：
  - `SettingsView` 通用 Tab 增加外观切换 `Picker`（浅色 / 深色 / 跟随系统）
  - `UserDefaults` key `app_appearance` 持久化选择
  - `AppDelegate.applicationDidFinishLaunching` 启动时应用外观设置
- **词典进度条**：词典模式使用渐变进度条动画，替代光标闪烁

#### 修改文件

| 文件 | 修改 |
|------|------|
| `Views/FloatingTranslationView.swift` | 全局字体放大；`dictProviderName` 标签；单词检测提示条；词典进度条 |
| `App.swift` | `app_appearance` 启动时应用外观 |
| `Views/SettingsView.swift` | 外观切换 Picker（浅色/深色/跟随系统） | 
| `Models/AppState.swift` | `detectedIsWord` 发布属性 |

---

## V0.3 完整变更总结

| # | 功能 | 分类 | 新文件 |
|---|------|------|--------|
| 34 | 智能词典 JSON Mode | 功能 | `DictionaryEntry.swift`, `DictionaryCardView.swift` |
| 35 | SenseNova API + 模型列表 | 功能 | — |
| 36 | macOS 原生离线通道 | 功能 | `MacOSNativeProvider.swift` |
| 37 | 原生词典专用排版 | 体验 | `NativeDictionaryView.swift` |
| 38 | 全版本降级兼容 | 架构 | `SystemTranslationEngine.swift` |
| 39 | 词典提示词目标语言约束 | 修复 | — |
| 40 | 进度条时序修复 | 修复 | — |
| 41 | 原生词典斑马行排版 | 体验 | — |
| 42 | 传统 MT 多供应商集成 | 功能 | `TranslationActor_MT.swift` |
| 43 | 阿里云 MT 签名修复 | 修复 | — |
| 44 | MT 模板分组 | 架构 | — |
| 45 | MT 配置界面优化 | 体验 | — |
| 46 | 设置 → 翻译 Tab | 功能 | — |
| 47 | 窗口高度统一 380px | 体验 | — |
| 48 | 词典路由 + Keychain 优化 | 架构 | — |
| 49 | 全局 UI 优化 | 体验 | — |

**V0.3 新增文件（9 个）**：
`ProviderStorageManager.swift`、`TextCaptureStrategies.swift`、`FallbackRouter.swift`、
`DictionaryEntry.swift`、`DictionaryCardView.swift`、`MacOSNativeProvider.swift`、
`NativeDictionaryView.swift`、`SystemTranslationEngine.swift`、`TranslationActor_MT.swift`

**编译状态**：✅ Build complete!

---

## #50 2026-07-01 — Keychain 存储结构重构与授权优化

**严重度**：🔴 架构  
**文件**：`KeychainManager.swift`（重写）、`ProviderStorageManager.swift`（重写）、`ProviderCardView.swift`、`SettingsView.swift`

### 问题诊断

1. **魔法字符串散落四处**：`uuid`、`uuid_secret`、`uuid_region` 硬编码在 3 个文件中，新增字段需要全局 grep + replace
2. **重复授权弹窗**：`enterEdit()` 每次进入编辑时逐个调用 `KeychainManager.get()`，每个触发一次系统级 Keychain 授权弹窗（3 字段 = 最多 3 次弹窗）
3. **View 层直接依赖 KeychainManager**：ProviderCardView / SettingsView 需要知道 keychain 内部命名规则（`uuid_string`、`uuid_secret`、`uuid_region`）
4. **风险写入模式**：`save()` 使用 `SecItemDelete → SecItemAdd` — 删除成功但新增失败 = 数据丢失
5. **无迁移能力**：旧格式 `{uuid}` 无法自动升级为结构化格式

### 重构方案

#### 1. 结构化 Key 格式

```
旧格式（扁平）：              新格式（结构化）：
550e8400-...    → apiKey     provider:550e8400-...:apiKey
550e8400-..._secret          provider:550e8400-...:apiSecret
550e8400-..._region          provider:550e8400-...:region
```

新增类型：
- `KeychainField` 枚举 — `apiKey` / `apiSecret` / `customRegion`
- `KeychainKey` 结构体 — 组合 `providerID` + `field`，自动序列化/反序列化
- `KeychainFields` 结构体 — 一个 Provider 的全量敏感字段容器

#### 2. 原子写入

`save()` 改用 `SecItemUpdate` 优先（已存在则更新），不存在才 `SecItemAdd` — 消除 delete-then-add 的竞态窗口。

#### 3. 自动迁移

`batchReadAll()` 检测到旧格式 `{uuid}` key 时，自动写入新格式 `provider:{uuid}:apiKey` 并删除旧 key，全程透明。

#### 4. 内存缓存层

`ProviderStorageManager` 新增：
- `secretCache: [UUID: KeychainFields]` — 启动时一次性加载全部密钥
- `preloadSecrets()` — 单次 Keychain 授权后缓存所有密钥
- `cachedFields(for:)` / `cachedValue(for:field:)` — 零 Keychain I/O 的缓存读取

#### 5. View 层解耦

- `ProviderCardView.enterEdit()` → `ProviderStorageManager.cachedFields(for:)`（不再直接调 KeychainManager）
- `SettingsView.onLoadKey` → `ProviderStorageManager.cachedValue(for:field:)`

### 修改文件

| 文件 | 修改 |
|------|------|
| `Utils/KeychainManager.swift` | **全量重写** — 新增 `KeychainField`、`KeychainKey`、`KeychainFields` 类型；`save()` 原子更新；`batchReadAll()` 返回 `[UUID: KeychainFields]` + 自动迁移；`saveFields()` / `deleteAllFields()` 批量操作；`deleteByPrefix()` |
| `Services/ProviderStorageManager.swift` | **全量重写** — 新增 `secretCache` 内存缓存；`preloadSecrets()` / `cachedFields(for:)` / `cachedValue(for:field:)`；`saveProviders()` 使用 `KeychainManager.saveFields()` |
| `Views/ProviderCardView.swift` | `enterEdit()` 改用 `ProviderStorageManager.cachedFields()` 替代 3 次独立 `KeychainManager.get()` |
| `Views/SettingsView.swift` | `onLoadKey` 改用 `ProviderStorageManager.cachedValue()` 替代 `KeychainManager.get()` |

**编译状态**：✅ Build complete!  |  ARM: ✅ `.build/OmniTrans-arm64.app`

---

## #51 2026-07-01 — 全局设计系统 + GUI 代码优化

**严重度**：✨ 体验  
**文件**：新建 `AppTheme.swift`，重写 `FloatingTranslationView.swift`、`TranslationView.swift`、`DictionaryCardView.swift`、`NativeDictionaryView.swift`，更新 `ProviderCardView.swift`、`ContentView.swift`、`SettingsView.swift`

### 设计理念

建立统一设计系统 `AppTheme`，消除 8 个视图中散落的 213 处硬编码颜色/字号/间距引用。采用「半透明材质 + 纯色文字」平衡策略：浮窗面板使用 `.regularMaterial`（macOS 原生毛玻璃），菜单栏内容使用纯色背景，文字全部使用 `NSColor` 桥接的系统色确保深色/浅色模式自适应。

### 新增文件

| 文件 | 内容 |
|------|------|
| `Utils/AppTheme.swift` | 统一设计令牌 — 5 组颜色（textPrimary / textSecondary / textTertiary / textAccent + bgSolid / bgSubtle / bgElevated / bgFloating + border + semantic）、4 级字号（caption=11 / label=12 / body=14 / headline=16 / title=20）、4 级间距（xs=4 / sm=8 / md=12 / lg=16） |
| — | View 扩展 — `cardStyle()` / `badgeStyle()` / `hintStyle()` / `wordHintBar()` / `floatingPanelStyle()` / `sectionLabel(_:_:)` |

### 核心改动

| 文件 | 改动 |
|------|------|
| `Views/FloatingTranslationView.swift` | 重写：使用 `floatingPanelStyle()` + `.regularMaterial` 毛玻璃面板；标题/文字/标签全部使用 AppTheme 颜色；字号统一；底部栏半透明提升 |
| `Views/TranslationView.swift` | 重写：菜单栏主界面使用 `bgSolid` 纯色背景；标题栏/输入区/输出区统一色板；provider 菜单高对比度 |
| `Views/DictionaryCardView.swift` | AppTheme 颜色替换；字号统一使用 fontSize constants |
| `Views/NativeDictionaryView.swift` | AppTheme 颜色替换；斑马行改用 `bgSubtle` |
| `Views/ProviderCardView.swift` | 9 处颜色引用替换为 AppTheme |
| `Views/ContentView.swift` | 底部快捷键栏颜色/replace AppTheme |
| `Views/SettingsView.swift` | 38 处 `.secondary` + 多处 opacity 背景替换为 AppTheme |

**编译状态**：✅ Build complete!  |  ARM: ✅ `.build/OmniTrans-arm64.app`

---

## #52 2026-07-01 — Keychain 持久化修复 + 界面重排 + 字号优化

**严重度**：🔴 Keychain / 🟡 UI  
**文件**：重写 `KeychainManager.swift`、`ProviderStorageManager.swift`、`FloatingTranslationView.swift`，调整 `TranslationView.swift`、`ContentView.swift`、`SettingsView.swift`

### Keychain 根因分析

API Key 每次重启丢失，根因有三：

1. **多字段存储复杂**：之前每个 provider 的 3 个字段（apiKey / apiSecret / customRegion）存储为 3 个独立 Keychain item，写路径上 `SecItemUpdate → SecItemAdd` 的竞态 + 静默吞错误导致部分写入失败时无感知
2. **迁移路径脆弱**：旧格式 `{uuid}` 迁移到新格式 `provider:{uuid}:{field}` 依赖多步操作，任一步失败导致数据丢失
3. **错误不可见**：`save()` 返回 `@discardableResult Bool`，`saveFields` 完全忽略返回值，写入失败无日志

### Keychain 修复方案

**改为单 JSON blob 存储**：每个 provider 一个 Keychain item，account 格式 `provider:{uuid}`，value 是 JSON `{"apiKey":"...","apiSecret":"...","customRegion":"..."}`。

- 一条 `SecItemAdd` / `SecItemUpdate` 搞定全部字段
- 无法部分写入 — 要么全成功要么全失败
- 自动迁移旧格式（`{uuid}` 和 `provider:{uuid}:{field}`）到新 blob
- 写入失败打印 `OSStatus` 错误码到日志，包含 `errSecAuthFailed` 等可诊断信息

### 悬浮翻译卡片重排

- 拖拽手柄 / 标题栏 / 原文卡片 / 结果区 / 底部工具栏 — 分层清晰
- 原文区加上卡片背景和圆角，与面板分离
- 进度条 / 错误 / 流式文本 / 词典结果 — 统一结果区
- 字号下调 2pt（14pt 正文，更紧凑）

### 菜单栏字号提升

- `TranslationView`：正文 14→16pt，标签 11→14pt，标题 16→18pt
- `ContentView`：底部栏 12→13pt

### 修改文件

| 文件 | 改动 |
|------|------|
| `Utils/KeychainManager.swift` | **全量重写** — 单 JSON blob 存储；`saveFields` 有错误日志；`batchReadAll` 自动迁移双重旧格式 |
| `Services/ProviderStorageManager.swift` | 简化 — 移除 `KeychainField` enum / `KeychainKey` struct；`cachedValue` 改用 String 字段名 |
| `Views/FloatingTranslationView.swift` | **全量重写** — 分层布局：drag → header → source card → result → bottom bar |
| `Views/TranslationView.swift` | 字号 +2pt（标题 18pt / 正文 16pt / 标签 14pt） |
| `Views/ContentView.swift` | 底部栏字号微调 |
| `Views/SettingsView.swift` | `onLoadKey` 适配新 API |

**编译状态**：✅ Build complete!  |  ARM: ✅ `.build/OmniTrans-arm64.app`

---

## #53 2026-07-01 — Keychain 深度诊断 + 直接存储双保险

**严重度**：🔴 Keychain  
**文件**：`KeychainManager.swift`、`ProviderStorageManager.swift`、`ProviderCardView.swift`、`AppState.swift`

### 问题诊断

API Key 每次重启丢失，在关键路径加入 8 处 `print` 日志追踪完整写链：

| 位置 | 日志内容 |
|------|---------|
| `AppState.load()` 启动时 | `debugDump()` 打印所有 keychain items |
| `ProviderStorageManager.loadProviders()` | secretCache 条数 |
| `ProviderStorageManager.saveProviders()` | 每个 provider 的 apiKey/secret 前缀 |
| `KeychainManager.saveFields()` | 💾 写入前 / ✅ 写入+验证 / ❌ OSStatus 错误码 |
| `KeychainManager.batchReadAll()` | 原始条数 + 每个 blob 内容 |
| `ProviderCardView.commit()` | 直接存储确认 |

### 双保险存储

`ProviderCardView.commit()` 现在直接调用 `KeychainManager.saveFields()`，不再仅依赖 `AppState.save() → ProviderStorageManager.saveProviders()` 链。两条路都写，确保至少一条成功。

### Keychain 写入验证

`saveFields()` 写入后立即通过 `SecItemCopyMatching` 读取比对，发现不一致立即打印 `⚠️ read-back mismatch`。

### 错误码暴露

写入失败时打印完整 `OSStatus`，包含 `errSecAuthFailed` 等可诊断信息。

### 运行诊断方法

启动软件后打开「控制台.app」，搜索 `[Keychain]` 即可看到完整存取日志。

**编译状态**：✅ Build complete!  |  ARM: ✅ `.build/OmniTrans-arm64.app`

---

## #54 2026-07-01 — Keychain 根因修复：-34018 errSecMissingEntitlement

**严重度**：🔴 阻断  
**文件**：新建 `Resource/entitlements.plist`，修改 `build-arm.sh`

### 根因

通过控制台日志发现的真实错误：

```
Error Domain=NSOSStatusErrorDomain Code=-34018
"Client has neither com.apple.application-identifier
nor com.apple.security.application-groups
nor keychain-access-groups entitlements"
```

**-34018 = `errSecMissingEntitlement`**。SwiftPM `swift build` 生成的二进制文件没有任何 entitlements。Ad-hoc `codesign --sign -` 签名后依然缺少 Keychain 访问权限声明，导致所有 `SecItemAdd` / `SecItemUpdate` 被系统拒绝 — 这就是每次重启 API Key 丢失的真正原因。

### 修复

1. 创建 `Resource/entitlements.plist`：
   ```xml
   <key>keychain-access-groups</key>
   <array>
       <string>com.omnitrans.arm64</string>
   </array>
   ```

2. `build-arm.sh` 签名命令加入 `--entitlements`：
   ```bash
   codesign --force --deep --sign - \
     --entitlements "Resource/entitlements.plist" "$APP_DIR"
   ```

3. `codesign -d --entitlements -` 验证：`keychain-access-groups: [com.omnitrans.arm64]` ✅

### 影响

修复后 Keychain 写入不再被系统拒绝，API Key 可正常持久化。

**编译状态**：✅ Build complete!  |  ARM: ✅ `.build/OmniTrans-arm64.app`

---

## #55 2026-07-01 — Keychain 方案废弃：迁移到本地加密文件存储

**严重度**：🔴 阻断修复  
**文件**：重写 `KeychainManager.swift`，清理 `build-arm.sh`、`entitlements.plist`

### 问题链

1. `errSecMissingEntitlement (-34018)` → Keychain 拒绝写入
2. 加 `keychain-access-groups` entitlement → 与 ad-hoc 签名冲突 → **app 无法启动**
3. SwiftPM 构建的 app 没有 Xcode provisioning profile，无法获得正确的 keychain entitlements

### 最终方案：弃用 Keychain，改用 `CryptoKit` 本地加密文件

| 维度 | Keychain | 文件存储 |
|------|----------|---------|
| 路径 | `login.keychain-db` | `~/Library/Application Support/OmniTrans/secrets.json` |
| 加密 | 系统级 | AES-256-GCM（key 绑定机器 UUID） |
| 权限 | 需要 entitlements | 文件系统权限（用户目录 0700） |
| 可靠性 | -34018 阻断 | 零依赖，可读可写 |
| 可迁移性 | 系统钥匙串跟随 | 文件跟随用户目录 |

### 加密细节

- 密钥派生：`HKDF-SHA256` 基于 `IOPlatformUUID`（机器唯一标识）
- 加密：`AES.GCM.seal()` — 每条写入生成随机 nonce
- 格式：`nonce(12B) + ciphertext + tag(16B)`
- 写入：`.atomic` 保证不出现半写文件

### 修改文件

| 文件 | 改动 |
|------|------|
| `Utils/KeychainManager.swift` | 完全重写 — 移除所有 Security framework 调用，改为 CryptoKit + 本地文件 |
| `build-arm.sh` | 移除 entitlements 参数 |
| `Resource/entitlements.plist` | 弃用 |

**编译状态**：✅ Build complete!  |  ARM: ✅ `.build/OmniTrans-arm64.app`（ad-hoc 签名，无 entitlements）

---

## #56 2026-07-02 — v0.3 重构：架构优化 + UI 还原

**文件**：TranslationView、FloatingTranslationView、ContentView、ClipboardMonitor、TranslationActor、TranslationActor_MT、SettingsView

### UI 还原 v0.2 风格
- `TranslationView.swift`：移除 `.regularMaterial` 背景，恢复系统原生颜色，还原 `.ultraThinMaterial` toast
- `FloatingTranslationView.swift`：恢复 `.regularMaterial` + `cornerRadius(12)`，保留词典模式全部功能
- `ContentView.swift`：还原 v0.2 简洁底部栏格式

### 性能重构
- `ClipboardMonitor.swift`：新增 `checkNow()` 公开方法，供 HotkeyManager 在 AX 取词失败时主动触发（零 Timer）
- `TranslationActor.swift`：新增 `ThrottledStream` 类，OpenAI/Anthropic/Gemini 三条 SSE 管道 80ms 节流
- `TranslationActor_MT.swift`：阿里云 endpoint 强转为 HTTPS `https://mt.cn-hangzhou.aliyuncs.com`

### SettingsView 物理拆分
- `GeneralSettingsView.swift`：快捷键录制 + 外观主题 + 剪贴板监听 + 悬浮窗行为
- `APISettingsView.swift`：API Provider 列表管理 + 模板添加
- `SettingsView.swift`：精简为 Tab 路由壳（5 个 Tab）
- `TemplateListView.swift`：模板选择独立 View

---

## #57 2026-07-02 — Bug 修复：持久化 + 模板取消 + 历史 + UI 优化

### 翻译引擎持久化
- `ProviderStorageManager` 新增 `saveSelectedProviderID` / `loadSelectedProviderID`
- `AppState.load()` 从 UserDefaults 恢复上次选择的 Provider
- `TranslationView` provider 菜单每次点击同步保存

### API 模板取消闪退
- 根因：`TemplateListView` 同时持有 `@Binding isPresented` 和 `@Environment(\.dismiss)` 在 sheet 中冲突
- 修复：改为纯回调 `onSelect` + `onCancel`，选择后 `DispatchQueue.main.async` 延迟关闭

### 历史界面
- 最大保存条数改为可编辑 TextField，默认 100
- 新增「一键清除」红色按钮 + 「不保存历史」Toggle
- `addHistory()` 加入 `history_disabled` 守卫

### 其他
- 关于页面图标改为 `icon.icns`，快捷键动态读取
- 设置左上角「返回翻译」→「返回」
- 清空原文联动清空翻译 + 词典条目 + 错误信息

---

## #58 2026-07-02 — Bug 修复：持久化 + 词典布局 + 按钮 + 快捷键重置

### selectedProviderID 持久化补全
- 根因：provider 菜单 Button 直接设值未保存
- 修复：每次选择同步调用 `ProviderStorageManager.saveSelectedProviderID(p.id)`

### 词典模式浮动窗优化
- 划词/OCR 词典模式隐藏原词框，全部空间给输出
- 菜单栏翻译页保持原样

### 菜单栏新增按钮
- 语言栏右侧新增「清空」+「翻译」按钮
- Enter 键绑定：`keyboardShortcut(.return)` 触发翻译

### 快捷键恢复默认
- 通用设置新增「恢复默认」按钮
- 一键重置翻译 `⌥D` + OCR `⌥F`

---

## #59 2026-07-02 — Bug 修复：sheet 闪退 + 开关 bug + 历史还原

### Sheet 闪退（根因修复）
- MenuBarExtra 的 `.sheet` 在 macOS 有已知 bug
- 改为 inline overlay：`ZStack` + `Color.black.opacity(0.3)` 遮罩 + 居中 `TemplateListView`

### 开关"删除"bug
- 根因：`APISettingsView` 用 `state.enabledProviders` 做 `ForEach`，关闭开关卡片消失
- 修复：改为 `state.providers` 显示全部 provider，禁用后仍可重新启用

### 历史记录点击还原
- 点击历史条目 → 恢复原文/译文/语言方向 → 自动切换 API → 跳回主页
- 不发起新翻译请求

### 剪贴板监听修复
- Toggle 改为 `Binding(get:set:)` 手动调用 `ClipboardMonitor.shared.start()/stop()`

---

## #60 2026-07-02 — 模板裁切 + 快捷键修正 + 自定义提示词 + 代码审计

### 模板界面裁切
- 模板列表 overlay 改为弹性布局（`maxWidth: 420, maxHeight: 460`）+ Spacer 居中

### 快捷键文本修正
- 全局默认快捷键确认为 `⌥D`（划词）和 `⌥F`（OCR）
- `resetShortcuts` 修正，所有文本使用 `HotkeyManager.hotkeyLabel()` 动态读取

### 自定义翻译提示词
- 设置 → 翻译页面新增「自定义翻译提示词」卡片
- 支持变量 `{sourceLang}`、`{targetLang}`
- 「恢复默认提示词」一键重置
- `TranslationActor.buildHint()` 同步使用自定义提示词
- 默认提示词优化为专业翻译指令

### 代码审计
- 无遗留 TODO/FIXME
- `deleteProvider` / `updateProvider` / `selectedProviderID` 持久化链路完整

---

## #61 2026-07-02 — 提示词 UX + 历史美化 + 悬浮 API 切换 + 版本号

### 自定义提示词 UX
- 文本框始终显示，关闭时灰不可编辑，开启时即时恢复
- 关闭时同步显示系统默认提示词
- 字体改为 `.monospaced`

### 历史界面美化
- 条目卡片式：`RoundedRectangle` + 细边框 + 分层字体
- Provider 徽章圆角标签 + 语言方向独立模块

### 菜单栏隐藏版本号
- `ContentView` 底部栏移除版本号显示

### 悬浮框 API 切换
- `FloatingTranslationView` header 新增 API 下拉菜单
- 列出所有启用 provider，点击切换并持久化

### 翻译按钮收紧
- 图标和文字缩小为 11pt，内边距减半

### 引导页重设计
- 三页结构：欢迎 → 隐私安全 → 翻译能力
- `OnboardRow` 统一组件，卡片式布局
- 使用 `ZStack` 替代不可用的 `TabView.page`

### 关于页调试功能
- 新增「重置首次使用引导」按钮

---

## #62 2026-07-02 — Bug 修复：API 切换不生效 + 提示词不响应

### 悬浮框 API 切换不生效
- 根因：`translate()` 重复请求拦截未比较 `selectedProviderID`
- 修复：新增 `lastProviderID` 变量，切换到新 API 后重新触发翻译

### 自定义提示词不即时响应
- 根因：`let promptEnabled = UserDefaults.standard.bool(forKey:)` 是渲染时一次性求值
- 修复：改用 `@AppStorage` 属性包装器，SwiftUI 自动追踪变化并刷新 UI

**编译状态**：✅ Build complete!  |  ARM: ✅ `.build/OmniTrans-arm64.app`

---

## v0.3 版本总结

### 新增功能
- 智能词典模式（AI 大模型 JSON Mode + macOS 原生词典）
- 3 种机器翻译（Google / Bing / 阿里云）
- macOS 15+ Translation 框架支持（弱链接降级）
- 自定义翻译提示词（开关 + 变量替换）
- 悬浮框内 API 实时切换
- 历史记录点击还原（不发起请求）
- 翻译引擎选择持久化
- 深色/浅色/系统外观切换
- 快捷键一键恢复默认
- 菜单栏翻译按钮 + Enter 快捷键 + 清空联动

### 架构改进
- SettingsView 拆分为 5 个独立 Tab View
- TranslationActor SSE 80ms 节流
- ClipboardMonitor 事件驱动（零 Timer）
- Keychain → CryptoKit AES-256-GCM 文件存储
- ProviderStorageManager 职责分离
- 阿里云 HTTPS 强制升级

### 修复 Bug（共 15+）
- sheet 闪退、开关"删除"、持久化丢失、快捷键错误、提示词不响应
- API 切换不生效、模板裁切、历史不可编辑、剪贴板监听无效

