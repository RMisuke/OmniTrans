# OmniTrans

> 轻量 macOS 菜单栏翻译工具 · 零三方依赖 · 多 API 提供商 · 本地优先

OmniTrans 是一款运行在 macOS 菜单栏的翻译应用，支持快捷键划词翻译、OCR 区域截图取词、多 API 提供商切换，以及流式翻译输出。

---

## 功能特色

- **菜单栏常驻** — 菜单栏图标，一键唤出，不干扰工作流
- **划词翻译** — `⌥D` 选中文本自动翻译，支持 Cmd+C + AX 双回退
- **OCR 取词** — `⌥F` 框选屏幕区域，Vision OCR 识别文字并翻译
- **多 API 提供商**
  - OpenAI / OpenAI 兼容（DeepSeek、硅基流动、Ollama 等）
  - Claude (Anthropic)
  - Gemini
- **流式输出** — 实时逐字输出翻译结果
- **翻译历史** — 本地持久化，支持上限配置（10–500 条）
- **快捷键录制** — 翻译热键和 OCR 热键均可自定义
- **首次引导** — 首次启动弹出权限配置引导
- **深色模式自适应** — 菜单栏图标自动适配系统外观
- **零三方依赖** — 纯 Swift + AppKit / SwiftUI 构建

---

## 项目结构

```
OmniTrans/
├── Package.swift              # SwiftPM 构建配置
├── build.sh                   # 编译 & 打包脚本
├── Resource/icon/
│   ├── icon.icns               # 应用图标
│   └── menubar.icns            # 菜单栏图标
└── Sources/OmniTrans/
    ├── App.swift                # 应用入口 & 菜单栏 / 委托
    ├── Models/
    │   ├── APIProvider.swift    # API 提供商模型
    │   ├── AppState.swift       # 全局状态机
    │   ├── ProviderTemplates.swift  # 提供商模板
    │   └── TranslationConfig.swift  # 翻译配置
    ├── Services/
    │   ├── APITestService.swift     # API 连通性测试
    │   ├── ClipboardMonitor.swift   # 剪贴板监听
    │   ├── FloatingPanel.swift      # 浮动翻译面板
    │   ├── HotkeyManager.swift      # 全局热键管理
    │   ├── OCRSelectionOverlay.swift # OCR 区域选取
    │   ├── TranslationActor.swift   # 线程隔离翻译核心
    │   └── TranslationService.swift # 多 API 流式翻译
    ├── Utils/
    │   └── KeychainManager.swift    # Keychain 安全存储
    └── Views/
        ├── ContentView.swift            # 主菜单
        ├── FloatingTranslationView.swift # 浮动翻译 UI
        ├── OnboardingView.swift         # 首次引导
        ├── ProviderCardView.swift       # API 配置卡片
        ├── SettingsView.swift           # 设置页
        └── TranslationView.swift        # 翻译界面
```

---

## 快速开始

### 系统要求

- macOS 14.0+
- Xcode 15+ 或 Swift 5.9+ 命令行工具

### 构建

```bash
git clone https://github.com/RMisuke/OmniTrans.git
cd OmniTrans/AiTranslator
./build.sh
```

脚本会自动编译 release 版本 → 打包 `.app` → ad-hoc 签名。

构建产物位于 `AiTranslator/.build/OmniTrans.app`。

### 运行

```bash
open AiTranslator/.build/OmniTrans.app
```

首次启动会弹出引导窗口，按提示授予辅助功能权限和屏幕录制权限。

---

## 使用指南

| 操作 | 快捷键 | 说明 |
|------|--------|------|
| 划词翻译 | `⌥D` | 选中文本后按下，自动翻译 |
| OCR 取词 | `⌥F` | 框选屏幕区域，识别文字并翻译 |
| 打开设置 | 菜单 → 设置 | API 密钥、热键、外观等 |
| 退出 | `⌘Q` | 退出应用 |

### 配置 API 密钥

1. 打开设置 → API 配置
2. 点击「+」添加提供商模板（OpenAI / Claude / Gemini 等）
3. 填入 API Key 和自定义 Endpoint（可选）
4. 保存并设为默认

> API Key 通过 macOS Keychain 安全存储。

---

## 架构概要

采用 **域分治 (Domain-Driven State)** 模式：

```
                    ┌──────────────────┐
                    │   AppCoordinator │  ← 全局状态机
                    └───┬──────┬───────┘
                        │      │
        ┌───────────────┘      └───────────────┐
        ▼                                      ▼
┌──────────────────┐                  ┌──────────────────┐
│  SettingsStore   │                  │  HistoryStore    │
│  API 配置 / 模板  │                  │  FIFO 磁盘缓存    │
└──────────────────┘                  └──────────────────┘
                        │
                        ▼
              ┌──────────────────┐
              │ TranslationContext│  ← 主界面绑定
              │  input / output   │
              └──────────────────┘
```

核心设计原则：

- **零三方依赖** — 纯 Swift 标准库 + 系统框架
- **线程隔离** — `TranslationActor` 处理网络请求和流解析
- **安全存储** — API Key 全部存入 Keychain
- **剪贴板保护** — `defer` 保证剪贴板内容安全恢复
- **双热键隔离** — 翻译和 OCR 使用独立的 EventHotKeyID，统一回调分发

---

## 构建详情

`build.sh` 自动完成：

1. 清理旧构建
2. `swift build -c release --arch arm64`
3. 创建 `.app` 目录结构
4. 复制图标资源
5. 生成 Info.plist
6. Ad-hoc codesign

---

## 许可证

MIT
