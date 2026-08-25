# OmniTrans 全面代码审计报告

> 版本: v0.9 | 审计日期: 2026-08-13 | 模式: 静态代码审计（未修改任何代码）
> 审计范围: `Sources/` 全部 Swift 文件、`Tests/`、构建脚本（build.sh / build-arm.sh / build-intel.sh / scripts/omnitrans-build-common.sh）、`Package.swift`、`Resource/entitlements.plist`
> 严重级别: **Critical**（错误/崩溃/数据损坏）· **Major**（明显缺陷或显著性能/一致性隐患）· **Minor**（可维护性/小隐患）

---

## 1. 概览

共审计 60 个 Swift 源文件 + 4 个构建脚本 + 配置文件。按「Bug 隐患 / 性能优化 / 可维护性规范」三维度逐文件检查。下文每个发现均给出问题描述、相对路径与行号、严重级别、修复建议。报告末尾给出按严重级别的汇总与 Top 5 优先处理项。

审计方法说明：核心文件（状态机、翻译管线、OCR、存储、热键、替换、窗口）进行了逐行深审；动画/主题/纯 UI 布局文件进行了模式扫描与重点抽查。发现主要集中在线程安全、主线程阻塞、每次请求新建 Actor 的状态管理、以及若干易误读/易失效的实现。

---

## 2. Bug 隐患

### B1. [Critical] 原位替换在主线程同步阻塞最长 2 秒
- 文件: [`Sources/OmniTrans/Services/TextReplacementService.swift`](Sources/OmniTrans/Services/TextReplacementService.swift:40)（`replaceSelectedText` 内 `while CACurrentMediaTime() < deadline { ... Thread.sleep(0.05) }`，`@MainActor` 方法）
- 问题: 该方法运行在 `@MainActor` 上，内部同步 spin-loop 等待剪贴板被消费，最多阻塞主线程 2 秒。期间整个 UI（含菜单栏、面板、拖拽）完全无响应；`⌥R` 又是用户高频操作，极易感知为"卡死"。
- 建议: 改为异步：`simulatePaste()` 后 `try? await Task.sleep(...)` 轮询（方法改 `async`），或在后台队列轮询后回到主线程恢复剪贴板。

### B2. [Critical] Volcengine 签名参数双重百分号编码
- 文件: [`Sources/OmniTrans/Services/TranslationActor_MT.swift`](Sources/OmniTrans/Services/TranslationActor_MT.swift:231)（`TextList` = `"[\(percentEncode(sourceText))]"`）
- 问题: 源文本先被 `percentEncode`（`%20` 等），外层 `buildSignedQuery` 对参数值再次 `percentEncode`，导致 `%` 被编码为 `%25`。含空格/中文/特殊字符的源文本经服务端解码后会得到错误文本，翻译内容错误或签名校验失败；仅纯 ASCII 无保留字符时"碰巧"正常。对照同文件 `testConnectivity`（第 252 行直接传 `"[hello]"`）行为不一致。
- 建议: 去掉内层预编码，直接传 `"[\"\(sourceText)\"]"` 或 `"[\(sourceText)]"`，与 `buildSignedQuery` 的单次编码一致；并用含特殊字符的文本做真实联通性测试。

### B3. [Major] `ThrottledStream` 并发安全依赖 Actor 隔离的隐性继承
- 文件: [`Sources/OmniTrans/Services/TranslationActor.swift`](Sources/OmniTrans/Services/TranslationActor.swift:841)（`ThrottledStream` 普通 class，`buffer`/`flushTask` 可变）
- 问题: `yield()`/`scheduleFlush()` 在 `TranslationActor` 方法内被调用，其内部 `Task {}` 依赖"从 actor 隔离上下文创建 Task 会继承隔离"才保证 `buffer` 串行访问。这是隐式约定，一旦从非隔离上下文（如回调、新并发入口）调用即产生数据竞争；Swift 6 编译期已对 `self.buffer` 捕获给出并发警告。
- 建议: 将 `ThrottledStream` 改为 `actor`，或在内部用 `OSAllocatedUnfairLock`/`Mutex` 显式保护 `buffer` 与 `flushTask`，消除对隔离继承的隐性依赖。

