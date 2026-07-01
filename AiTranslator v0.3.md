# OmniTrans v0.3 — 开发规划

> **日期**：2026-07-02  
> **状态**：规划阶段（尚未执行）

---

## 阶段一：架构优化（不增加新功能）

### 1.1 SettingsView 拆分
- **现状**：`SettingsView.swift` 732 行单文件，包含 5 个 Tab 全部逻辑
- **目标**：拆分为独立 View 文件
  - `SettingsGeneralView.swift` — 通用设置（快捷键、外观、语言）
  - `SettingsProvidersView.swift` — Provider 管理列表
  - `SettingsProviderEditView.swift` — 单个 Provider 编辑
  - `SettingsTranslationView.swift` — 翻译默认模型配置
  - `SettingsAboutView.swift` — 关于页面
- **文件**：`Sources/OmniTrans/Views/SettingsView.swift` → 重构为路由壳 + 子 View

### 1.2 AppState 路由简化
- **现状**：`AppState.swift` 338 行，`translate()` 和 `doTranslate()` 分支交错
- **目标**：
  - 提取 `TranslationRouter` 单独文件，负责模式判断（词典/段落 × AI/MT/Native）
  - `AppState` 仅保留状态存储 + 对外接口
- **文件**：`Sources/OmniTrans/Models/AppState.swift` → 精简

### 1.3 TranslationActor 职责拆分
- **现状**：`TranslationActor.swift` 480 行，同时处理 LLM 流式 + MT 单次 + 词典 JSON 构建
- **目标**：
  - `LLMTranslationActor` — 纯 LLM 流式翻译
  - `DictionaryActor` — 词典 JSON 解析 + 格式化
  - 保留 `TranslationActor` 作为调度中心
- **文件**：`Sources/OmniTrans/Services/TranslationActor.swift` → 拆分

### 1.4 代码清理
- OnboardingView 样式从 `.secondary` 迁移到 `AppTheme`
- 移除废弃的 Keychain entitlements 残留代码
- 统一命名：所有 `OmniTrans` / `AiTranslator` 混用归一

---

## 阶段二：UI 还原与美化

### 2.1 还原 v0.2 半透明风格
- **现状**：当前 UI 经历了多次迭代，风格偏离 v0.2 原始设计
- **目标**：从 git commit `05a51cc` 提取 v0.2 UI 风格特征
  - `TranslationView`：`.ultraThinMaterial` 半透明毛玻璃
  - `FloatingTranslationView`：`.regularMaterial` + `cornerRadius(12)`
  - `ContentView`：`minWidth: 420, maxWidth: 700, minHeight: 460`
- **参考**：对比当前文件与 v0.2 差异，逐文件还原
- **文件**：
  - `Sources/OmniTrans/Views/TranslationView.swift`
  - `Sources/OmniTrans/Views/FloatingTranslationView.swift`
  - `Sources/OmniTrans/Views/ContentView.swift`

### 2.2 统一字体大小
- 划词翻译卡片字号略微减小
- 菜单栏主页和其他子页面字号增大
- 悬浮窗原文部分框体比例增大
- **文件**：涉及所有 View 文件字体 `.font()` 调用

### 2.3 悬浮翻译卡片重写
- **现状**：存在严重界面问题
- **目标**：完全重写 `FloatingTranslationView`
  - 整理布局结构（dragHandle → header → sourceText → result → bottomBar）
  - 词典模式使用 `DictionaryCardView` / `NativeDictionaryView` 专用布局
  - 段落翻译使用标准流式输出布局
  - 修复 resize grip、dismiss 逻辑
- **文件**：`Sources/OmniTrans/Views/FloatingTranslationView.swift` → 重写

### 2.4 全局风格统一
- 半透明材质 + 纯色文字结合，提高美观度和可读性
- 提供深色 / 浅色 / 跟随系统三模式开关
- 所有 View 统一使用 `AppTheme` 颜色常量
- **文件**：`Sources/OmniTrans/Utils/AppTheme.swift` → 增强

---

## 阶段三：Bug 修复

### 3.1 macOS 原生翻译兼容性
- **现状**：macOS 14/15 上 `TranslationSession` 均报 "not found"
- **目标**：
  - 确认 `@available(macOS 15.0, *)` 守卫正确
  - 弱链接 `Translation` 框架
  - macOS <26 降级到 `DCSCopyTextDefinition` 词典 + 传统回退
  - macOS 26+ 自动开启 ANE 神经网络引擎翻译
