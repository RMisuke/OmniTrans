# macOS 兼容性修复记录 (v0.9)

## HotkeyManager 合并单事件处理器

**问题**: `register()`/`registerOCR()`/`registerReplace()` 各自调用 `InstallEventHandler()`，
只有最后一个 handler 生效，前两个被覆盖。

**修复**: 
- 新增模块级 `sharedHandlerRef: OSAllocatedUnfairLock<EventHandlerRef?>`，
  在模块初始化时一次性安装 `InstallEventHandler`
- C 回调 `unifiedHotkeyCallback` 改为使用 `HotkeyManager.shared` 直接访问，
  不再使用 `Unmanaged.fromOpaque(userData)`
- `unregister()`/`unregisterOCR()`/`unregisterReplace()` 只调用 
  `UnregisterEventHotKey`，不再调用 `RemoveEventHandler`
- 所有 `register()`/`registerOCR()`/`registerReplace()` 使用新的
  `registerHotKey(key:mods:id:ref:)` 辅助方法
- 增加 OSLog `logger` 提供 `log stream` 诊断

## SystemTranslationEngine 超时和诊断增强

**问题**:
- 3 秒超时对冷启动 ANE 模型加载不充足
- 无日志导致翻译失败难以排查

**修复**:
- `availabilityTimeout` 从 3s → 15s
- `translateTimeout` 新增 15s 常量
- 新增 `transLogger` (os_log) 记录：语言包查询开始/完成/耗时, 翻译开始/完成/耗时/失败/超时
- 新增 `translateTimedOutMessage` 用户友好提示信息
- 新增 `warmUp()` 静态方法 (fire-and-forget) 在应用启动时预热 Translation 框架
- `ResumeGate` actor 保持 Swift 6 并发安全

## 关键原则
- 所有 C 回调中通过 `HotkeyManager.shared` 直接引用，不使用 `userData` 指针
- 所有 `@available(macOS 26.0, *)` 保持声明，`MacOSNativeEngineAdapter` 中已有 `if #available` 运行时检测
- `VNDisableANE=1` 尚未处理为条件设置 — 后续需要在 OCR 诊断完成后再决定是否禁用 ANE

## 多屏 OCR 取词坐标系统修复（DisplayGeometry）

**问题**: 外接屏位于主屏上/下/左/右时 OCR 取词失败或区域偏移，内屏正常。
**根因**: 坐标系混用 —— `SCDisplay.frame`（CG top-left）与 `NSScreen.frame`（AppKit bottom-left）
Y 语义相反；原代码用 AppKit 坐标对 `SCDisplay.frame` 做 `contains` 判断，多屏下必失配并
回退 `displays.first` 主屏；`cgScreenHeight - mouse.y` 假设所有屏底部对齐（依赖主屏布局）。

**修复**:
- 新增独立库 target `DisplayGeometry`（`Sources/DisplayGeometry/DisplayGeometry.swift`），
  作为唯一跨坐标系换算出口：AppKit↔CG 互转、`CGDirectDisplayID` 关联选屏、
  `AppKit 全局 rect → display-local sourceRect`、scale 动态化（`SCDisplay.width/frame.width`）、
  Vision normalized→AppKit 全局/窗口局部映射。
- `CaptureService.swift` / `TextCaptureStrategies.swift` 统一走 DisplayGeometry，
  删除 `NSScreen.main` / `displays.first` / `backingScaleFactor` 硬乘。
- `OCRSelectionOverlay.swift` 新增 `OCRResult`（文本+文字行区域坐标）。
- 新增 `DisplayGeometryTests`（12 个用例，覆盖四方向/负坐标/双外接/混合缩放率，已通过）。
- 启动时 `DisplayLayoutDebug.dump()` 输出显示拓扑，便于集成验证。