### B4. [Major] `SystemTranslationEngine.installedCache` 静态可变字典无同步
- 文件: [`Sources/OmniTrans/Services/SystemTranslationEngine.swift`](Sources/OmniTrans/Services/SystemTranslationEngine.swift:40)（`nonisolated(unsafe) private static var installedCache: [String: Bool]`）
- 问题: 该静态字典由 `nonisolated` 方法读写，可在多线程（warmUp 后台 Task、翻译请求）并发访问；同时读写 `UserDefaults`。`nonisolated(unsafe)` 只是绕过编译器检查，不提供线程安全，存在数据竞争 UB。
- 建议: 改为 actor 包一层，或用 `OSAllocatedUnfairLock` 保护；缓存读写做成原子操作。

### B5. [Major] `NativeDictionaryParser.stripPinyin` 误删带重音英文词
- 文件: [`Sources/OmniTrans/Services/NativeDictionaryParser.swift`](Sources/OmniTrans/Services/NativeDictionaryParser.swift:323)
- 问题: `stripPinyin` 把「含声调元音字符（含 é、è 等）」的整个单词当作拼音删除。英文词如 café、résumé、cliché、naïve 会被错误地从释义中剔除，导致词典释义缺失。
- 建议: 结合上下文判断（仅当整词为小写字母+声调且词长较短时视为拼音），或将声调字符集合限制为中文拼音专用组合；补充单元测试覆盖 café/résumé。

### B6. [Major] 每次翻译新建 `TranslationActor()` 实例
- 文件: [`Sources/OmniTrans/Services/TranslationEngineFactory.swift`](Sources/OmniTrans/Services/TranslationEngineFactory.swift:23)、[`Sources/OmniTrans/Services/TranslationService.swift`](Sources/OmniTrans/Services/TranslationService.swift:42)
- 问题: 工厂与 `TranslationService.translate` 每次调用 `TranslationActor()` 生成新 actor。actor 内的 `activeStreamTask?.cancel()`（[`TranslationActor.swift`](Sources/OmniTrans/Services/TranslationActor.swift:197)）针对的是旧实例的状态，每次新建导致「取消上一请求」机制在 actor 层面失效，仅靠上层 `AppState.activeStreamTask` 兜底；同时无谓分配与丢弃 actor。
- 建议: 工厂返回共享单例 `TranslationActor.shared`（actor 本身线程安全），`TranslationService` 同样复用，保证取消语义与连接池一致。

### B7. [Major] `AppState` 与 `ConfigurationStore` 双数据源漂移
- 文件: [`Sources/OmniTrans/Models/Stores.swift`](Sources/OmniTrans/Models/Stores.swift:42)、[`Sources/OmniTrans/Models/AppState.swift`](Sources/OmniTrans/Models/AppState.swift:15)
- 问题: `ConfigurationStore` 维护 providers/selectedProviderID/sourceLang 等副本，仅 `syncFrom(_:)` 一次性同步；此后 `AppState` 的任何修改（切 provider、改语言、增删 provider）都不会自动反映到 `ConfigurationStore`。若视图观察 `ConfigurationStore` 而逻辑写 `AppState`，会出现界面与实际状态不一致。
- 建议: 收敛为单一数据源（去掉 `ConfigurationStore` 副本，或让 `AppState` 通过 `@Observable` 直接发布），消除双写与漂移。

### B8. [Major] `HotkeyManager` 三个独立 `InstallEventHandler` 与维护文档不符
- 文件: [`Sources/OmniTrans/Services/HotkeyManager.swift`](Sources/OmniTrans/Services/HotkeyManager.swift:217,238,255)；文档: [`memories/repo/macos-compat-fixes.md`](memories/repo/macos-compat-fixes.md:3)
- 问题: `register()`/`registerOCR()`/`registerReplace()` 各自调用一次 `InstallEventHandler`（handler 分别为 handlerRef/ocrHandlerRef/replaceHandlerRef）。记忆文档声称已合并为"一次性安装单一 handler + 共用 handlerRef"，与当前实现不一致。同一 `kEventHotKeyPressed` 事件会命中三个 handler（按 `hid.id` 分发），虽功能可用但属于文档与代码脱节，且存在重复回调隐患。
- 建议: 收敛为单次 `InstallEventHandler` 安装、三个 hotkey 共用一个 handler，并同步更新文档；`unregister` 逻辑一并统一。