- **文件**：
  - `Sources/OmniTrans/Services/SystemTranslationEngine.swift`
  - `Sources/OmniTrans/Services/MacOSNativeProvider.swift`

### 3.2 阿里云 MT HTTPS 修复
- **现状**：使用 HTTP 明文，ATS 报错
- **目标**：检查阿里云 MT endpoint 是否支持 HTTPS，若支持则切换
- **文件**：`Sources/OmniTrans/Services/TranslationActor_MT.swift`

### 3.3 词典模式默认模型不生效
- **现状**：设置中配置词典默认模型后未生效
- **目标**：修复 `translate()` 路由中词典模式 provider 选择逻辑
- **文件**：`Sources/OmniTrans/Models/AppState.swift`

### 3.4 密钥懒加载优化
- **现状**：初次使用需连续授权三次
- **目标**：压缩到一次权限请求，懒加载密钥
- **文件**：`Sources/OmniTrans/Utils/KeychainManager.swift`

---

## 阶段四：新功能

### 4.1 机器翻译独立模板系统
- **目标**：每种 MT（阿里云/Google/Bing）有独立配置界面
  - 阿里云：AccessKeyID + AccessKeySecret
  - Google：API Key
  - Bing：API Key + Region
- **文件**：
  - `Sources/OmniTrans/Models/ProviderTemplates.swift` → 扩展
  - `Sources/OmniTrans/Views/SettingsProviderEditView.swift` → 新增动态表单

### 4.2 macOS 原生词典内置化
- **目标**：macOS 原生词典作为默认内置 Provider，不可删除、不可修改
- 词典模式初始默认使用 macOS 自带词典
- **文件**：`Sources/OmniTrans/Models/AppState.swift` → 添加内置 provider 逻辑

### 4.3 词典模式自动切换
- **目标**：菜单栏主界面输入单词时自动判断并切换到词典模式
- 词典模式下右上角模型显示切换到对应词典模型
- **文件**：
  - `Sources/OmniTrans/Views/TranslationView.swift`
  - `Sources/OmniTrans/Models/AppState.swift`

### 4.4 设置页"翻译"配置 Tab
- **目标**：新增翻译配置页
  - 词典模式默认模型选择
  - 划词模式默认模型选择
  - 默认翻译窗口高度设置（380px）
- **文件**：`Sources/OmniTrans/Views/SettingsTranslationView.swift` → 新建

### 4.5 进度条动画（词典 JSON 模式）
- **目标**：词典模式下大模型返回 JSON 时不显示流式文本，替换为进度条动画
- **文件**：`Sources/OmniTrans/Services/TranslationActor.swift`

### 4.6 模型列表纵向滚动选择
- **目标**：模型列表改为可滚动纵向列表，支持 SenseNova 等多模型 provider
- **文件**：`Sources/OmniTrans/Views/ProviderCardView.swift`

---

## 阶段五：文档与文本更新

### 5.1 更新所有界面文本
- 关于页面文本
- 首次启动引导页面文本
- 所有提示和帮助文本
- **文件**：
  - `Sources/OmniTrans/Views/OnboardingView.swift`
  - `Sources/OmniTrans/Views/SettingsAboutView.swift`（新建）

### 5.2 fix-log.md 合并与归档
- 将 fixlog.md 内容合并到 fix-log.md
- 整理为统一格式
- **文件**：`fix-log.md`

### 5.3 版本号更新
- 更新 `kAppVersion` 到 0.3
- **文件**：`Sources/OmniTrans/App.swift`

---

## 执行顺序

| 顺序 | 阶段 | 说明 |
|------|------|------|
| 1 | 阶段一 | 架构优化（无功能变化，降低回归风险） |
| 2 | 阶段二 | UI 还原与美化（在架构稳定后做视觉） |
| 3 | 阶段三 | Bug 修复 |
| 4 | 阶段四 | 新功能 |
| 5 | 阶段五 | 文档与文本 |
| 每阶段结束后 | — | ARM 打包验证 `.build/OmniTrans-arm64.app` |

---

## 构建命令

```bash
cd "/Users/chensinuo/Codex/AI Translater"
swift build                          # 编译验证
bash build-arm.sh                    # ARM 打包
open .build/OmniTrans-arm64.app      # 启动验证
```

---

*规划由 Codex 生成 — 2026-07-02*