**构建注意**: 本机 `xcode-select` 指向 CommandLineTools，必须
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift build|test`，
否则报 `spec ... already registered`（见 build.sh）。

## 构建脚本全面修复（scripts/omnitrans-build-common.sh）

**问题**: 三个脚本（build.sh / build-arm.sh / build-intel.sh）存在
- 工具链硬编码 `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`
- SwiftPM 产物路径过时：Xcode 27/Swift 6.4 输出到 `.build/out/Products/Release`，
  脚本仍硬编码 `.build/release` 或 `.build/apple/Products/Release`
- build-intel.sh 未设 DEVELOPER_DIR、裸用 `swift build`，CLT 环境下报
  `spec ... already registered`
- 部署目标未显式声明（二进制 minos 依赖 Package.swift）

**修复**:
- 新增共享 [`scripts/omnitrans-build-common.sh`](../../scripts/omnitrans-build-common.sh)：
  `omni_select_developer_dir`（Xcode-beta > Xcode > xcode-select 动态选择，兼容 CLT）、
  `omni_resolve_release_binary`（`.build/out/Products/Release` 优先，兼容 apple/release 旧布局）、
  `MACOSX_DEPLOYMENT_TARGET=14.0`、`omni_make_info_plist`（统一含阿里云 ATS）、
  `omni_assemble_app`（拷贝/strip/图标/plist/codesign/xattr）。
- 三个脚本统一 source common；build-intel.sh 改经 `xcrun` 构建。
- 产物目录与命名保留：OmniTrans.app（universal）、OmniTrans-arm64.app、OmniTrans-intel.app，
  bundle id 分别 com.omnitrans.app / com.omnitrans.arm64 / com.omnitrans.intel。

**验证（本机实测）**: build.sh → universal(arm64+x86_64) ✅；build-arm.sh → arm64 ✅；
build-intel.sh → x86_64 ✅。三产物 `minos=14.0`、adhoc 签名、bundle id 正确。
构建日志 warning 均为既有源码 Swift 6 严格并发告警（StrictConcurrency 实验特性、
Swift 5 模式仅告警），非脚本引入；彻底消除需另行源码并发重构。

## 审计 Top5 修复 + 全量告警清零（2026-08-13）

按 docs/code-audit.md 的 Top 5 顺序落地修复，并**消除全部编译器告警**（此前
build 有大量 Swift 6 严格并发 warning，现为 0 error / 0 warning，`swift test` 12 例全绿）：

- **C1** TextReplacementService：`replaceSelectedText` 由 `@MainActor` 同步自旋（阻塞 UI ≤2s）
  改为 `async` + `Task.sleep` 轮询；两处调用（App.swift onReplaceHotkey / menuReplace）改 `Task { await ... }`。
- **C2** TranslationActor_MT：`TextList` 去掉预 `percentEncode`（避免 `%`→`%25` 双重编码），
  由 `buildSignedQuery` 统一编码一次。
- **M1** ThrottledStream 由普通 class 改为 `actor`（buffer/flushTask 隔离），调用点加 `await`。
- **M4** TranslationActor 加 `static let shared` 单例；TranslationEngineFactory / TranslationService 复用，
  不再每次 new actor（保证 activeStreamTask 取消语义）。
- **M7** SettingsPanelContent 温度/Token 滑块保存加 300ms 防抖（`debounceProviderSync`），
  避免每步全量 Keychain 加密写。
- **M2** SystemTranslationEngine `installedCache` 用 `OSAllocatedUnfairLock` 保护；修复
  `self.availability` sending 告警（改用局部 `avail`）。
- **M3** NativeDictionaryParser.stripPinyin：仅当文本含 CJK 才剥离，避免误删 café/résumé 等。
- **M6** HotkeyManager 统一为单次 `InstallEventHandler`（`ensureHandlerInstalled`），移除重复 handler。
- **M5** 移除 ConfigurationStore 中从未消费的 providers/selectedProviderID 等存储字段与 `syncFrom`
  （AppState 为唯一权威），消除双 SSOT 漂移。

**告警清零手段**（复用范式）：
- `@preconcurrency import Vision / ScreenCaptureKit / CoreVideo / Translation / NaturalLanguage`。
- 移除冗余 `nonisolated(unsafe)`（PinningDelegate/HotkeyManager 因 Sendable/@MainActor 不再需要）。
- CVBuffer 跨线程传递用 `PixelBufferBox: @unchecked Sendable` 包装；TaskGroup 元素类型用 Box。
- OCRHardwareMode.probeAccurate / OCRSelectionOverlay.attemptOCR 由 semaphore+可变捕获重构为
  `withCheckedContinuation` + `ResumeOnceGate`（单次 resume 门控）；performOCR 移除 autoreleasepool（async 内不可 await）。
- TextCaptureStrategies.captureScreen 用 `OSAllocatedUnfairLock<CGImage?>` + `Task.detached` 替代 NSLock+捕获 var。
- `MainActor.assumeIsolated` 包裹 NotificationCenter 回调；`_ =` 处理未用返回值；局部 let 捕获替代捕获 var。

## 审计剩余问题修复（2026-08-17）

在 Top5 修复后，继续按 docs/code-audit.md 逐项处理剩余问题。基线：干净构建 0 error / 0 warning，
`swift test` 12 例全绿。本批修复后重新干净构建 + 测试，仍为 0 error / 0 warning、12/12 通过。

### Bug 隐患
- **B11** TranslationActor.parseSSEStream：`try? decoder.decode` 静默吞错 → 改为 `do/catch` 记录每行失败
  （`NetworkLogger.log`），并统计连续失败次数，≥8 次即抛出，避免「流式无输出且无日志」的静默故障。
- **B13** AppState：7 处 `DispatchQueue.main.asyncAfter` 强捕获 `self` → 统一 `[weak self]`（与既有 626 行一致）。
- **B14** MemoryPurgeHelper：`if kr == KERN_SUCCESS { _ = info }` 死代码 → 读取 `info.phys_footprint`
  用 `os_log(.debug)` 输出 purge 前内存基线（新增 `memPurgeLog`）。
- **B15** TTSManager.isSpeaking 恒 `false` → 由底层上报真实状态：`NativeTTSEngine.isSpeaking`（`synth.isSpeaking`）、
  `OpenAITTSEngine.isSpeaking`（`player?.isPlaying`）、`TTSManager` 组合。
- **B16** OpenAITTSEngine 裸用 `URLSession.shared` 且无超时 → 复用 `sharedURLSession`（HTTP/2 连接池）
  并设 `req.timeoutInterval = NetworkConfig.requestTimeout`。

### 性能优化
- **P3** KeychainManager.deriveKey 每次派生 → 进程级密钥缓存（`OSAllocatedUnfairLock<SymmetricKey?>`），
  机器 UUID 不变则密钥只派生一次。
- **P5** FloatingPanelContent.formattedCacheTimestamp 每次创建 ISO8601DateFormatter + 2 个 DateFormatter →
  `@MainActor enum PanelTimestampFormatters` 静态单例复用。
- **P8** LocalDictionaryRepository.batchImport 每行 `sqlite3_prepare_v2`/`finalize` → 事务内只 prepare 一次，
  逐行 `reset`+`clear_bindings`+rebind；prepare 失败回滚并返回失败数。
- **M11** ContentHeightCalculator 缓存 key 用 `text.hashValue`（碰撞风险）→ 改为完整文本 `"\(layoutWidth)|\(text)"`
  作 `NSString` key；删除无效的 countLimit 判断，改为在 `LineCountCache` 初始化时设置。

### 可维护性
- **M3** FallbackRouter.probeProvider：`statusCode ?? 0 < 500` → 显式括号 `((...) ?? 0) < 500` 消除歧义。
- **M4** OSLog subsystem 不统一（`com.omnitrans.app` / `com.omnitrans.omnitrans` 混用）→ 新增统一常量
  `AppLogging.subsystem`（`Bundle.main.bundleIdentifier ?? "com.omnitrans.app"`），
  NetworkConfig / SystemTranslationEngine / HistoryActor / TTSEngine / KeychainManager /
  LocalDictionaryRepository / NativeDictionaryParser / DictionaryEntry / MemoryPurgeHelper /
  ProviderStorageManager 全部引用。
- **M6** AppState：删除 `retryCount`/`maxAutoRetry` 死状态（仅被赋值为 0，从未参与重试决策，
  实际重试由 RetryUtility/fallback 承担）—— 5 处赋值点一并清理。
- **M8** 关键 print 生产噪音 → OSLog / NetworkLogger：
  - KeychainManager.log、DictionaryEntry（DictParse）、NativeDictionaryParser、LocalDictionaryRepository、
    MemoryPurgeHelper、ProviderStorageManager（DEBUG 内密钥前缀日志）→ `os_log`。
  - TranslationActor（Alibaba/Volcengine body）、TranslationActor_MT（连通性测试）→ `NetworkLogger.log`。
  - OCR 诊断（CaptureService/OCRSelectionOverlay/OCRHardwareMode）与 DisplayGeometry.dump 为低频显式
    诊断工具，保留 print。

**验证**：`swift build`（clean）0 error / 0 warning；`swift test` 12/12 passed。
修复过程唯一编译错误为 `os_log` 参数 `Substring` 不满足 `CVarArg`（`p.apiKey.prefix(6)`），
已用 `String(...)` 包装解决。

## OCR 划词取词性能 + 反馈优化（2026-08-17）

按 plans/ocr-capture-perf-optimization.md 实现。目标：OCR 分析期间菜单栏立即显示「解析中…」，
解析完成后才弹结果窗口，杜绝空白/半渲染帧，异步解耦不阻塞 UI，防重复触发/状态错乱/回调丢失。

### 瓶颈定位
- **B1 弹窗空白帧**：`startOCRSelection()` 里 `showFloatingPanel()` 在 `s.translate()` 之前，
  首帧 `isTranslating=false`/`translatedText=""` → `displayMode=.empty`，先闪空白再跳「正在翻译…」。
- **B2 反馈不可靠**：`NSPopover.behavior = .transient`，点击外部/失焦即自动关闭；且 loading 到
  mouseUp 才显示，框选过程无文字反馈。
- **B3 连续触发串台**：`onComplete` 单一可变属性，前一次 OCR 未完成时新触发覆盖闭包 → 旧结果串台。

### 修复（方案 A/B/C）
- **A 状态机**：`AppDelegate` 新增 `OCRBusyState`（idle/selecting/parsing）。`setOCRStatus(_:)`
  以 **statusItem 标题**为主通道（`.parsing` 时 `button.title = "解析中…"`，点击/失焦不丢失）；
  `.selecting` 用 popover「拖选屏幕区域…」（`.applicationDefined`，不自动关闭）。
  替换原 `showOCRLoadingIndicator/hideOCRLoadingIndicator`；`OmniTransOCRLoading/OCRDone`
  通知 observer 改调 `setOCRStatus(.parsing)/setOCRStatus(.idle)`。
- **B 弹窗时序**：completion 改为 `s.translate()`（同步置 isTranslating=true 或填充缓存）
  **先于** `showFloatingPanel()`，面板首帧即为「正在翻译…」动画或缓存结果，杜绝空白帧。
- **C 代际守卫**：新增 `Sources/OmniTrans/Services/OCRGenerationGuard.swift`
  （`OSAllocatedUnfairLock` 单调递增代际）。`OCRSelectionOverlay.beginCapture` 递增代际，
  `captureRegion` 的 `Task.detached` 完成回主线程时 `isValid(generation)` 校验，过期结果静默丢弃。

### 线程/队列
- OCR 全流程（SCK 截图 + Vision 推理）仍在 `Task.detached` 后台；主线程只做轻量状态切换与
  窗口编排。状态更新（main queue）+ 弹窗（OCR completion 后）通过「先 translate 后 show」解耦。
- 防重复触发三层：`DebounceController`（0.8s）+ `guard window == nil` + `captureGeneration`。

### 测试
- Package.swift 新增 `OmniTransTests` target（`@testable import OmniTrans`，可测 executable target）。
- `Tests/OmniTransTests/OCRGenerationGuardTests.swift` 4 例：递增、仅当前代际有效、
  新捕获后旧代际失效、并发 200 次严格递增无重复。

**验证**：`swift build`（clean）0 error / 0 warning；`swift test` 16/16 passed
（OmniTransTests 4 + DisplayGeometryTests 12）。集成验证需真机 ⌥F：框选结束即现「解析中…」、
弹窗无空白帧、快速连续触发无重复弹窗/结果串台。

## 2026-11 全项目审计修复（0.7.0）

依据 docs/audit-2026-11.md + plans/fix-plan-2026-11.md，分支 fix/audit-2026-11：

- **S1** ⌥R：changeCount 消费检测前提错误（粘贴读取不增计数）→ 写入后基线 + 0.5s 宽限期 + 第三方写入保护
- **S2** OCR 首帧：OnceGate 取消竞态死锁 → continuation 槽 + 早到结果暂存 + 存入后查取消；停流改 OnceGate 竞速真超时；acquired 标志防误释放
- **S3** Keychain 迁移：defer 覆盖重试标记 → 显式标记 + batchReadAll 合并回读
- **H1-H12**：降级深度上限 + CancellationError 短路；火山 TextList JSONSerialization；关闭键统一 dismiss_mode；热键 0 哨兵改存在性判断；录制 monitor 生命周期；PasteboardSnapshot 全保真；AX 选区记录/恢复；AnimationGate 未注册键按启用；窗口 hide/show 代际；抑制计数器；防抖 providerID 快照；注册状态日志 + 引导页权限实时刷新
- **M 系列**：签名 URL 脱敏、TTS utterance 身份守卫、SSE onTermination、语言包仅 installed 缓存、耗时公式补整秒、busy 上抛、预热 markFailed、原子写、MainActor hop、UserDefaults 观察者
- 死代码清除约 12 处；ATS 阿里云例外移除（远端全 https）；版本统一 0.7.0
- 测试 49 → 58+ 例；Debug/Release 0 error / 0 warning

## 密钥存储重构：钥匙串 → 本地加密存储（2026-11-21）

**问题**：重新编译后打开应用弹系统钥匙串密码，且输入正确密码被拒。根因：Phase 0
的 R2 改动删除 entitlements `keychain-access-groups` 并启用 Hardened Runtime，
叠加 ad-hoc 签名每次编译 cdhash 变化 → 钥匙串条目 access group/签名 ACL 全失配
→ SecurityAgent 弹窗；组失配下正确密码也可能被拒，重复失败还会锁定登录钥匙串。

**重构**：`SecretStore`（替代 KeychainManager，删除全部 SecItem 代码）
- 主密钥：`SecRandomCopyBytes` 32B，存 `.master.key`（0600）——替代 IOPlatformUUID
  派生（换主板不再丢钥），不再访问钥匙串（零弹窗）
- 密文：整表 `[UUID: SecretFields]` → JSON → AES-256-GCM 单密文块
  `secrets.v2.json`（0600）；每次保存新 nonce + 原子写，实例锁串行化
- 迁移：v1 `secrets.json` 首次访问自动解密重加密（LegacyV1 仅迁移用）并删旧文件；
  钥匙串存量不自动导入（读取即弹窗），受影响用户重输一次 API Key
- 安全边界：防误传/云备份泄漏/其他用户/未解锁磁盘；不防同账户恶意进程；
  静态加密依赖 FileVault（README 已注明）
- 测试 8 例：往返、跨实例持久化、删除/空保存、权限与密钥尺寸、坏密文、
  错主密钥、v1 迁移、不可解密 v1

## 功能审计 P0 修复（2026-11-21）

**流式**：解析层识别流内 error（OpenAI/Anthropic/Gemini）与 finish_reason
（length/content_filter/max_tokens/SAFETY）→ 抛错触发回退；零输出兜底；
extractText 改 throwing 不占解码失败配额；SSE 专用 session resource 60s→300s
+ `Accept: text/event-stream`。

**词典/翻译**：forceRefresh 绕过翻译缓存与同文跳过（重试按钮修复）；
L2 统一存归一化 JSON（含 native 补全），native 查词补写 L2；历史统一 schema
（召回不再解码失败）；CSV 导入改 RFC4180 引号感知解析（4 例测试）。

**窗口**：高度更新改「节流+尾随」（基准=距上次执行），修复流式期间任务饥饿；
流式期间 animate:false，消除 0.22s 动画重叠风暴。

验证：102 例测试 0 失败；后续 P1 项（增量渲染、chrome 持续测量、WordDetector
归一化、流测试）待办。

## 功能审计 P1 修复（2026-11-21）

- **流式**：增量拼接渲染（去每批 joined）；SSELineParser 纯函数（兼容
  `data:{…}`，过滤 [DONE]）；parseAndFlush 错误/取消路径冲刷缓冲；
  11 例新测试（SSE/合并/归一化）
- **窗口**：上下 Chrome 改 onGeometryChange 持续测量；流式高度测量节流
  （≥24 字符才全量 boundingRect）；NSCache 按长度计费 + costLimit
- **词典**：WordDetector Unicode 归一化 + CJK 扩展区；`_ctx` 键读写对齐；
  isFromLocalCache 语义修正；双源合并纯函数化
- 验证：113 例测试 0 失败；Debug/Release 0 警告
