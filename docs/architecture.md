# OmniTrans 系统架构文档

> 版本: v0.9 | 平台: macOS 14+ | 语言: Swift 5.9 (StrictConcurrency)

---

## 1. 概览

OmniTrans 是一款 macOS 菜单栏驻留的智能翻译工具，支持三大翻译路径：**AI/LLM 流式翻译**（OpenAI、Claude、Gemini、Ollama）、**传统 MT 引擎**（Google、Bing、阿里云、火山）、以及 **macOS 原生离线翻译+词典**。通过全局快捷键划词取词，结合 OCR 屏幕识别与双向滑动窗口上下文感知技术，提供即时的多引擎翻译与查词体验。

---

## 2. 项目结构

```
Sources/OmniTrans/
├── App.swift                          # @main 入口 + AppDelegate
├── Models/
│   ├── APIProvider.swift              # 翻译引擎供应商模型
│   ├── AppState.swift                 # 全局状态（@MainActor ObservableObject）
│   ├── DictionaryEntry.swift          # 词典条目模型
│   ├── PromptProfile.swift            # 自定义提示词模型
│   ├── ProviderTemplates.swift        # 供应商模板
│   ├── Stores.swift                   # @Observable 细分状态仓库
│   └── TranslationConfig.swift        # 语言枚举定义
├── Services/
│   ├── TranslationEngineProtocol.swift # 翻译引擎统一协议
│   ├── TranslationEngineFactory.swift  # 引擎工厂（开闭原则）
│   ├── TranslationActor.swift          # AI/LLM SSE 流式 + MT 引擎
│   ├── TranslationActor_MT.swift       # MT 签名工具（阿里云/火山）
│   ├── TranslationService.swift        # 非流式翻译回退
│   ├── TranslationPipeline.swift       # Token 批处理管线
│   ├── MacOSNativeEngineAdapter.swift  # macOS 原生引擎适配器
│   ├── MacOSNativeProvider.swift       # 原生词典/翻译提供者
│   ├── NativeDictionaryParser.swift    # 原生词典解析
│   ├── SystemTranslationEngine.swift   # macOS 26+ ANE 翻译
│   ├── FallbackRouter.swift            # 本地 Ollama 故障转移
│   ├── ContextAwareService.swift       # 上下文感知提示词注入
│   ├── HistoryActor.swift              # 翻译历史持久化
│   ├── HotkeyManager.swift             # Carbon 全局快捷键
│   ├── CaptureService.swift            # SCStream 屏幕捕获
│   ├── TextCaptureStrategies.swift     # 取词策略链
│   ├── OCRSelectionOverlay.swift       # OCR 框选叠加层
│   ├── ClipboardMonitor.swift          # 剪贴板监控
│   ├── TextReplacementService.swift    # 原位替换粘贴
│   ├── TTSEngine.swift                 # 文本朗读
│   ├── WindowManager.swift             # 窗口生命周期管理
│   ├── FloatingPanel.swift             # 浮动翻译面板
│   ├── OmniPanel.swift                 # 基础面板类
│   ├── SettingsPanel.swift             # 设置面板
│   ├── ProviderStorageManager.swift    # 供应商配置持久化
│   └── APITestService.swift            # API 连通性测试
├── Views/
│   ├── FloatingTranslationView.swift   # 浮动面板工作区根视图
│   ├── WorkspaceRuntime.swift          # 插件运行时（v0.8）
│   ├── WorkspacePlugins.swift          # 翻译/查词/历史插件
│   ├── WorkspaceFramework.swift        # 工作区协议定义
│   ├── WorkspaceComponents.swift       # 共享 UI 组件
│   ├── ContentView.swift               # 设置内容
│   ├── SettingsView.swift              # 设置视图
│   ├── TranslationView.swift           # 翻译结果视图
│   ├── StreamingTextView.swift         # 流式文本渲染
│   ├── DictionaryCardView.swift        # AI 词典卡片
│   ├── NativeDictionaryView.swift      # 原生词典视图
│   ├── OnboardingView.swift            # 首次引导
│   ├── SkeletonShimmerView.swift       # 骨架屏
│   ├── AdaptiveGlassBackground.swift   # 玻璃背景
│   └── Components/                     # 可复用子组件
└── Utils/
    ├── AppTheme.swift                   # 主题常量
    ├── AppTheme+Motion.swift            # 动画常量
    ├── AnimationGate.swift              # 动画门控
    ├── KeychainManager.swift            # Keychain 安全存储
    └── MemoryPurgeHelper.swift          # 内存压力管理
```

