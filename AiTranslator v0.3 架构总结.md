# OmniTrans v0.3 — 架构总结

> **项目**：OmniTrans (AI 翻译菜单栏应用)  
> **平台**：macOS 14+  ·  arm64  
> **版本**：0.3  
> **总代码量**：30 文件 · 4,891 行 Swift（不含 App.swift）  
> **构建方式**：SwiftPM + ad-hoc codesign  
> **日期**：2026-07-02

---

## 一、总体架构

```
┌─────────────────────────────────────────────────────┐
│                      App.swift                       │
│  @main · AppDelegate · FloatingPanel · HotkeyManager  │
└────────┬──────────────────────────────┬─────────────┘
         │                              │
    ┌────▼─────┐                   ┌────▼──────────┐
    │  Views/  │                   │   Services/   │
    │  8 视图   │◄────@Published────│  12 服务模块   │
    └──────────┘                   └───────┬───────┘
         │                                 │
         │                          ┌──────▼──────┐
         │                          │   Models/   │
         └──────────────────────────│  5 数据模型  │
                                    └──────┬──────┘
                                           │
                                    ┌──────▼──────┐
                                    │   Utils/    │
                                    │ 2 工具模块   │
                                    └─────────────┘
```

**状态管理**：`@MainActor class AppState: ObservableObject` — 单体响应式状态机，所有视图通过 `@ObservedObject` 绑定。

**并发模型**：`TranslationActor (actor)` 隔离所有网络请求，通过 `AsyncThrowingStream` 流式回传。

---

## 二、后端架构

### 2.1 翻译管道（Translation Pipeline）

```
用户输入 → AppState.translate()
    │
    ├─ isWord? ──────────────────────────────┐
    │   ├─ macOSNative → MacOSNativeProvider  │
    │   ├─ LLM dict  → TranslationActor       │
    │   └─ MT dict   → (fallback translate)   │
    │                                         │
    └─ !isWord ───────────────────────────────┤
        ├─ macOSNative → SystemTranslationEngine
        ├─ AI/LLM    → TranslationActor (stream)
        └─ MT        → TranslationActor_MT (mock stream)
```

### 2.2 核心服务模块

| 文件 | 行 | 职责 |
|------|----|------|
| `TranslationActor.swift` | 480 | AI/LLM 流式翻译调度（OpenAI/Claude/Gemini/本地 Ollama）；构建 System Prompt + Dictionary Hint；`performMockStream()` 管道桥接 |
| `TranslationActor_MT.swift` | 139 | 传统 MT 翻译（Google/Bing/阿里云）+ `AlibabaCloudSigner` HMAC-SHA1 签名 |
| `TranslationService.swift` | 172 | 非流式翻译回退 + `TranslationError` 枚举 |
| `MacOSNativeProvider.swift` | 111 | macOS 原生词典 (`DCSCopyTextDefinition`) + `Translation` 框架段落翻译 |
| `SystemTranslationEngine.swift` | 91 | macOS 15 Translation 框架封装；`@_silgen_name` 弱链接低版本降级 |
| `TextCaptureStrategies.swift` | 162 | 职责链取词：AX → Clipboard → Vision OCR |
| `HotkeyManager.swift` | 277 | 全局快捷键注册 (`⌥⇧D` / `⌥⇧S`) + Carbon 事件桥接 |
| `ClipboardMonitor.swift` | 76 | `changeCount` 轮询 + `suppressNext` 防回环 |
| `FallbackRouter.swift` | 47 | Ollama 可用性探测 + 路由重写 |
| `OCRSelectionOverlay.swift` | 257 | 框选图层 + Vision OCR 识别 |
| `FloatingPanel.swift` | 69 | NSPanel 悬浮窗（弹性弹出动画、鼠标跟随） |
| `APITestService.swift` | 227 | API 连接测试 + 模型列表拉取 |

### 2.3 数据模型

