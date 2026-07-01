# OmniTrans

> 轻量 macOS 菜单栏翻译工具 · 零三方依赖 · 多引擎 · 本地优先

OmniTrans 是一款运行在 macOS 菜单栏的 AI 翻译应用，支持快捷键划词翻译、OCR 区域截图取词、智能词典、多 API 提供商切换、流式翻译输出及 macOS 原生离线翻译引擎。

---

## 功能特色

- **菜单栏常驻** — 菜单栏图标，一键唤出，不干扰工作流
- **划词翻译** — `⌥D` 选中文本自动翻译，支持 Cmd+C + AX 双回退
- **OCR 取词** — `⌥F` 框选屏幕区域，Vision OCR 识别文字并翻译
- **智能词典** — 输入单词自动切换词典模式，展示音标、词性、释义、例句
- **多翻译引擎**
  - **AI 大模型** — OpenAI · Claude · Gemini · 通义千问 · DeepSeek · SenseNova 等 12+ 模型
  - **机器翻译** — Google Translate · Bing Translator · 阿里云机器翻译
  - **macOS 原生** — 系统离线词典 + 神经网络翻译引擎
- **流式输出** — SSE 实时逐字输出，80ms 节流防掉帧
- **翻译历史** — 本地持久化，支持上限配置、一键清除、历史回溯
- **快捷键录制** — 翻译/OCR 热键均可自定义，一键恢复默认
- **自定义提示词** — 翻译系统提示词可自定义，支持变量替换
- **悬浮框 API 切换** — 划词翻译悬浮窗内可直接切换翻译引擎
- **深色/浅色/系统** — 三种外观模式切换
- **隐私优先** — AES-256-GCM 本地加密存储密钥，不上传任何第三方
- **零三方依赖** — 纯 Swift + AppKit / SwiftUI / CryptoKit 构建

---

## 项目结构

```
OmniTrans/
├── Package.swift                  # SwiftPM 构建配置
├── build-arm.sh                   # ARM 编译 & 打包脚本
├── Resource/icon/
│   ├── icon.icns                  # 应用图标
│   └── menubar.icns               # 菜单栏图标
└── Sources/OmniTrans/
    ├── App.swift                   # 应用入口 & 菜单栏 / 委托
    ├── Models/
    │   ├── APIProvider.swift       # API 提供商模型（8 种 ProviderKind）
    │   ├── AppState.swift          # 全局状态机
    │   ├── DictionaryEntry.swift   # 词典结构化模型
    │   ├── ProviderTemplates.swift # AI + MT 预设模板
    │   └── TranslationConfig.swift # 翻译语言配置
    ├── Services/
    │   ├── APITestService.swift         # API 连通性测试 & 模型列表拉取
    │   ├── ClipboardMonitor.swift       # 零 CPU 剪贴板事件监听
    │   ├── FallbackRouter.swift         # Ollama 本地回退路由
    │   ├── FloatingPanel.swift          # 浮动翻译面板
    │   ├── HotkeyManager.swift          # 全局热键管理（Carbon）
    │   ├── MacOSNativeProvider.swift    # macOS 原生词典 & 翻译
    │   ├── OCRSelectionOverlay.swift    # OCR 区域选取
    │   ├── ProviderStorageManager.swift # Provider 持久化
    │   ├── SystemTranslationEngine.swift # macOS 15+ Translation 框架
    │   ├── TextCaptureStrategies.swift  # 职责链取词（AX/Clipboard/Vision）
    │   ├── TranslationActor.swift       # Actor 隔离流式翻译核心
    │   ├── TranslationActor_MT.swift    # 传统 MT 翻译 + 阿里云签名
    │   └── TranslationService.swift     # 非流式翻译回退
    ├── Utils/
    │   ├── AppTheme.swift           # 统一设计系统
    │   └── KeychainManager.swift    # AES-256-GCM 加密文件存储
    └── Views/
        ├── ContentView.swift             # 菜单栏主页
        ├── TranslationView.swift         # 翻译界面
        ├── FloatingTranslationView.swift # 浮动翻译窗
        ├── SettingsView.swift            # 设置页路由
        ├── GeneralSettingsView.swift     # 通用设置（快捷键/外观/行为）
        ├── APISettingsView.swift         # API 配置管理
        ├── TemplateListView.swift        # API 模板选择
        ├── ProviderCardView.swift        # API 配置卡片
        ├── DictionaryCardView.swift      # AI 词典卡片
        ├── NativeDictionaryView.swift    # 原生词典卡片
        └── OnboardingView.swift          # 首次引导
```

---

## 快速开始

### 系统要求

- macOS 14.0+
- Xcode 15+ 或 Swift 5.9+ 命令行工具

### 构建

```bash
git clone https://github.com/RMisuke/OmniTrans.git
cd OmniTrans
bash build-arm.sh
```

脚本自动编译 → 打包 `.app` → ad-hoc 签名。

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
| 打开设置 | 菜单 → ⚙️ | API 密钥、快捷键、外观等 |
| Enter 翻译 | `↩` | 菜单栏输入文本后按 Enter |
| 退出 | `⌘Q` | 退出应用 |

### 配置 API

1. 打开设置 → API 配置
2. 从模板添加或自定义 API 提供商
3. 填入 API Key / AccessKey 等凭据
4. 测试连接 → 保存

> 密钥使用 AES-256-GCM 加密存储于 `~/Library/Application Support/OmniTrans/secrets.json`。

---

## 架构概要

```
                    ┌──────────────────┐
                    │    AppState       │  ← @MainActor 全局状态
                    │  @Published vars  │
                    └───┬──────┬───────┘
                        │      │
        ┌───────────────┘      └───────────────┐
        ▼                                      ▼
┌──────────────────┐                  ┌──────────────────┐
│  TranslationActor │                  │  ProviderStorage │
│  流式 SSE 调度     │                  │  UserDefaults    │
└──────────────────┘                  └──────────────────┘
        │
        ▼
┌──────────────────┐     ┌──────────────────┐
│  LLM Streams      │     │  MT (single-shot) │
│  OpenAI/Claude/   │     │  Google/Bing/     │
│  Gemini + 80ms    │     │  Alibaba + HMAC   │
│  throttle         │     │  signer           │
└──────────────────┘     └──────────────────┘
```

核心设计原则：

- **零三方依赖** — 纯 Swift 标准库 + 系统框架
- **线程隔离** — `actor TranslationActor` 处理所有网络 I/O
- **加密存储** — CryptoKit AES-256-GCM + HKDF 密钥派生
- **流式节流** — `ThrottledStream` 80ms 缓冲防 SwiftUI 高频重绘
- **事件驱动** — `ClipboardMonitor` 基于 `NSWorkspace` 通知，零 Timer
- **职责分离** — Settings 拆分为 5 个独立 View 文件

---

## 构建详情

`build-arm.sh` 自动完成：

1. `swift build -c release --arch arm64`
2. 创建 `.app` 目录结构
3. 复制图标资源到 `Contents/Resources/`
4. 生成 `Info.plist`
5. Ad-hoc codesign（无 entitlements）

---

## 许可证

MIT