---

## 3. 分层架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        表示层 (Views)                            │
│  FloatingTranslationView → WorkspaceRuntime → Plugin System     │
│  (TranslationPlugin / DictionaryPlugin / HistoryPlugin)          │
├─────────────────────────────────────────────────────────────────┤
│                      状态管理层 (Models)                         │
│  AppState (facade) → TranslationSessionStore / ConfigurationStore│
├─────────────────────────────────────────────────────────────────┤
│                       服务层 (Services)                          │
│  ┌──────────────┬──────────────────┬──────────────────────────┐ │
│  │  引擎工厂    │   翻译引擎        │   基础设施                │ │
│  │  Factory     │  TranslationActor │   WindowManager          │ │
│  │              │  MacOSNative      │   HotkeyManager          │ │
│  │              │  TranslationSvc   │   HistoryActor           │ │
│  │              │  FallbackRouter   │   ClipboardMonitor       │ │
│  │              │  ThrottledStream  │   CaptureService         │ │
│  │              │  ContextAwareSvc  │   OCRSelectionOverlay    │ │
│  │              │  TranslationPipe  │   TextReplacementService │ │
│  └──────────────┴──────────────────┴──────────────────────────┘ │
├─────────────────────────────────────────────────────────────────┤
│                       持久化层                                   │
│  UserDefaults + Keychain + JSONL Stream (history_archive.jsonl) │
├─────────────────────────────────────────────────────────────────┤
│                      macOS 系统层                                 │
│  Carbon Event / AppKit / Vision / ScreenCaptureKit / Translation │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. 核心设计模式

### 4.1 状态管理双轨制

```
AppState (ObservableObject) ← 20+ 旧消费者兼容 facade
    ├── session: TranslationSessionStore   (@Observable) 高频流式状态
    └── configuration: ConfigurationStore  (@Observable) 低频配置状态
```

- [`TranslationSessionStore`](Sources/OmniTrans/Models/Stores.swift:13) 隔离了 `translatedText`、`isTranslating` 等高频字段，SwiftUI `@Observable` 实现字段级观察，只有 [`StreamingTextView`](Sources/OmniTrans/Views/StreamingTextView.swift) 会在文本变化时重算 body。
- [`ConfigurationStore`](Sources/OmniTrans/Models/Stores.swift:40) 承载 `providers`、`sourceLang`、`targetLang` 等低频配置，避免流式翻译时的无效重绘。

### 4.2 翻译引擎策略模式 + 工厂模式

```
TranslationEngineProtocol (统一接口)
        │
        ├── TranslationActor         ← AI/LLM SSE 流 + 传统 MT
        └── MacOSNativeEngineAdapter ← macOS 原生词典 + Translation 框架
```

- [`TranslationEngineFactory`](Sources/OmniTrans/Services/TranslationEngineFactory.swift:8) 根据 `EngineRoutingContext`（文本、供应商、是否为单词） 动态选择引擎，符合开闭原则。
- [`TranslationActor`](Sources/OmniTrans/Services/TranslationActor.swift:32) 是 `actor` 隔离的网络 I/O 层，内部按 `ProviderKind` 分发到: `openAIStream` → `anthropicStream` → `geminiStream` → `performMockStream`(传统 MT) 等 private 方法。

### 4.3 工作区插件系统 (v0.8)

```
FloatingTranslationView (薄壳)
    └── WorkspaceRuntime
            ├── HistoryPlugin      (priority=0, 默认)
            ├── DictionaryPlugin   (priority=10, 查词)
            └── TranslationPlugin  (priority=20, 翻译)
```