### B9. [Major] 设置面板滑块改动触发全量 Keychain 写入
- 文件: [`Sources/OmniTrans/Views/SettingsPanelContent.swift`](Sources/OmniTrans/Views/SettingsPanelContent.swift:141)（`onChange(of: translationTemp)`/`translationMaxTokens` → `syncTemperatureToProvider` → `state.updateProvider` → `save`）
- 问题: 拖动温度/Token 滑块每变化一步就 `updateProvider` → `ProviderStorageManager.saveProviders` → 对**所有 provider** 循环写 Keychain（AES 加密+文件写）+ 重写 UserDefaults。滑块高频触发会反复阻塞主线程（Keychain I/O 在 `@MainActor` 链路上）。
- 建议: 滑块变更防抖（停止拖动后再保存），或将 Keychain 写入改为「仅变更项」增量写。

### B10. [Major] `StreamingDictParser` 每个 chunk 全量重解析累积 buffer
- 文件: [`Sources/OmniTrans/Models/DictionaryEntry.swift`](Sources/OmniTrans/Models/DictionaryEntry.swift:142)
- 问题: `feed(_:)` 每次把 `buffer += chunk` 后调用 `extractDefinitions(from: buffer)` 重新解析整个已累积 JSON。流式词典输出时 buffer 持续增长，每次 token 都做 O(buffer) 的全量正则扫描，浪费 CPU。
- 建议: 记录已解析的字节偏移，仅对新增部分增量解析；或限制 buffer 长度并只做低频（如每 N chunk）全量校验。

### B11. [Minor] `TranslationActor.parseSSEStream` 静默吞掉解码错误
- 文件: [`Sources/OmniTrans/Services/TranslationActor.swift`](Sources/OmniTrans/Services/TranslationActor.swift:160)
- 问题: `guard let chunk = try? decoder.decode(...)` 用 `try?` 静默忽略每个 `data:` 行解码失败。若服务端格式变化导致持续解码失败，会表现为"流式无输出"且无任何日志。
- 建议: 解码失败时至少 `NetworkLogger` 记录一次并统计连续失败次数，达到阈值后抛出，避免无限静默。

### B12. [Minor] OCR 捕获的 `CVPixelBuffer` 未显式加锁/解锁
- 文件: [`Sources/OmniTrans/Services/CaptureService.swift`](Sources/OmniTrans/Services/CaptureService.swift:26)、[`Sources/OmniTrans/Services/OCRSelectionOverlay.swift`](Sources/OmniTrans/Services/OCRSelectionOverlay.swift:108)
- 问题: 协议文档要求调用方对 buffer "lock 后使用、立即 unlock"，但实际 `performOCR` 未调用 `CVPixelBufferLockBaseAddress`。SCK 返回的 IOSurface-backed buffer 通常可直接读，但严格按文档应加锁以防被回收/复用。
- 建议: 在 Vision 处理前后显式 `CVPixelBufferLockBaseAddress`/`UnlockBaseAddress`（只读标志），与文档一致。

### B13. [Minor] `AppState` 多个 `asyncAfter` 强捕获 `self`
- 文件: [`Sources/OmniTrans/Models/AppState.swift`](Sources/OmniTrans/Models/AppState.swift:255,327,350,456,479,520,532,626)
- 问题: 多数 `DispatchQueue.main.asyncAfter` 闭包直接捕获 `self`（`AppState` 为进程级单例，不会真正泄漏，但风格不统一）；第 626 行有 `[weak self]` 而其余没有。
- 建议: 统一加 `[weak self]`，与第 626 行保持一致，避免将来将 `AppState` 改为非单例时引入引用循环。

### B14. [Minor] `MemoryPurgeHelper` 的 `task_info` 返回值未使用
- 文件: [`Sources/OmniTrans/Utils/MemoryPurgeHelper.swift`](Sources/OmniTrans/Utils/MemoryPurgeHelper.swift:69)
- 问题: `if kr == KERN_SUCCESS { _ = info }` 为死代码——查询结果既未使用也无副作用。
- 建议: 删除该段，或真正用返回数据（如 `phys_footprint`）做日志/指标。

### B15. [Minor] `TTSManager.isSpeaking` 恒为 `false`
- 文件: [`Sources/OmniTrans/Services/TTSEngine.swift`](Sources/OmniTrans/Services/TTSEngine.swift:218)
- 问题: 占位实现，任何调用都返回 false；若 UI 依赖它做按钮态/打断逻辑会失效。
- 建议: 由底层引擎上报真实状态，或移除该属性及引用方。

