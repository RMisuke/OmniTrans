# OmniTrans

> 轻量 macOS 菜单栏翻译工具 · 零三方依赖 · 多引擎 · 本地优先 · Swift 6.4

OmniTrans 是一款运行在 macOS 菜单栏的 AI 翻译应用，支持快捷键划词翻译、OCR 区域截图取词、智能词典、多 API 提供商切换、流式翻译输出及 macOS 原生离线翻译引擎（macOS 26+ Neural Engine）。

---

## 功能特色

- **菜单栏常驻** — 菜单栏图标，一键唤出，不干扰工作流
- **划词翻译** — `⌥D` 选中文本自动翻译，支持 Cmd+C + AX 双回退 + 上下文感知
- **OCR 取词** — `⌥F` 框选屏幕区域，Vision OCR `.fast` 模式识别文字并翻译（零拷贝 CVPixelBuffer 直通）
- **智能词典** — 输入单词自动切换词典模式，展示音标、词性、释义、例句（AI + macOS 原生双源）
- **上下文感知** — 双向滑动窗口截取划词前后文本（100-500 字符 5 档强度），注入 LLM Prompt 提升翻译质量
- **多翻译引擎**
  - **AI 大模型** — OpenAI · Claude · Gemini · 通义千问 · DeepSeek · SenseNova 等
  - **机器翻译** — Google · Bing · 阿里云 · 火山翻译
  - **macOS 原生** — 系统离线词典 (`DCSCopyTextDefinition`) + Neural Engine 翻译 (`TranslationSession`, macOS 26+)
- **流式输出** — SSE 实时逐字输出，30ms 批处理 Token 节流（~33fps）
- **三级降级** — AI → MT → macOS Native 自动逐级回退
- **翻译历史** — JSONL 流式持久化 + 搜索 + 可展开卡片 + 内联词典预览
- **原位替换** — `⌥R` 将翻译结果直接粘贴到原文位置
- **TTS 朗读** — 翻译结果与词典词汇 Premium 语音朗读
- **快捷键录制** — 翻译/OCR/替换热键均可自定义
- **自定义提示词** — 翻译系统提示词可自定义，支持变量替换
- **悬浮框 API 切换** — 划词翻译悬浮窗内可直接切换翻译引擎
- **深色/浅色/系统** — 三种外观模式切换
- **隐私优先** — AES-256-GCM 本地加密存储密钥
- **零三方依赖** — 纯 Swift 6.4 + AppKit / SwiftUI / CryptoKit 构建

---

## 项目结构

```
OmniTrans/
├── Package.swift
├── build-arm.sh / build-intel.sh / build.sh
├── doc/v0.5/            ← 架构文档
├── Resource/icon/
└── Sources/OmniTrans/
    ├── App.swift
    ├── Models/           ← APIProvider, AppState, DictionaryEntry, Stores, TranslationConfig...
    ├── Services/         ← TranslationActor, TranslationPipeline, NativeDictionaryParser,
    │                       OCRSelectionOverlay, CaptureService, HotkeyManager, HistoryActor...
    ├── Utils/            ← AppTheme, AnimationGate, KeychainManager, MemoryPurgeHelper
    └── Views/            ← TranslationView, FloatingTranslationView, SettingsView,
                            NativeDictionaryView, ContentView, Components...
```

---

## 快速开始

### 系统要求

- macOS 14.0+
- Xcode 16+ 或 Swift 6.4+ 命令行工具

### 构建

```bash
git clone https://github.com/RMisuke/OmniTrans.git
cd OmniTrans
bash build-arm.sh
```

构建产物：`.build/OmniTrans-arm64.app`

### 运行

```bash
open .build/OmniTrans-arm64.app
```

首次启动弹出引导窗口，按提示授予辅助功能和屏幕录制权限。

---

## 使用指南

| 操作 | 快捷键 | 说明 |
|------|--------|------|
| 划词翻译 | `⌥D` | 选中文本后按下，悬浮窗翻译 |
| OCR 取词 | `⌥F` | 框选屏幕区域，识别文字翻译 |
| 原位替换 | `⌥R` | 将翻译结果直接粘贴到原文 |
| 打开设置 | 菜单 → ⚙️ | API 密钥、快捷键、外观等 |
| 退出 | `⌘Q` | 退出应用 |

---

## 架构概要

```
用户操作 → HotkeyManager (Carbon) → SlidingWindowContextCapture
                                          ↓
                                    AppState (@MainActor)
                                          ↓
                              TranslationPipeline (actor, 30ms 批处理)
                               → TranslationEngineFactory → 引擎 (AI/MT/Native)
                                          ↓
                              TranslationSessionStore (@Observable 字段级)
                                          ↓
                              StreamingTextView / NativeDictionaryView
```

### 核心设计原则

- **零三方依赖** — 纯 Swift 标准库 + macOS 系统框架
- **Swift 6 并发安全** — `actor` 隔离 + `@MainActor` + `@Observable` 字段级状态
- **加密存储** — CryptoKit AES-256-GCM + HKDF 密钥派生
- **流式节流** — 30ms 批处理 Token，防 Liquid Glass 重合成
- **历史 JSONL 流式写入** — `FileHandle.seekToEndOfFile` O(1) 追加
- **网络层复用** — 全局 `sharedURLSession` HTTP/2 多路复用 + 预连接
- **OCR 零拷贝** — `SCStream` → `CVPixelBuffer` → Vision，无 CGImage 编解码

---

## 构建命令

```bash
# Debug
swift build

# 严格并发检查
swift build -Xswiftc -strict-concurrency=complete

# Release
swift build -c release

# 打包
bash build-arm.sh
```

---

## 许可证

MIT