- [`WorkspacePlugin`](Sources/OmniTrans/Views/WorkspaceFramework.swift) 协议定义 `canHandle(context:)` → `buildCanvas` / `buildOverlay` / `buildHUD`。
- [`WorkspaceRuntime`](Sources/OmniTrans/Views/WorkspaceRuntime.swift:19) 管理插件注册、上下文快照、插件解析和过渡动画，UI 层零模式枚举知识。

### 4.4 取词责任链模式

```
HotkeyManager.capture()
    ├── ClipboardCaptureStrategy    ← 模拟 Cmd+C
    ├── AXCaptureStrategy           ← Accessibility API
    └── ScreenCaptureOCRCaptureStrategy ← Vision OCR 回退
```

- [`HotkeyManager`](Sources/OmniTrans/Services/HotkeyManager.swift:6) 通过 Carbon `RegisterEventHotKey` 注册三个全局快捷键。
- TCP/TLS 预热：在取词前发送 HEAD 请求完成 DNS + TCP + TLS 握手，与取词管线并行执行。

### 4.5 窗口管理集中化 (v0.9)

[`WindowManager`](Sources/OmniTrans/Services/WindowManager.swift:13) 作为 AppDelegate 下唯一的窗口生命周期协调器：
- [`FloatingPanel`](Sources/OmniTrans/Services/FloatingPanel.swift:17) — 主翻译工作区，支持固定(`isPinned`)、动态高度、鼠标跟随定位。
- [`SettingsPanel`](Sources/OmniTrans/Services/SettingsPanel.swift) — 设置面板，定位到菜单栏下方。
- 所有 `makeKeyAndOrderFront` / `orderOut` 统一经过 `WindowManager`。

---

## 5. 数据流

### 5.1 翻译主流程

```
用户按 ⌥D
    │
    ▼
HotkeyManager (Carbon callback)
    │
    ├── preConnectCurrentProvider()  ← TCP/TLS 预热 (并行)
    │
    ├── captureWithoutOCR()          ← 取词责任链
    │       │
    │       ▼
    │   SlidingWindowContextCapture  ← 捕获双向上下文
    │
    ▼
AppDelegate.fire(text:context:)
    │
    ▼
AppState.resetForNew() → translate(context:)
    │
    ├── 缓存命中? → 直接返回
    │
    ├── FallbackRouter.resolveWithFallback()  ← Ollama 健康检查
    │
    ├── WordDetector.isWord() → 选择 translateProvider 或 dictProvider
    │
    ▼
TranslationEngineFactory.makeEngine()
    │
    ├── macOSNative → MacOSNativeEngineAdapter
    │       ├── 查词: MacOSNativeProvider.lookupWord() (CoreServices)
    │       └── 翻译: SystemTranslationEngine (macOS 26+ ANE)
    │
    └── AI/MT → TranslationActor.translateStream()
            │
            ▼
        performStream() ─── SSE 流式解析
            │
            ▼
        ThrottledStream (80ms 批处理)
            │
            ▼
        AppState.translatedText ← MainActor.run
            │
            ▼
        StreamingTextView 渲染
```

### 5.2 OCR 流程

```
用户按 ⌥F
    │
    ▼
OCRSelectionOverlay.beginCapture()
    │
    ├── 全屏半透明叠加层
    ├── 用户拖拽矩形选区
    │
    ▼
ScreenCaptureService.capture() → SCStream 单帧 CVPixelBuffer
    │
    ▼
Vision VNRecognizeTextRequest
    │
    ▼
AppState.resetForNew() → translate()
```

### 5.3 原位替换流程

```
用户按 ⌥R
    │
    ▼
TextReplacementService.replaceSelectedText()
    ├── 获取 AppState.translatedText
    ├── 定位前台应用
    ├── 模拟 Cmd+V 粘贴
    └── 恢复剪贴板原始内容
```

---

## 6. 支持引擎一览