### B16. [Minor] `OpenAITTSEngine` 使用 `URLSession.shared` 且无超时
- 文件: [`Sources/OmniTrans/Services/TTSEngine.swift`](Sources/OmniTrans/Services/TTSEngine.swift:175)
- 问题: 未复用 `sharedURLSession`（无 HTTP/2 连接池与统一超时），`data(for:)` 无显式 `timeoutInterval`。
- 建议: 改用 `sharedURLSession` 并设置超时。

---

## 3. 性能优化

### P1. [Critical] 原位替换主线程自旋阻塞（同 B1）
见 B1；主线程阻塞 2 秒属严重性能/交互问题，优先处理。

### P2. [Major] `ProviderStorageManager.saveProviders` 全量写 Keychain（含 P9 高频触发）
- 文件: [`Sources/OmniTrans/Services/ProviderStorageManager.swift`](Sources/OmniTrans/Services/ProviderStorageManager.swift:88)
- 问题: 每次 `save()` 对全部 provider 循环 `KeychainManager.saveFields`（AES 加密 + 全文件重写 `secrets.json`），`@MainActor` 链路上同步执行；配合设置面板滑块高频调用（见 B9）会明显卡顿。
- 建议: 改为「仅变更 provider」增量写；Keychain 写与文件写移出主线程；`secrets.json` 用原子写并缓存密钥派生结果（见 P3）。

### P3. [Minor] `KeychainManager.deriveKey` 每次派生 + 全文件重写
- 文件: [`Sources/OmniTrans/Utils/KeychainManager.swift`](Sources/OmniTrans/Utils/KeychainManager.swift:47,128)
- 问题: 每次加密/解密都执行 `HKDF` 派生；每次 `saveFields` 都重加密整本字典。小数据量下耗时低，但可缓存对称密钥与合并写。
- 建议: 缓存派生密钥（进程级）；多次字段更新合并为一次落盘。

### P4. [Minor] 流式渲染 `onChange(of: session.translatedText)` 高频调用
- 文件: [`Sources/OmniTrans/Views/FloatingPanelContent.swift`](Sources/OmniTrans/Views/FloatingPanelContent.swift:245)
- 问题: 每个批次 token 到达都触发 `updateStatusFromSession()` + `scheduleHeightUpdate(debounce:)`。高度更新已有 50ms 防抖，但状态更新与高度计算仍逐 token 执行，且 `ContentHeightCalculator.accurateTextHeight`（`boundingRect`）在流式期间可能被高频调用（虽有行数缓存）。
- 建议: 状态灯更新合并到防抖任务中；`boundingRect` 结果按「文本前缀 + 宽度」缓存，减少重复测量。

### P5. [Minor] `formattedCacheTimestamp` 每次调用创建多个 DateFormatter
- 文件: [`Sources/OmniTrans/Views/FloatingPanelContent.swift`](Sources/OmniTrans/Views/FloatingPanelContent.swift:65)
- 问题: body 计算中每次创建 `ISO8601DateFormatter` + 两个 `DateFormatter`。日期格式化开销小但在列表/重绘中反复发生。
- 建议: 静态/单例化 formatter（`Thread-safe` 或 `MainActor` 单例）。

### P6. [Minor] `htmlEntityDecoded`/`preprocess` 用 `NSAttributedString` 解析 HTML
- 文件: [`Sources/OmniTrans/Services/TranslationActor_MT.swift`](Sources/OmniTrans/Services/TranslationActor_MT.swift:8)、[`Sources/OmniTrans/Services/NativeDictionaryParser.swift`](Sources/OmniTrans/Services/NativeDictionaryParser.swift:142)
- 问题: HTML 实体解码依赖 `NSAttributedString(documentType: .html)`，在非主线程构造会有线程告警且开销较高；MT 每次翻译结果解码都走此路径。
- 建议: 对常见实体（`& < > " ' &nbsp;`）用轻量字典替换，仅对未知实体回退 HTML 解析。

