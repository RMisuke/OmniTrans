# AiTranslator v0.2 — 项目文档

> 版本：0.2  |  平台：macOS 14+  |  Swift 5.9  |  SwiftUI + AppKit  
> 更新日期：2026-07-01  |  二进制：3.1 MB  |  .app：3.9 MB

---

## 一、架构总览

```
┌─────────────────────────────────────────────────────┐
│                    AiTranslatorApp                    │
│                   (MenuBarExtra)                      │
├─────────────────────────────────────────────────────┤
│  AppDelegate                                         │
│  ├─ HotkeyManager (⌥D / OCR)                        │
│  ├─ ClipboardMonitor                                │
│  ├─ FloatingPanel                                    │
│  ├─ Onboarding window                                │
│  └─ OCRSelectionOverlay                              │
├─────────────────────────────────────────────────────┤
│  AppState (ObservableObject, @MainActor)             │
│  ├─ providers: [APIProvider]                         │
│  ├─ translationHistory: [HistoryEntry]               │
│  ├─ translate() / retryTranslate()                   │
│  └─ 语言 / 历史 CRUD                                  │
├─────────────────────────────────────────────────────┤
│  Services                                            │
│  ├─ TranslationActor (actor, streaming SSE)          │
│  ├─ TranslationService (non-streaming fallback)      │
│  ├─ APITestService (连接测试 / 模型列表)               │
│  └─ KeychainManager (API Key 加密存储)                │
├─────────────────────────────────────────────────────┤
│  Views (SwiftUI)                                     │
│  ├─ ContentView         主窗口                        │
│  ├─ TranslationView     翻译面板                      │
│  ├─ FloatingTranslationView  悬浮翻译窗               │
│  ├─ SettingsView        设置（API / 通用 / 历史 / 关于）│
│  ├─ ProviderCardView    API 卡片                      │
│  ├─ OnboardingView      首次启动引导                   │
├─────────────────────────────────────────────────────┤
│  Models                                              │
│  ├─ APIProvider         提供商模型                     │
│  ├─ ProviderTemplate    12 个预设模板                   │
│  └─ TranslationLanguage 13 种语言                      │
└─────────────────────────────────────────────────────┘
```

### 文件清单（18 个源文件）

| 层级 | 文件 | 职责 |
|------|------|------|
| 入口 | `App.swift` | MenuBarExtra + AppDelegate |
| 模型 | `Models/APIProvider.swift` | 提供商数据结构 |
| 模型 | `Models/AppState.swift` | 全局状态 + 翻译调度 |
| 模型 | `Models/ProviderTemplates.swift` | 12 个 API 预设模板 |
| 模型 | `Models/TranslationConfig.swift` | 13 种语言定义 |
| 服务 | `Services/TranslationActor.swift` | actor 隔离的流式翻译 (SSE) |
| 服务 | `Services/TranslationService.swift` | 非流式翻译 fallback |
| 服务 | `Services/APITestService.swift` | API 连接测试 + 模型拉取 |
| 服务 | `Services/HotkeyManager.swift` | 双热键 + 划词取词 + OCR |
| 服务 | `Services/OCRSelectionOverlay.swift` | OCR 框选全屏 overlay |
| 服务 | `Services/ClipboardMonitor.swift` | 剪贴板轮询监听 |
| 服务 | `Services/FloatingPanel.swift` | NSPanel 悬浮翻译窗 |
| 工具 | `Utils/KeychainManager.swift` | 钥匙串加密存储 |
| 视图 | `Views/ContentView.swift` | 主窗口容器 |
| 视图 | `Views/TranslationView.swift` | 完整翻译面板 |
| 视图 | `Views/FloatingTranslationView.swift` | 悬浮翻译窗内容 |
| 视图 | `Views/SettingsView.swift` | 设置页（4 个 tab） |
| 视图 | `Views/ProviderCardView.swift` | API 提供商卡片 |
| 视图 | `Views/OnboardingView.swift` | 3 页首次引导 |

---

## 二、核心流程

### 2.1 翻译流程

```
用户按 ⌥D / 选中文本
  → HotkeyManager.capture()
    → ① Cmd+C 模拟（需辅助功能权限）
    → ② AX API 直接读取选中文本
  → AppDelegate.fire(text:)
    → AppState.resetForNew() → showFloatingPanel() → translate()
  → AppState.doTranslate()
    → TranslationActor.resolveWithFallback()  // Ollama 本地兜底
    → TranslationActor.translateStream()      // SSE 流式
    → 失败 → TranslationService.translate()   // 非流式 fallback
    → 失败 → 网络错误自动重试 1 次
  → 结果显示在 FloatingPanel / ContentView
```

### 2.2 OCR 框选流程

```
用户按 ⌥F
  → HotkeyManager.onOCRHotkey
  → AppDelegate.startOCRSelection()
  → OCRSelectionOverlay.beginCapture()
    → 全屏半透明遮罩
    → 鼠标拖拽画框 → 蓝色选框 + 尺寸标签
    → 松开 → CGWindowListCreateImage（排除遮罩自身）
    → Vision VNRecognizeTextRequest
    → 空间排序（Y 分组 → X 左到右）
  → AppState.translate()
  → FloatingPanel 显示结果
```

### 2.3 事件分发

```
Carbon EventHotKey 统一回调 unifiedHotkeyCallback
  → GetEventParameter → EventHotKeyID
    → id == 1 → onHotkey → captureWithoutOCR() → 翻译热键
    → id == 2 → onOCRHotkey → OCR 框选热键
```

---