| 引擎类型 | ProviderKind | 流式 | 词典 | 备注 |
|---------|-------------|------|------|------|
| OpenAI | `.openAI` | ✅ SSE | ✅ JSON Mode | GPT-4o-mini 等 |
| OpenAI 兼容 | `.openAICompat` | ✅ SSE | ✅ JSON Mode | Ollama / 本地模型 |
| Claude | `.anthropic` | ✅ SSE | ❌ | Anthropic Messages API |
| Gemini | `.gemini` | ✅ SSE | ❌ | Google Generative AI |
| macOS 原生 | `.macOSNative` | ❌ | ✅ | 离线词典 + macOS 26+ ANE |
| Google 翻译 | `.googleMT` | ❌ 模拟 | ❌ | Cloud Translation v2 |
| Bing 翻译 | `.bingMT` | ❌ 模拟 | ❌ | Translator v3 |
| 阿里云翻译 | `.alibabaMT` | ❌ 模拟 | ❌ | 签名鉴权 |
| 火山翻译 | `.volcengineMT` | ❌ 模拟 | ❌ | 签名鉴权 |

---

## 7. 上下文感知翻译

[`CapturedContext`](Sources/OmniTrans/Services/ContextAwareService.swift:14) 在快捷键触发时捕获选中文本的前后文（默认各 300 字符），通过 [`ContextAwareService.buildFinalPrompt`](Sources/OmniTrans/Services/ContextAwareService.swift:63) 注入到 LLM 系统提示词中。

- 强度级别 0–4 可调，控制上下文窗口 (100/200/300/400/500 字符)。
- 仅对 AI/LLM 路径生效，传统 MT 引擎忽略上下文。
- 词典模式下强制 300 字符上下文，并引导 LLM 在首位给出最符合语境的释义。

---

## 8. 持久化策略

| 数据类型 | 存储方式 | 容量 |
|---------|---------|------|
| 供应商配置 | UserDefaults (Codable JSON) | 不限 |
| API 密钥 | Keychain (kSecClassGenericPassword) | 安全存储 |
| 翻译历史 (热) | UserDefaults | ≤50 条 |
| 翻译历史 (冷) | JSONL 流式追加写入 | 不限，内存 ≤2000 |
| 用户偏好 | UserDefaults | — |

[`HistoryActor`](Sources/OmniTrans/Services/HistoryActor.swift:18) 采用双写策略：
- **JSONL** 立即流式追加（O(1) I/O），`FileHandle.seekToEndOfFile`
- **UserDefaults** 5 秒防抖刷新，仅保留最近 50 条用于冷启动
- 内存压力时释放缓存，标记 `isDirty`，下次按需从 JSONL 流式回读

---

## 9. 内存管理

- [`MemoryPurgeHelper`](Sources/OmniTrans/Utils/MemoryPurgeHelper.swift) 在OCR大文本操作后 (2秒延迟) 调用 `malloc_zone_pressure_relief` 回收 Vision C++ 缓冲区 (~60MB)。
- [`TranslationActor`](Sources/OmniTrans/Services/TranslationActor.swift:32) 的 `activeStreamTask` 在新请求时自动取消旧任务。
- [`AppState.resetForNew`](Sources/OmniTrans/Models/AppState.swift:421) 预分配 `translatedText` 缓冲区 (max(1024, text.count×2))，避免流式拼接时的堆重分配。

---

## 10. 并发模型

- **AppDelegate / WindowManager / AppState**: `@MainActor` — 所有 UI 操作主线程
- **TranslationActor**: `actor` — 网络 I/O 隔离，串行化请求
- **HistoryActor**: `actor` — 持久化写入隔离
- **ThrottledStream**: 运行在 TranslationActor 的 cooperative Task 上
- **TranslationSessionStore / ConfigurationStore**: `@Observable` — 字段级 SwiftUI 观察
- **sharedURLSession**: HTTP/2 多路复用全局单例，`httpMaximumConnectionsPerHost = 10`

---

## 11. 构建配置

- Swift 5.9 + `StrictConcurrency` (实验性 Swift 6 严格并发)
- `AccessLevelOnImport` (减少符号可见性)
- Release: `-whole-module-optimization`
- 双架构构建脚本: `build-arm.sh` (Apple Silicon) / `build-intel.sh` (Intel)
- 应用类型: `.accessory` (菜单栏应用，无 Dock 图标)