### P7. [Minor] `ConfigurationStore` 计算属性反复读 `UserDefaults`
- 文件: [`Sources/OmniTrans/Models/Stores.swift`](Sources/OmniTrans/Models/Stores.swift:55,68,80,94)
- 问题: `isContextAwareEnabled`/`contextIntensity`/`isCacheEnabled`/`isDictCacheEnabled` 每次读取都访问 `UserDefaults`；`buildCacheKey` 每次翻译读取多次。
- 建议: 启动时缓存到内存并在写时更新，避免高频磁盘读。

### P8. [Minor] `LocalDictionaryRepository.batchImport` 每行 prepare 语句
- 文件: [`Sources/OmniTrans/Services/LocalDictionaryRepository.swift`](Sources/OmniTrans/Services/LocalDictionaryRepository.swift:171)
- 问题: CSV 导入在事务内对每行 `sqlite3_prepare_v2`，行数多时 prepare 开销累积。
- 建议: 复用 prepared statement（仅 rebind）。

### P9. [Minor] 设置面板 `onChange` 未防抖（同 B9）
见 B9：滑块每步触发完整保存链路，主线程 I/O 密集。

### P10. [Minor] `OCRHardwareMode` 启动探针在主线程链路外仍可能延迟首帧
- 文件: [`Sources/OmniTrans/Services/OCRHardwareMode.swift`](Sources/OmniTrans/Services/OCRHardwareMode.swift:67)
- 问题: 探针在后台 Task 运行（设计正确），但 `OCRHardwareMode.current` 在探针完成前默认为 `.fast`，若用户在探针期间触发 OCR 会走 `.fast` 分支，行为与探针完成后不一致（可接受，但可在 UI 上提示）。
- 建议: 可选：探针完成时若已发生 OCR，提示用户重试以获得 `.accurate` 质量。

---

## 4. 可维护性与规范性

### M1. [Major] `ConfigurationStore` 与 `AppState` 双 SSOT（同 B7）
见 B7；建议收敛数据源，避免双份状态与 `syncFrom` 一次性同步的漂移。

### M2. [Major] `HotkeyManager` 实现与维护文档不一致（同 B8）
见 B8；修复后需同步更新 [`memories/repo/macos-compat-fixes.md`](memories/repo/macos-compat-fixes.md)。

### M3. [Minor] `FallbackRouter.probeProvider` 运算符优先级易误读
- 文件: [`Sources/OmniTrans/Services/FallbackRouter.swift`](Sources/OmniTrans/Services/FallbackRouter.swift:101)
- 问题: `let alive = (resp as? HTTPURLResponse)?.statusCode ?? 0 < 500`。按 Swift 优先级（`??` 高于 `<`）实际等价于 `(statusCode ?? 0) < 500`，逻辑正确，但极易被读成 `statusCode ?? (0 < 500)` 而误判为 bug。
- 建议: 显式加括号 `((resp as? HTTPURLResponse)?.statusCode ?? 0) < 500`，消除歧义。

### M4. [Minor] OSLog subsystem 字符串不统一
- 文件: [`Sources/OmniTrans/Services/NetworkConfig.swift`](Sources/OmniTrans/Services/NetworkConfig.swift:60)、[`Sources/OmniTrans/Services/SystemTranslationEngine.swift`](Sources/OmniTrans/Services/SystemTranslationEngine.swift:8)（`com.omnitrans.omnitrans`）、[`Sources/OmniTrans/Services/HistoryActor.swift`](Sources/OmniTrans/Services/HistoryActor.swift:28)、[`Sources/OmniTrans/Services/TTSEngine.swift`](Sources/OmniTrans/Services/TTSEngine.swift:41)（`com.omnitrans.app`）
- 问题: 日志子系统混用 `com.omnitrans.app` 与 `com.omnitrans.omnitrans`，且 `NetworkConfig` 有 `Bundle.main.bundleIdentifier` 兜底而其余没有，导致 `log stream` 过滤与统计口径不一致。
- 建议: 统一为常量 `Bundle.main.bundleIdentifier ?? "com.omnitrans.app"`，集中定义。