## 三、支持的服务商

12 个内置 API 模板，均使用 OpenAI Chat Completions 兼容协议：

| 模板 | 模型 |
|------|------|
| OpenAI | gpt-4o-mini |
| DeepSeek | deepseek-chat |
| Ollama (本地) | qwen2.5:7b |
| 硅基流动 | Qwen/Qwen2.5-7B-Instruct |
| Groq | llama-3.1-8b-instant |
| Together AI | Llama-3.1-8B-Instruct |
| 智谱 GLM-4-Plus | glm-4-plus |
| 智谱 GLM-4-Flash | glm-4-flash（免费） |
| Kimi (月之暗面) | moonshot-v1-8k |
| 通义千问 | qwen-turbo |
| Anthropic Claude | claude-3-haiku |
| Google Gemini | gemini-2.0-flash |

API Key 通过 macOS Keychain 加密存储，`kSecAttrAccessibleAfterFirstUnlock`。

---

## 四、翻译语言

13 种语言：自动检测、中文、English、日本語、한국어、Français、Deutsch、Español、Русский、Português、Italiano、العربية、ไทย、Tiếng Việt。

---

## 五、完整修复与改进清单（#1–#28）

### 🔴 安全（2 项）

| # | 描述 |
|---|------|
| 1 | Gemini API Key URL 泄露 → 改为 x-goog-api-key 请求头 |
| — | URL force unwrap → 安全解包 |

### 🔴 崩溃（2 项）

| # | 描述 |
|---|------|
| 2 | AXUIElement force cast → CFGetTypeID 运行时校验 |
| 11 | v0.2 快捷键闪退（NSPasteboardItem + Coordinator）→ 回退单体架构 |

### 🔴 Bug（2 项）

| # | 描述 |
|---|------|
| 22 | OCR 坐标系 Y 轴翻转（CG vs AppKit） |
| 25 | 双热键事件冲突 → 统一回调 + EventHotKeyID 分发 |

### 🟡 功能（4 项）

| # | 描述 |
|---|------|
| 3 | stream_options 兼容性 → 移除该字段 |
| 5 | 重试条件 → 多语言网络错误关键词 |
| 10 | 剪贴板去抖 → 2 秒最小间隔 |
| 20 | OCR 自适应三档 + 空间排序 + 去重 |

### 🟡 Bug（6 项）

| # | 描述 |
|---|------|
| 7 | 删除按钮手势冲突 → 二次确认 |
| 13 | 设置 UI 不刷新 → @AppStorage |
| 15 | 模板选择窗口关闭 → 内嵌替代 sheet |
| 23 | OCR 标签干扰 / 引导尺寸 / 程序退出 |
| 27 | 关于页导航栏上移 → ScrollView |
| 28 | 翻译热键误触发 OCR → capture 移除 OCR fallback |

### 🟡 健壮性（1 项）

| # | 描述 |
|---|------|
| 6 | 剪贴板恢复非原子 → defer 块 |

### 🟡 体验（3 项）

| # | 描述 |
|---|------|
| 8 | Keychain 懒加载 |
| 18 | 引导窗口手动翻到最后一页才消失 |
| 23 | 引导窗口尺寸逐步增大至 560×640 |

### 🟡 维护（2 项）

| # | 描述 |
|---|------|
| 4 | 版本号统一 |
| 16 | 冗余代码精简（~340 行 / 3 个 Store 文件删除） |

### 🟡 分发（1 项）

| # | 描述 |
|---|------|
| 9 | ad-hoc 签名 + quarantine 清除 |

### ✨ 功能增强（7 项）

| # | 描述 |
|---|------|
| 12 | 翻译快捷键录制 + 还原默认 |
| 14 | 应用图标 + 关于页 icon |
| 17 | 首次启动 3 页引导窗口 |
| 19 | 关于页重置引导标记按钮 |
| 21 | OCR 框选取词（⌥F） |
| 24 | OCR 快捷键自定义 |
| 26 | 翻译历史最大记录数可配置（10–500） |

**合计：30 项**

---

## 六、已知问题

| 问题 | 严重度 | 说明 |
|------|--------|------|
| `CGWindowListCreateImage` 弃用 | 🟡 | macOS 14 弃用，建议迁移 ScreenCaptureKit |
| Vision OCR 仅单屏 | 🟡 | 多显示器场景下 overlay 仅覆盖主屏 |
| 无流式响应中断重连 | 🟡 | SSE 断连后依赖非流式 fallback |
| Anthropic / Gemini 非流式 | 🟡 | 仅 OpenAI 协议有流式，Anthropic/Gemini 走非流式 fallback |
| 键帽组件重复 | 🟡 | ContentView 和 SettingsView 各有一套 keycapView |
| OCR 标签显示位置 | 🟡 | 框选区域贴近屏幕边缘时标签可能被裁剪 |
| 无自动更新机制 | 🟡 | 需手动替换 .app |

---

## 七、构建与分发

```bash
# 开发构建
cd AiTranslator && swift build

# 发布打包
./build.sh
# 输出: .build/AiTranslator.app (3.9 MB, arm64, ad-hoc 签名)

# 运行
open .build/AiTranslator.app

# 重置首次启动引导（测试用）
defaults delete com.aitranslator.app has_completed_onboarding
```

### Info.plist 关键配置

| 键 | 值 |
|----|-----|
| CFBundleIdentifier | com.aitranslator.app |
| CFBundleVersion | 0.2 |
| LSMinimumSystemVersion | 14.0 |
| LSUIElement | true（无 Dock 图标） |
