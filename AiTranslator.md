# AiTranslator 项目技术文档

> 版本: `0.1` ｜ 平台: macOS 14+ ｜ 语言: Swift 5.9 ｜ 界面: SwiftUI + AppKit

---

## 目录

1. [技术栈](#1-技术栈)
2. [项目结构](#2-项目结构)
3. [架构总览](#3-架构总览)
4. [核心流程](#4-核心流程)
5. [模块实现详解](#5-模块实现详解)
   - [5.1 应用入口 — App.swift](#51-应用入口)
   - [5.2 状态管理 — AppState.swift](#52-状态管理)
   - [5.3 翻译服务 — TranslationService.swift](#53-翻译服务)
   - [5.4 全局热键 + 划词取词 — HotkeyManager.swift](#54-全局热键--划词取词)
   - [5.5 剪贴板监听 — ClipboardMonitor.swift](#55-剪贴板监听)
   - [5.6 悬浮翻译窗 — FloatingPanel.swift](#56-悬浮翻译窗)
   - [5.7 API 连接测试 — APITestService.swift](#57-api-连接测试)
   - [5.8 安全存储 — KeychainManager.swift](#58-安全存储)
   - [5.9 数据模型](#59-数据模型)
   - [5.10 UI 视图](#510-ui-视图)
6. [API 协议适配](#6-api-协议适配)
7. [安全设计](#7-安全设计)
8. [构建与分发](#8-构建与分发)
9. [已修复问题清单](#9-已修复问题清单)

---

## 1. 技术栈

| 层次 | 技术 | 说明 |
|------|------|------|
| 语言 | Swift 5.9 | 无第三方依赖，纯 Apple 框架 |
| UI | SwiftUI | 主界面 / 设置 / 翻译卡片 |
| 桥接 | AppKit | FloatingPanel (NSPanel)、剪贴板 (NSPasteboard)、辅助功能 (AXUIElement) |
| 系统事件 | Carbon | 全局热键 (RegisterEventHotKey)、模拟按键 (CGEvent) |
| 安全存储 | Security.framework | 基于 macOS Keychain 的 API Key 持久化 |
| 网络 | URLSession | URLSession.shared (无三方 HTTP 库) |
| 数据流 | AsyncThrowingStream | SSE 流式翻译 |
| 持久化 | UserDefaults | 提供商列表、语言偏好、翻译历史 |
| 构建 | Swift Package Manager | `swift build -c release --arch arm64` |

**无三方依赖 / 零外部包依赖**，完全基于系统原生 API。

---

## 2. 项目结构

```
AiTranslator/
├── Package.swift                        # SPM 描述文件
├── build.sh                             # 编译 + 打包 .app + ad-hoc 签名
└── Sources/AiTranslator/
    ├── App.swift                        # @main 入口 + AppDelegate
    ├── Models/
    │   ├── APIProvider.swift            # API 提供商模型 (ProviderKind)
    │   ├── AppState.swift               # 全局状态 (ObservableObject)
    │   ├── ProviderTemplates.swift      # 12 个预设 API 模板
    │   └── TranslationConfig.swift      # 支持语言枚举
    ├── Services/
    │   ├── TranslationService.swift     # 翻译 API 调用 (流式/非流式)
    │   ├── APITestService.swift         # 连接测试 + 模型列表拉取
    │   ├── HotkeyManager.swift          # 全局热键 + 划词取词
    │   ├── ClipboardMonitor.swift       # 剪贴板轮询监听
    │   └── FloatingPanel.swift          # NSPanel 悬浮窗
    ├── Utils/
    │   └── KeychainManager.swift        # Keychain 读写封装
    └── Views/
        ├── ContentView.swift            # MenuBarExtra 主窗口
        ├── TranslationView.swift        # 主翻译界面
        ├── FloatingTranslationView.swift # 悬浮窗翻译界面
        ├── SettingsView.swift           # 设置 (API/通用/历史/关于)
        └── ProviderCardView.swift       # 单个 API 提供商卡片
```

---

## 3. 架构总览

```
┌─────────────────────────────────────────────────┐
│                   AppDelegate                    │
│  applicationDidFinishLaunching                   │
│  ├─ HotkeyManager.register()                    │
│  ├─ ClipboardMonitor.start() (条件)              │
│  └─ 初始化 FloatingPanel                        │
├─────────────────────────────────────────────────┤
│                  AppState (单例)                  │
│  @Published providers / inputText / translated… │
│  翻译调度 / 历史管理 / UserDefaults 持久化        │
├──────────────────┬──────────────────────────────┤
│   翻译服务         │       系统服务               │
│ TranslationService│  HotkeyManager              │
│ APITestService    │  ClipboardMonitor           │
│                   │  FloatingPanel              │
└──────────────────┴──────────────────────────────┘
```

**核心设计原则：**
- **AppState 单例 + @Published**：全局唯一数据源，View 层直接绑定
- **@MainActor**：所有状态变更在主线程，避免 UI 线程安全问题
- **无三方依赖**：全部使用系统原生 API（URLSession / Carbon / Security）
- **Keychain 懒加载**：API Key 只在首次使用时从 Keychain 读取，避免启动时多次弹窗

---

## 4. 核心流程

### 4.1 热键翻译流程

```
用户选中文本 → 按下 ⌥D
  → Carbon hotkey 回调触发
  → HotkeyManager.capture()
    ├─ (优先) AXUIElement 获取选中文本
    └─ (回退) CGEvent 模拟 Cmd+C 取剪贴板
  → AppDelegate.fire(text:)
    ├─ 显示 FloatingPanel (悬浮窗)
    └─ AppState.translate() → TranslationService
```

### 4.2 剪贴板监听流程 (可选)

```
ClipboardMonitor (1s 轮询)
  → NSPasteboard.changeCount 变化
  → 取剪贴板文本
  → 2 秒去抖判断
  → AppState.translate()
```

### 4.3 翻译请求流程

```
AppState.translate()
  ├─ 去重判断 (同文本+同语言跳过)
  ├─ ensureKey() 懒加载 API Key
  └─ doTranslate()
      ├─ 取消前一个 Task (translateGeneration 机制)
      ├─ 主路径: TranslationService.translateStream()
      │   └─ 50ms 节流更新 UI (避免卡顿)
      ├─ 流式失败回退: TranslationService.translate() (非流式)
      └─ 网络错误自动重试 (最多 1 次)
```

### 4.4 多代并发保护

```
translateGeneration: Int  (每次翻译 +1)

doTranslate() 中的 Task:
  let gen = translateGeneration
  ... 每个 await 后检查:
  guard gen == self.translateGeneration else { return }
  → 确保旧任务残留不会污染新翻译结果
```

---

## 5. 模块实现详解

### 5.1 应用入口 — App.swift

```swift
@main
struct AiTranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra("AI 翻译", systemImage: "character.bubble.fill") {
            ContentView(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}
```

**关键点:**
- `MenuBarExtra` 窗口模式 (非标准菜单)，点击菜单栏图标弹出窗口
- `AppDelegate` 负责热键注册 / FloatingPanel 生命周期
- `AppState.shared` 单例，全局唯一数据源

**AppDelegate:**
- `applicationDidFinishLaunching` → 注册热键、条件性启动剪贴板监听
- `fire(text:)` → 显示悬浮窗 + 自动翻译
- `showFloatingPanel(text:)` → 仅显示悬浮窗 (不自动翻译)

---

### 5.2 状态管理 — AppState.swift

**核心属性:**

| 属性 | 类型 | 说明 |
|------|------|------|
| `providers` | `[APIProvider]` | 所有 API 配置 |
| `selectedProviderID` | `UUID?` | 当前使用的提供商 |
| `sourceLang` / `targetLang` | `TranslationLanguage` | 语言对 |
| `inputText` / `translatedText` | `String` | 输入/输出 |
| `isTranslating` | `Bool` | 翻译进行中 |
| `errorMessage` | `String?` | 错误信息 |
| `translationHistory` | `[HistoryEntry]` | 历史 (最多 50 条) |
| `showSuccessPulse` | `Bool` | 成功动效 |
| `showErrorShake` | `Bool` | 错误抖动 |

**持久化策略:**
- **API 配置** → `UserDefaults` (JSON, **不包含 API Key**)
- **API Key** → macOS Keychain (`SecItemAdd`/`SecItemCopyMatching`)
- **语言偏好** → `UserDefaults` 单值
- **翻译历史** → `UserDefaults` JSON (最多 50 条 FIFO)

**Keychain 懒加载 (`ensureKey`):**
```swift
func ensureKey(for provider: APIProvider) -> APIProvider {
    var p = provider
    if p.apiKey.isEmpty, let key = KeychainManager.get(key: p.id.uuidString) {
        p.apiKey = key
        providers[i].apiKey = key  // 缓存到内存
    }
    return p
}
```
- 仅在 `translate()` / `retryTranslate()` 调用时才从 Keychain 读取
- 读取后缓存到内存，后续访问即时
- 避免启动时多个 provider 同时触发 Keychain 弹窗

---

### 5.3 翻译服务 — TranslationService.swift

#### 支持的 API 协议

| 提供商类型 | 端点 | 鉴权方式 |
|-----------|------|---------|
| OpenAI / 兼容 | `POST {base}/chat/completions` | `Authorization: Bearer` |
| Anthropic | `POST {base}/v1/messages` | `x-api-key` + `anthropic-version` |
| Gemini | `POST {base}/models/{model}:generateContent` | `x-goog-api-key` (头) |

#### 流式翻译 (SSE)

```
TranslationService.translateStream() → AsyncThrowingStream<String, Error>

├─ OpenAI/兼容:  SSE (data: [DONE]), yield choices[0].delta.content
├─ Anthropic:    SSE (event: content_block_delta), yield delta.text
└─ Gemini:       SSE (data: {...}), yield candidates[0].content.parts[0].text
```

#### 降级策略

```
流式请求 (translateStream)
  ├─ 成功 → 流式渲染 UI
  ├─ 失败 → 自动降级到非流式 (translate)
  │   ├─ 成功 → 显示完整结果
  │   └─ 失败 → 显示错误 + 可选自动重试
  └─ 重试条件: retryCount < maxAutoRetry (1)
     且错误信息包含网络关键词 (中/英文)
```

#### 提示词构建

```swift
// 自动检测
"Translate to {target}. Output translation only."
// 指定源语言
"Translate {source} to {target}. Output translation only."
```

#### UI 节流

```swift
// 50ms 刷新间隔，避免高频更新导致 UI 卡顿
let flushInterval = Duration.milliseconds(50)
if (now - lastFlush) >= flushInterval {
    self.translatedText = fullText
}
```

---

### 5.4 全局热键 + 划词取词 — HotkeyManager.swift

#### 热键注册

```swift
// Carbon API
RegisterEventHotKey(key, mods, hotkeyID, GetApplicationEventTarget(), 0, &hotkeyRef)
InstallEventHandler(GetApplicationEventTarget(), callback, ...)
```

- 默认快捷键 `⌥D`（Option + D）
- 可通过 `UserDefaults( "hotkey_carbonKey" / "hotkey_carbonMods" )` 自定义
- 0.8 秒去抖，防止连续触发

#### 划词取词双通道

| 通道 | 实现 | 权限要求 | 优先级 |
|------|------|---------|--------|
| **主通道** | `CGEvent` 模拟 Cmd+C，轮询剪贴板变化 | 辅助功能权限 | 优先 |
| **回退通道** | `AXUIElement` 获取 `kAXSelectedTextAttribute` | 辅助功能权限 | 回退 |

**剪贴板保护 (defer 原子恢复):**
```swift
defer {
    pb.clearContents()
    if let strings = savedStrings {
        pb.setString(strings.joined(separator: "\n"), forType: .string)
    }
}
```
- 取词前保存剪贴板内容
- 使用 `defer` 确保即使崩溃也能恢复 (防止用户剪贴板数据丢失)

**取词超时:** 模拟 Cmd+C 后等待 40 × 5ms = 200ms 最大超时

---

### 5.5 剪贴板监听 — ClipboardMonitor.swift

```swift
// 核心机制
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { check() }
→ 比对 NSPasteboard.general.changeCount
→ 提取 string 类型内容
→ 2 秒去抖 (lastTranslationTime)
→ 触发 AppState.translate()
```

**自我保护:**
- `suppressNext`: 应用自身拷贝结果时不触发翻译
- 翻译中 (`isTranslating`) 跳过新请求
- 2 秒最小间隔防止连续复制触发多次翻译

---

### 5.6 悬浮翻译窗 — FloatingPanel.swift

```swift
final class FloatingPanel: NSPanel {
    // 核心配置
    styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled, .closable, .resizable]
    level: .floating
    collectionBehavior: [.canJoinAllSpaces, .fullScreenNone]
    becomesKeyOnlyIfNeeded: true
}
```

**特性:**
- 非激活面板 (不抢焦点)
- 悬浮在所有窗口之上
- 可拖拽移动 (`isMovableByWindowBackground = true`)
- 弹性弹出动画 (0.28s)
- 失焦自动关闭 (取决于 `dismiss_mode` 设置)
- `isReleasedWhenClosed = false` → 复用不销毁

**内容注入:**
```swift
panel.contentView = NSHostingView(rootView: FloatingTranslationView(state: s))
```

---

### 5.7 API 连接测试 — APITestService.swift

**测试连接 (`testConnection`)**

| 提供商类型 | 测试方法 | 超时 |
|-----------|---------|------|
| OpenAI | `GET /models` → 检查 HTTP 200 | 15s |
| OpenAI 兼容 | `GET /models` → 检查 HTTP 200 | 15s |
| Anthropic | `POST /v1/messages` 发 "hi" → 检查 HTTP 200 | 15s |
| Gemini | `GET /models` (header: x-goog-api-key) → 检查 HTTP 200 | 15s |

**拉取模型列表 (`fetchModels`)**

- OpenAI/兼容: `GET /models` → 解析 `{ data: [{ id: "gpt-4" }] }` → 排序
- Anthropic: 无公开端点，返回硬编码常用模型列表
- Gemini: `GET /models` → 解析 `{ models: [{ name: "models/gemini-pro" }] }` → 去前缀 `models/` → 排序

---

### 5.8 安全存储 — KeychainManager.swift

```swift
enum KeychainManager {
    static let service = "com.aitranslator.keys"
}
```

| 操作 | Security.framework | 特点 |
|------|-------------------|------|
| **Save** | `SecItemDelete` + `SecItemAdd` | 先删后加防止残留 |
| **Get** | `SecItemCopyMatching` | 返回 `Data → String` |
| **Delete** | `SecItemDelete` | |
| **Check** | `SecItemCopyMatching` (无返回数据) | 检查钥匙串是否可用 |

**存储属性:**
- `kSecClassGenericPassword`: 通用密码类型
- `kSecAttrAccessibleAfterFirstUnlock`: 首次解锁后可访问
- Key 为 provider UUID 字符串

---

### 5.9 数据模型

#### ProviderKind (APIProvider.swift)

```swift
enum ProviderKind: String, Codable, CaseIterable {
    case openAI      // OpenAI
    case openAICompat // OpenAI 兼容 (DeepSeek, Ollama, 硅基流动…)
    case anthropic   // Claude
    case gemini      // Google Gemini
}
```

#### TranslationLanguage (TranslationConfig.swift)

13 种语言 + 自动检测，每个有 `languageCode` (ISO 639-1):

```
auto / 中文(zh) / English(en) / 日本語(ja) / 한국어(ko)
Français(fr) / Deutsch(de) / Español(es) / Русский(ru)
Português(pt) / Italiano(it) / العربية(ar) / ไทย(th) / Tiếng Việt(vi)
```

#### ProviderTemplate (ProviderTemplates.swift)

12 个预设模板: DeepSeek / OpenAI / Ollama / 硅基流动 / Groq / Together AI / 智谱 GLM-4-Plus / 智谱 GLM-4-Flash / Kimi / 通义千问 / Anthropic / Gemini

---

### 5.10 UI 视图

#### ContentView → MenuBarExtra 窗口

```
┌─────────────────────────────┐
│  header (gear → Settings)   │
├─────────────────────────────┤
│  languageBar (源→目标)       │
├─────────────────────────────┤
│  inputArea (TextEditor)     │
├─────────────────────────────┤
│  outputArea (翻译结果+光标)   │
├─────────────────────────────┤
│  bottomBar (快捷键提示 版本)  │
└─────────────────────────────┘
```

#### FloatingTranslationView → 悬浮窗

与 TranslationView 功能对应，但为悬浮窗优化布局：
- 拖拽手柄 (Capsule)
- 简洁头部 (关闭按钮)
- 权限提示 (无辅助功能权限时)
- 源文本折叠显示
- 流式翻译 + 闪烁光标
- 底部语言切换 + 拷贝 + 重新翻译

#### SettingsView → 4 个标签页

| Tab | 内容 |
|-----|------|
| **API 配置** | ProviderCardView 列表 + 模板选择 sheet |
| **通用** | 快捷键录制 / 剪贴板监听开关 / 关闭模式 |
| **历史** | 翻译历史列表 (点击回填) |
| **关于** | 版本信息和介绍 |

#### ProviderCardView

**展示模式:**
```
[开关] 名称 [类型badge]    [测试][🗑️][✏️]
       模型 · URL
```

**编辑模式:** 名称 / 类型 / URL / Key / Model / 温度 / MaxTokens / 测试按钮 / [取消][保存]

**删除 (二次确认):**
1. 点击 🗑️ → 卡片边框变红 + 按钮变为红色"确认删除"
2. 再次点击 → 执行删除
3. 4 秒无操作 / 进入编辑 / 点击名称区域 → 取消确认

---

## 6. API 协议适配

### OpenAI 兼容协议

大多数国内模型 (DeepSeek / 通义千问 / 智谱 / Kimi / 硅基流动) 都实现了 OpenAI 的 `/chat/completions` 协议。

```
POST {baseURL}/chat/completions
{
  "model": "deepseek-chat",
  "temperature": 0.3,
  "max_tokens": 1024,
  "stream": true,
  "messages": [
    {"role": "system", "content": "Translate zh to en. Output translation only."},
    {"role": "user", "content": "你好世界"}
  ]
}
```

**注意:** `stream_options` 字段已移除，因为它不被 DeepSeek / Ollama 等兼容 API 支持，会导致流式请求失败。

### Anthropic Messages API

```
POST {baseURL}/v1/messages
Headers: x-api-key, anthropic-version: 2023-06-01
{
  "model": "claude-3-haiku-20240307",
  "max_tokens": 1024,
  "messages": [{"role": "user", "content": "Translate..."}]
}
```

流式 SSE 事件: `content_block_delta` → `delta.text`

### Gemini GenerateContent API

```
POST {baseURL}/models/{model}:generateContent (or :streamGenerateContent?alt=sse)
Headers: x-goog-api-key
{
  "contents": [{"parts": [{"text": "prompt"}]}],
  "generationConfig": {"temperature": 0.3, "maxOutputTokens": 1024}
}
```

**安全:** 所有 Gemini API Key 通过 `x-goog-api-key` 请求头传递，不使用 URL 查询参数。

---

## 7. 安全设计

| 关注点 | 实现 |
|--------|------|
| API Key 存储 | macOS Keychain (system-level encrypted) |
| API Key 传输 | HTTPS + HTTP Header (不通过 URL 参数) |
| 内存安全 | 仅启用的 provider 加载 Key；无 Key 日志输出 |
| 剪贴板保护 | `defer` 确保取词操作后恢复用户原始剪贴板内容 |
| 并发安全 | `translateGeneration` + `guard gen ==` 模式防止旧任务污染 |

---

## 8. 构建与分发

### 本地构建

```bash
cd AiTranslator
swift build                     # Debug 构建
./build.sh                      # Release + 打包 .app + 签名
```

### build.sh 流程

```
1. 清理旧 .app
2. swift build -c release --arch arm64
3. 复制二进制到 .app/Contents/MacOS/
4. 生成 Info.plist (LSUIElement=true → 无 Dock 图标)
5. codesign --force --deep --sign - (ad-hoc 签名)
6. xattr -cr (移除 quarantine 扩展属性)
```

### Info.plist 关键配置

| Key | Value | 说明 |
|-----|-------|------|
| `CFBundleIdentifier` | `com.aitranslator.app` | |
| `LSUIElement` | `true` | 纯菜单栏应用，无 Dock 图标 |
| `LSMinimumSystemVersion` | `14.0` | |
| `CFBundleVersion` | `0.1` | |

### 分发给他人

ad-hoc 签名可防止 Gatekeeper "应用已损坏" 提示，但不绑定开发者身份。

**接收方如仍提示损坏:**
```bash
xattr -cr AiTranslator.app
```

**正式分发:** 需要 Apple Developer Program + Developer ID 证书 + 公证 (`notarytool`)

---

## 9. 已修复问题清单

| # | 问题 | 严重度 | 修复 |
|---|------|--------|------|
| 1 | Gemini API Key 通过 URL 查询参数传递 (4 处) | 🔴 安全 | 改为 `x-goog-api-key` 请求头 |
| 2 | `captureViaAX()` 中 `as! AXUIElement` force cast | 🔴 崩溃 | 改用 `CFGetTypeID` 安全校验 |
| 3 | `stream_options` 导致兼容 API 流式失败 | 🟡 功能 | 移除该字段 |
| 4 | 版本号不一致 (代码 2.0 vs plist 1.0) | 🟡 维护 | 统一为 0.1 |
| 5 | 重试条件仅匹配中文"网络" | 🟡 功能 | 扩展为匹配中英文网络关键词 |
| 6 | 剪贴板恢复非原子 (崩溃丢失数据) | 🟡 健壮性 | 改用 `defer` 确保恢复 |
| 7 | 剪贴板监听无去抖 | 🟡 体验 | 添加 2 秒最小间隔 |
| 8 | `onTapGesture(count: 2)` 导致删除按钮无响应 | 🟡 Bug | 改为单击 + 二次确认红色边框机制 |
| 9 | 启动时预加载所有 Key 触发多次 Keychain 弹窗 | 🟡 体验 | 改为 `ensureKey()` 懒加载 |
| 10 | 无签名导致分发后 "应用已损坏" | 🟡 分发 | build.sh 添加 ad-hoc codesign + xattr -cr |