| 文件 | 行 | 职责 |
|------|----|------|
| `AppState.swift` | 338 | 中心状态机：`inputText / translatedText / isTranslating / dictionaryEntry / providers / dictProviderID / detectedIsWord` + `translate()` 路由 |
| `APIProvider.swift` | 88 | `ProviderKind` 枚举（8 种：openAI/openAICompat/anthropic/gemini/macOSNative/googleMT/bingMT/alibabaMT）+ 模型字段 |
| `DictionaryEntry.swift` | 101 | 词典结构化模型：`word / phonetic / definitions[pos, meaning] / examples[en, zh]` + JSON 解析 |
| `ProviderTemplates.swift` | 42 | 预设模板：`.ai` 13 个 LLM 模板 + `.mt` 3 个 MT 模板 |

### 2.4 存储架构

```
ProviderStorageManager（持久化代理）
    ├─ UserDefaults（非敏感：provider 元数据 / 语言设置 / 历史记录）
    └─ KeychainManager（敏感字段：AES-256-GCM 加密文件）
         └─ ~/Library/Application Support/OmniTrans/secrets.json
              ├─ 加密：AES.GCM.seal() + HKDF-SHA256(machineUUID)
              ├─ 格式：nonce(12) + cipher + tag(16)
              └─ 无 entitlements、无 Keychain 授权弹窗
```

### 2.5 翻译供应商矩阵

| 供应商 | ProviderKind | 流式 | 认证方式 |
|--------|-------------|------|---------|
| OpenAI | `.openAI` | ✅ SSE | API Key (Bearer) |
| OpenAI 兼容 | `.openAICompat` | ✅ SSE | API Key (Bearer) |
| Anthropic | `.anthropic` | ✅ SSE | API Key (x-api-key) |
| Gemini | `.gemini` | ✅ SSE | API Key (x-goog-api-key) |
| macOS 原生 | `.macOSNative` | ✅ AsyncSequence | 无（系统内置） |
| Google MT | `.googleMT` | ❌ 单次 | API Key (URL query) |
| Bing MT | `.bingMT` | ❌ 单次 | Key + Region (Headers) |
| 阿里云 MT | `.alibabaMT` | ❌ 单次 | AccessKey ID + Secret (HMAC-SHA1) |

---

## 三、前端架构

### 3.1 视图树

```
App.swift
├── ContentView（菜单栏主窗口 420×460）
│   ├── TranslationView（翻译面板）
│   │   ├── headerBar（标题 + Provider 选择）
│   │   ├── languageBar（源/目标语言选择器）
│   │   ├── inputArea（文本输入 + 单词检测提示）
│   │   └── outputArea（流式结果 + 错误 + 拷贝）
│   └── bottomBar（快捷键提示 + 版本 + 退出）
│
├── FloatingTranslationView（悬浮翻译卡片 360×380）
│   ├── dragHandle + headerView
│   ├── sourceBlock（原文 + 单词检测提示）
│   ├── resultBlock（进度条 / 流式文本 / 词典卡片 / 原生词典）
│   └── bottomBar（语言切换 + 拷贝 + 翻译按钮）
│
├── SettingsView（设置面板 · 5 页）
│   ├── [0] API 配置（ProviderCardView 列表 + 模板）
│   ├── [1] 翻译（词典模型选择 + 语言方向 + 外观）
│   ├── [2] 通用（快捷键录制 + 剪贴板 + 外观模式）
│   ├── [3] 历史（翻译记录）
│   └── [4] 关于
│
└── OnboardingView（首次启动引导 · 3 页）
    ├── 权限说明（辅助功能 + 屏幕录制）
    ├── 安全说明（AES-256 加密存储）
    └── 功能一览（6 项 v0.3 功能）
```

### 3.2 视图文件清单