### M5. [Minor] `entitlements.plist` 声明与实现不符
- 文件: [`Resource/entitlements.plist`](Resource/entitlements.plist:5)
- 问题: 声明 `keychain-access-groups: com.omnitrans.arm64`，但密钥实际用「文件 AES-GCM 加密 + `StoragePaths.secretsFile`」（[`Utils/KeychainManager.swift`](Sources/OmniTrans/Utils/KeychainManager.swift:38)），并不使用 Keychain。此外该 entitlement 中的 bundle id `com.omnitrans.arm64` 与 universal 产物 `com.omnitrans.app` 不一致。
- 建议: 若确不用 Keychain，删除该 entitlement 键或与产物 bundle id 对齐，避免签名/沙盒困惑。

### M6. [Minor] `AppState` 中 `retryCount`/`maxAutoRetry` 为死状态
- 文件: [`Sources/OmniTrans/Models/AppState.swift`](Sources/OmniTrans/Models/AppState.swift:89,90,264,459)
- 问题: `retryCount`/`maxAutoRetry` 只被赋值/重置为 0，从未参与实际重试决策（重试由 `RetryUtility` 与 fallback 承担），属于未完成逻辑残留。
- 建议: 删除或接入真实自动重试计数。

### M7. [Minor] `NativeDictionaryParser.attachExamples` 为空实现
- 文件: [`Sources/OmniTrans/Services/NativeDictionaryParser.swift`](Sources/OmniTrans/Services/NativeDictionaryParser.swift:359)
- 问题: 函数体只有注释与空 return，永不把 examples 附加到 definitions；名称误导，且 `definitions` 内的 `examples` 关联逻辑缺失。
- 建议: 实现「最近 definition 归属」关联，或删除空实现并在注释中明确 examples 为顶层字段。

### M8. [Minor] 各处 `print(...)` 生产噪音
- 文件: 散见 [`TranslationActor.swift`](Sources/OmniTrans/Services/TranslationActor.swift:686)、[`TranslationActor_MT.swift`](Sources/OmniTrans/Services/TranslationActor_MT.swift:145,676)、[`NativeDictionaryParser.swift`](Sources/OmniTrans/Services/NativeDictionaryParser.swift:128)、[`DictionaryEntry.swift`](Sources/OmniTrans/Models/DictionaryEntry.swift:58)、[`LocalDictionaryRepository.swift`](Sources/OmniTrans/Services/LocalDictionaryRepository.swift:53)、[`MemoryPurgeHelper.swift`](Sources/OmniTrans/Utils/MemoryPurgeHelper.swift:41) 等
- 问题: 大量 `print` 直接输出到 stdout（含每次词典解析/每次 save），Release 构建仍保留，影响 Console 可读性与性能（`print` 有锁）。
- 建议: 统一改用 `OSLog`/`Logger`，敏感信息（如 MT 响应体前缀、apiKey 前缀日志）按 S2 脱敏并降级到 debug 级别。

### M9. [Minor] 硬编码默认模型名/过期模型
- 文件: [`Sources/OmniTrans/Models/APIProvider.swift`](Sources/OmniTrans/Models/APIProvider.swift:45)、[`Sources/OmniTrans/Services/APITestService.swift`](Sources/OmniTrans/Services/APITestService.swift:102)
- 问题: `claude-3-haiku-20240307` 等默认/回退模型名已过时；Anthropic 模型列表为硬编码。
- 建议: 更新为当前可用模型，或从各厂商 models 端点拉取（OpenAI/Gemini 已支持，Anthropic 可维护常量表）。

### M10. [Minor] 窗口定位/contentsScale 依赖 `NSScreen.main`
- 文件: [`Sources/OmniTrans/Services/FloatingPanel.swift`](Sources/OmniTrans/Services/FloatingPanel.swift:188)、[`Sources/OmniTrans/Services/WindowManager.swift`](Sources/OmniTrans/Services/WindowManager.swift:76)、[`Sources/OmniTrans/Services/OmniPanel.swift`](Sources/OmniTrans/Services/OmniPanel.swift:150)、[`Sources/OmniTrans/Services/SettingsWindowManager.swift`](Sources/OmniTrans/Services/SettingsWindowManager.swift:84)、[`Sources/OmniTrans/Services/OCRSelectionOverlay.swift`](Sources/OmniTrans/Services/OCRSelectionOverlay.swift:410)
- 问题: 多处仍以 `NSScreen.main` 作为兜底/基准。OCR 取词路径已修复，但窗口定位与 `contentsScale` 仍可能在主屏非鼠标所在屏时定位不准/文字模糊。
- 建议: 沿用 `DisplayGeometry.screen(containing:nearestScreen:)` 统一按鼠标所在屏定位与取 scale。