| 文件 | 行 | 职责 |
|------|----|------|
| `FloatingTranslationView.swift` | 218 | 悬浮翻译卡片：原文/结果/词典双模式 |
| `TranslationView.swift` | 193 | 菜单栏主界面：输入/输出/Provider 切换 |
| `ContentView.swift` | 87 | 菜单栏根容器：翻译 ↔ 设置切换 + 底部栏 |
| `SettingsView.swift` | 732 | 5 页设置面板（最大文件） |
| `ProviderCardView.swift` | 197 | 单个 Provider 编辑卡片（动态 MT/AI 字段） |
| `OnboardingView.swift` | 164 | 首次启动 3 页引导 |
| `DictionaryCardView.swift` | 90 | AI 词典卡片（词性色标 + 例句） |
| `NativeDictionaryView.swift` | 60 | macOS 原生词典排版（Serif 字体 + 斑马行） |

### 3.3 设计系统

`AppTheme.swift`（113 行）统一全局样式：

- **颜色**：`textPrimary / textSecondary / textTertiary / textAccent` + `bgSolid / bgSubtle / bgFloating` + 语义色
- **字号**：`caption=11 / label=12 / body=14 / headline=16 / title=20`
- **间距**：`xs=4 / sm=8 / md=12 / lg=16`
- **View 扩展**：`cardStyle() / badgeStyle() / hintStyle() / wordHintBar() / floatingPanelStyle()`
- **面板背景**：`.regularMaterial` 毛玻璃材质

---

## 四、已实现功能

| # | 功能 | 状态 |
|---|------|------|
| 1 | 全局快捷键划词翻译（`⌥⇧D`） | ✅ |
| 2 | OCR 框选翻译（`⌥⇧S`） | ✅ |
| 3 | 悬浮翻译卡片（弹性弹出 + 鼠标跟随） | ✅ |
| 4 | 菜单栏完整翻译窗口 | ✅ |
| 5 | 智能词典模式（单词自动检测 → JSON 输出 → 卡片排版） | ✅ |
| 6 | macOS 原生离线词典（CoreServices） | ✅ |
| 7 | macOS 原生翻译框架（macOS 15+ Translation） | ✅ |
| 8 | 低版本降级（macOS 14 可用原生词典但无 ANE 翻译） | ✅ |
| 9 | 12+ AI 模型支持（OpenAI/Claude/Gemini/通义千问/DeepSeek/SenseNova…） | ✅ |
| 10 | 3 种传统机器翻译（Google / Bing / 阿里云） | ✅ |
| 11 | 词典模式独立模型选择 | ✅ |
| 12 | 流式 SSE 翻译 + MT 单次包装 | ✅ |
| 13 | 灾害恢复（Ollama 本地 Fallback） | ✅ |
| 14 | 剪贴板监听自动翻译 | ✅ |
| 15 | API 密钥 AES-256 本地加密存储 | ✅ |
| 16 | 深色/浅色/跟随系统外观切换 | ✅ |
| 17 | 翻译历史记录（保存/清除） | ✅ |
| 18 | Provider 管理（添加/编辑/删除/测试/拉模型） | ✅ |
| 19 | MT 专属配置界面（动态标签） | ✅ |
| 20 | 半透明毛玻璃 UI | ✅ |

---

## 五、存在问题

### 5.1 功能缺失（v0.3 spec 未完成）

| 任务 | 原定 v0.3 需求 | 状态 |
|------|---------------|------|
| 0% CPU 剪贴板监控 | 废弃 Timer 轮询，改用 NSWorkspace 通知 | ❌ 未实现 |
| Vision OCR 对象复用 | VNRecognizeTextRequest 全局单例 + 低优先级队列 | ❌ 未实现 |
| 原地翻译替换 | `⌥⇧D` 选中文本原地替换（CGEvent 模拟键盘） | ❌ 未实现 |
| 专家会诊模式 | 多 Provider 并发翻译 + 网格卡片对比 | ❌ 未实现 |
| 存储职责剥离 | ProviderStorageManager 已做 ✅（#48 部分完成） | ⚠️ 仍有部分 CRUD 在 AppState |
| 取词职责链 | 协议 `TextCaptureStrategy` 已做 ✅（#4） | ✅ 完成 |

### 5.2 已知 Bug

| # | 问题 | 严重度 |
|---|------|--------|
| 1 | ~~API Key 重启丢失~~ → 已修复（#55 切换到文件存储） | ✅ 已修复 |
| 2 | ~~阿里云 MT 签名失败~~ → 已修复（#43 CryptoKit） | ✅ 已修复 |
| 3 | ~~Keychain entitlements 导致 app 无法启动~~ → 已修复 | ✅ 已修复 |
| 4 | macOS 15 TranslationSession 在 macOS 14/15 均报错 "not found" | ⚠️ 降级可用 |
| 5 | 阿里云 MT 使用 HTTP 明文（需 ATS 例外） | ⚠️ 已加 Info.plist 例外 |
| 6 | SenseNova API rpm exhausted 频繁出现 | ⚠️ 免费额度限制 |

### 5.3 架构债务

| 问题 | 影响 |
|------|------|
| `SettingsView.swift` 732 行单一文件，包含 5 页全部逻辑 | 维护困难，应拆分为独立 View 文件 |
| `AppState.swift` 338 行，`translate()` 和 `doTranslate()` 逻辑交错 | 路由逻辑复杂，分支多 |
| MT 翻译无流式支持，用 `performMockStream()` 模拟 | 用户体验不如真流式 |
| `TranslationActor` 同时处理 LLM 流式 + MT 单次 + 词典构建 | 职责过重 |
| OnboardingView 仍使用部分 `.secondary` 而非 `AppTheme` | 样式不统一 |

---

## 六、文件结构

```
Sources/OmniTrans/
├── App.swift                            (88 行)
├── Models/
│   ├── APIProvider.swift                (88 行) — ProviderKind 枚举 + 模型
│   ├── AppState.swift                   (338 行) — 中心状态机
│   ├── DictionaryEntry.swift            (101 行) — 词典数据模型
│   ├── ProviderTemplates.swift          (42 行) — AI+MT 预设模板
│   └── TranslationConfig.swift          (62 行) — 语言配置
├── Services/
│   ├── APITestService.swift             (227 行)
│   ├── ClipboardMonitor.swift           (76 行)
│   ├── FallbackRouter.swift             (47 行)
│   ├── FloatingPanel.swift              (69 行)
│   ├── HotkeyManager.swift              (277 行)
│   ├── MacOSNativeProvider.swift        (111 行)
│   ├── OCRSelectionOverlay.swift        (257 行)
│   ├── ProviderStorageManager.swift     (162 行)
│   ├── SystemTranslationEngine.swift    (91 行)
│   ├── TextCaptureStrategies.swift      (162 行)
│   ├── TranslationActor.swift           (480 行)
│   ├── TranslationActor_MT.swift        (139 行)
│   └── TranslationService.swift         (172 行)
├── Utils/
│   ├── AppTheme.swift                   (113 行)
│   └── KeychainManager.swift            (136 行)
└── Views/
    ├── ContentView.swift                (87 行)
    ├── DictionaryCardView.swift         (90 行)
    ├── FloatingTranslationView.swift    (218 行)
    ├── NativeDictionaryView.swift       (60 行)
    ├── OnboardingView.swift             (164 行)
    ├── ProviderCardView.swift           (197 行)
    ├── SettingsView.swift               (732 行)
    └── TranslationView.swift            (193 行)

总计: 30 文件 · 4,891 行
```

---

## 七、构建命令

```bash
cd "/Users/chensinuo/Codex/AI Translater"

# 编译
swift build

# ARM 打包
bash build-arm.sh

# 运行
open .build/OmniTrans-arm64.app
```

**签名方式**：ad-hoc (`codesign --force --deep --sign -`)  
**无 entitlements**：Keychain 功能已替换为本地加密文件存储  
**Bundle ID**：`com.omnitrans.arm64`

---

*文档由 Codex 基于当前代码库自动生成 — 2026-07-02*