### M11. [Minor] `ContentHeightCalculator` 缓存 key 使用 `text.hashValue`
- 文件: [`Sources/OmniTrans/Utils/ContentHeightCalculator.swift`](Sources/OmniTrans/Utils/ContentHeightCalculator.swift:118)
- 问题: `String.hashValue` 存在理论哈希碰撞，极端情况下返回错误行数；且 `LineCountCache` 的 `countLimit` 设置逻辑（第 127-129 行）无实际作用。
- 建议: 直接用 `text` 作为 NSCache key（`NSString`）；删除无意义的 countLimit 赋值。

### M12. [Minor] 硬编码/魔法数值
- 文件: [`Sources/OmniTrans/Services/TranslationActor_MT.swift`](Sources/OmniTrans/Services/TranslationActor_MT.swift:675)（阿里云 URL 硬编码 `https://mt.cn-hangzhou.aliyuncs.com`）、[`Sources/OmniTrans/Services/FallbackRouter.swift`](Sources/OmniTrans/Services/FallbackRouter.swift:40)（fallback 模型 `qwen2.5:1.5b`）、[`Sources/OmniTrans/Models/AppState.swift`](Sources/OmniTrans/Models/AppState.swift:98)（UserDefaults key 字符串散落）
- 问题: 关键 URL、模型名、UserDefaults key 以字符串散落多处，无集中常量。
- 建议: 抽取到 `NetworkConfig`/`StorageKeys` 等常量类型集中管理。

---

## 5. 按严重级别汇总

### Critical（2）
| # | 位置 | 问题 |
|---|---|---|
| C1 | TextReplacementService.swift:40 | 主线程同步阻塞 ≤2s（UI 冻结） |
| C2 | TranslationActor_MT.swift:231 | Volcengine 签名双重编码 → 源文本错误/签名失败 |

### Major（9）
| # | 位置 | 问题 |
|---|---|---|
| M1 | TranslationActor.swift:841 | ThrottledStream 并发安全依赖隐性隔离继承 |
| M2 | SystemTranslationEngine.swift:40 | 静态可变字典无同步（数据竞争） |
| M3 | NativeDictionaryParser.swift:323 | stripPinyin 误删带重音英文词 |
| M4 | TranslationEngineFactory/TranslationService | 每次新建 TranslationActor，取消语义失效 |
| M5 | Stores.swift:42 + AppState | 双数据源漂移 |
| M6 | HotkeyManager.swift:217/238/255 | 三处 InstallEventHandler 与文档不符 |
| M7 | SettingsPanelContent.swift:141 + ProviderStorageManager:88 | 滑块高频触发全量 Keychain 写（主线程） |
| M8 | DictionaryEntry.swift:142 | StreamingDictParser 每 chunk 全量重解析 |
| M9 | TextReplacementService（B1 合并） | （归入 C1，不重复计数） |

### Minor（约 20）
B11–B16、P3–P10、M3–M12 等（详见上文编号）。

---

## 6. 优先处理 Top 5

1. **TextReplacementService 主线程自旋阻塞（C1）** — 改为异步轮询，消除 ⌥R 的 UI 冻结。
2. **Volcengine 签名双重编码（C2）** — 修正 `TextList` 编码，避免含特殊字符源文本翻译错误/签名失败。
3. **ThrottledStream 并发安全（Major M1）** — 显式 `actor`/锁，消除对隔离继承的隐性依赖（流式翻译主链路）。
4. **每次新建 TranslationActor + 双数据源漂移（Major M4/M5）** — 复用共享 actor 单例、收敛 AppState/ConfigurationStore 数据源，提升状态一致性与可维护性。
5. **滑块高频触发全量 Keychain 写（Major M7）** — 保存防抖 + 增量写，避免设置界面卡顿。

---

## 7. 说明

- 本报告为**静态审计**，未对代码做任何修改；建议按 Top 5 顺序逐一修复并补充单元测试（尤其是 C2 的签名场景与 M3 的拼音剥离场景）。
- 与既有文档一致性结论：`memories/repo/macos-compat-fixes.md` 中「HotkeyManager 合并单事件处理器」与当前代码不符（见 B8/M2），需同步修正代码或文档；其余构建脚本文档与实现一致。
