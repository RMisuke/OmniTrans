# OmniTrans 审计修复方案（2026-11-14）

> 依据：[docs/audit-2026-11.md](../docs/audit-2026-11.md)（3 严重 / 12 高危 / 17 中危 / 低危若干）
> 原则：先止血（P0）→ 再修高危（P1）→ 后清理加固（P2/P3）；每组独立提交、独立验证；修复与回归测试同步落地
> 预估工作量：P0 约 0.5–1 天 · P1 约 1.5–2 天 · P2 约 0.5 天 · P3 约 1 天（合计 3–4 个工作日）

---

## 阶段 0：基线保护（前置，需用户确认）

当前工作区有 27 文件未提交改动（含 2 处回归 H6/M11），直接在其上修复会混淆 diff 归属。

| 步骤 | 操作 | 说明 |
|---|---|---|
| 0.1 | 创建修复分支 `fix/audit-2026-11` | 本地可逆操作 |
| 0.2 | 将现有未提交改动按主题拆分提交（建议 3 个）：① UI Liquid Glass 适配 + 状态灯优先级修复 ② 存储/引擎优化（增量 Keychain 写、单例复用、StoragePaths 缓存）③ OCR 调参 + 权限 UX | 拆分时**先剔除回归**：H6（OCRWarmupState.ensureCacheValid 阻塞链 + App.swift 3s 轮询）与 M11（maxAttempts 2→1）暂不提交或提交后立即在 P1 修复；H3（@available 吞注释）在提交前顺手修正 |
| 0.3 | 记录基线：`swift build` + `swift test` 全绿快照 | 每个阶段结束对照 |

⚠️ 提交操作需用户明确批准后执行。若用户希望保留现状不拆分，则跳过 0.2，全部修复完成后一次性审阅提交。

---

## 阶段 1（P0）：三个严重问题

### 1.1 S1 — ⌥R 原位替换失效
**文件**：`Services/TextReplacementService.swift`
**根因**：自身写入已递增 changeCount，轮询首轮即恢复旧剪贴板；且粘贴读取根本不改变 changeCount，检测前提错误。

**修复方案**（放弃"消费检测"，改为"宽限期 + 第三方写入保护"）：
1. 写入替换文本后记录 `postWriteCount = pasteboard.changeCount`（而非写入前的旧值）。
2. `simulatePaste()` 后等待固定宽限期 **0.5s**（`Task.sleep`，覆盖目标应用处理 Cmd+V 的延迟；保留 2s 上限语义可配）。
3. 宽限期结束检查：若 `changeCount > postWriteCount`（期间有第三方写入，如用户复制了新内容）→ **不恢复**，避免覆盖用户新数据；否则恢复备份。
4. 恢复写入前再次置 `ClipboardMonitor.shared.suppressNext = true`（配合 2.4 的计数器化，覆盖恢复写入自身）。
5. 删除"changeCount 变化=已消费"的错误注释，改写为真实语义说明。

**测试**：
- 新增 `TextReplacementTests`：把恢复判定抽为纯函数 `shouldRestore(postWriteCount:currentCount:)`，覆盖「无第三方写入→恢复」「有第三方写入→不恢复」两分支。
- 手动冒烟：TextEdit / Notes / Safari 三处 ⌥R，确认粘贴的是译文且原剪贴板内容恢复；剪贴板监控开启时不触发二次翻译。

**风险**：宽限期 0.5s 对极慢应用可能不足 → 保留常量可调；不做 CGEvent tap 监听（过度设计）。

### 1.2 S2 — OCR 首帧等待取消竞态死锁
**文件**：`OCR/Capture/ScreenRegionCapturing.swift`（SingleFrameStreamOutput，:278-299）
**根因**：onCancel 先耗尽 OnceGate 时 continuation 尚未存入，之后存入的 continuation 永不 resume；task group 隐式等待所有子任务 → 永久挂起。

**修复方案**（以 continuation 槽本身作为恰好一次机制）：
1. `finish()` 改为直接持锁操作槽位，**移除 OnceGate 依赖**：
   ```swift
   private func finish(_ result: Result<PixelBufferBox?, Error>) {
       state.withLock { cont in
           cont?.resume(with: result)
           cont = nil
       }
   }
   ```
   锁保证无论帧到达/取消/超时何种交错，resume 恰好一次。
2. `waitFirstFrame()` 在存入 continuation 后**立即检查取消**：
   ```swift
   try await withTaskCancellationHandler {
       try await withCheckedThrowingContinuation { cont in
           state.withLock { $0 = cont }
           if Task.isCancelled { finish(.success(nil)) }
       }
   } onCancel: { finish(.success(nil)) }
   ```
   交错分析：取消先于存入 → onCancel 见 nil 无操作，存入后 isCancelled 补恢复；取消后于存入 → onCancel 恢复，isCancelled 检查见 nil。全路径恰好一次。
3. 顺带修复 **H4**（stopCapture 假超时）：改用项目既有 `ResumeGate` + 双 Task 竞速（stop 任务 vs 1s sleep 任务），超时后 stop 任务弃管继续运行（与项目弃管语义一致），调用方有限等待：
   ```swift
   await withCheckedContinuation { cont in
       let gate = ResumeGate()
       Task { try? await stream.stopCapture(); await gate.runOnce { cont.resume() } }
       Task { try? await Task.sleep(for: .seconds(1)); await gate.runOnce { cont.resume() } }
   }
   ```
4. 顺带修复 **H5**（误释放槽位）：do 块内用局部 `var acquired = false`，acquire 成功后置 true；两个 catch 仅在 `acquired` 时 release。

**测试**：新增 `SingleFrameOutputTests`（把类提升为 internal 供 @testable）：
- 取消先于帧到达 → 返回 nil 不挂起（带 1s 测试超时断言）
- 帧到达后取消 → 返回帧
- 重复 finish → 恰好一次 resume（崩溃即失败）
- 并发 100 次「随机时刻取消」压力测试无挂起
- 手动冒烟：⌥F 框选中途按 ESC 连续 10 次，再正常框选，确认无死锁。

### 1.3 S3 — Keychain 迁移丢密钥
**文件**：`Utils/KeychainManager.swift`（migrateLegacyFileIfNeeded，:242-267）

**修复方案**：
1. **移除 :244 的 defer**，各路径显式置标记：无旧文件→true；空/不可解密→删文件+true；全部迁移→删文件+true；部分失败→**false**（保留文件，下次启动重试）。
2. **防御纵深**：`batchReadAll()` 在 Keychain 后端下，若旧文件仍存在，则解密合并「Keychain 中缺失的 UUID」条目（只读合并，不写），保证当前进程内未迁移密钥也可见。
3. 修正 :262-263 错误注释。
4. 顺带修复 **M3**：删除 :131/:138/:157 三处 apiKey 前缀日志（或整体 `#if DEBUG` 门控）——与本次 diff 对 ProviderStorageManager 的处理保持一致。

**测试**：
- 把迁移判定抽为纯函数 `migrationOutcome(migrated:total:) -> (deleteFile: Bool, done: Bool)` 单测四分支。
- 手动验证：构造含 2 个 provider 的旧 secrets.json → 启动 → 确认迁入 Keychain 且文件删除；日志无密钥前缀。

**阶段 1 验收**：`swift build` 0 error / 0 warning（顺带修 R5 两处 withLock 警告：`_ =` 显式丢弃）；`swift test` 全绿 + 新增 ≥6 例；⌥R / ⌥F / 迁移三项手动冒烟通过。提交 1 个 commit（或按 S1/S2/S3 拆 3 个）。

---

## 阶段 2（P1）：高危修复（按子系统分组，减少上下文切换）

### 2.A 翻译管线组（H1 / H2 / H3 + M1 / M6 / M7 / M16）
| 步骤 | 修复 | 要点 |
|---|---|---|
| 2.A.1 | **H1 降级无限递归** | `doTranslate` 增加 `fallbackDepth: Int = 0` 参数，递归调用传 `depth+1`，`depth >= enabledProviders.count` 时停止降级直接报错；catch 首行检查 `error is CancellationError \|\| Task.isCancelled` → 静默返回不降级。`AppState+TranslationLogic.nextFallbackProvider` 保持不变（回绕语义由深度上限约束） |
| 2.A.2 | **H2 火山 TextList** | `("TextList", String(data: try JSONSerialization.data(withJSONObject: [sourceText]), encoding: .utf8)!)` 生成合法 JSON 数组（自动处理引号/转义/中文）；新增单测：含引号、反斜杠、换行、emoji、中文的文本编码后是合法 JSON 且往返一致 |
| 2.A.3 | **H3 @available 归位** | SystemTranslationEngine.swift:24 注释与属性拆回两行；保留内部 macOS 26 运行时守卫（保守行为不变，仅恢复编译期标注兼容旧 SDK） |
| 2.A.4 | **M1 签名 URL 脱敏** | NetworkConfig.logRequest 对含 `Signature`/`AccessKeyId` 查询参数的 URL 只记 scheme+host+path（或参数名列表），不记值 |
| 2.A.5 | **M6 TTS continuation** | 单槽改 `[UUID: CheckedContinuation]` 字典；新 speak 先 resume 旧 continuation（throw CancellationError）再登记；加 10s 超时兜底 |
| 2.A.6 | **M7 SSE 取消传播** | translateStream 保存内层 Task 句柄，onTermination 同时取消内外层 |
| 2.A.7 | **M16 语言包缓存** | 仅 `.installed` 才 markPackInstalled；`.supported` 走正常检查路径 |

验证：断网模拟（关 Wi-Fi）触发翻译 → 确认降级链有限步终止并显示错误；火山引擎真实连通性测试（含特殊字符文本）；`swift test` 新增 ≥4 例。

### 2.B OCR 组（H6 + M10 / M11 / M12 / M13 + L1 / L2 / L3）
| 步骤 | 修复 | 要点 |
|---|---|---|
| 2.B.1 | **H6 闲置重预热阻塞（回归）** | ensureCacheValid 不再调 retryWarmup（其同步置 isWarmingUp 会阻塞热键）；改为直接 `Task.detached { await OCRCapturePipeline.warmUpANE() }` 静默后台刷新，**不触碰 OCRWarmupState**；App.swift 热键回调删除 3s 轮询等待，恢复「缓存检查→直接框选」，预热与推理由既有闸门串行化。保留 lastWarmupCompletedAt 时间戳逻辑 |
| 2.B.2 | **M11 竞速重试（回归）** | RacingLanguageStrategy maxAttempts 默认恢复为 2 |
| 2.B.3 | **M10 耗时统计** | `ms = Double(components.seconds)*1000 + Double(components.attoseconds)/1e15`；同步修复 OCRBenchmarkTests:110 同式错误，使 15s 断言真实生效 |
| 2.B.4 | **M12 繁忙反馈** | 竞速策略 busy/熔断错误改为抛出类型化 `OCRError.engineBusy`（不再吞为 nil）；OCRSelectionOverlay 捕获后发送通知；核对 App.swift 观察者通知名一致（OmniTransOCREngineBusy），确保气泡可达 |
| 2.B.5 | **M13 预热锁死** | makeSyntheticBuffer 失败路径先 `await MainActor.run { OCRWarmupState.shared.markFailed() }` 再 return |
| 2.B.6 | **L1/L2 预热配额与进度** | 让路 continue 不计入 attempt（循环改 while + 手动计数，或 continue 前 attempt 不增）；maxAttempts 单一来源：OCRWarmupState.maxAttempts 改引用 ANEWarmup 默认常量（10） |
| 2.B.7 | **L3 取消语义** | 竞速兜底区分 CancellationError（向上抛）与超时（返回最优）；OCRResultAssembler 排序比较器改为严格弱序（先 y 后 x，容差内视为相等） |

验证：闲置 >5 分钟后 ⌥F 立即可框选（后台静默预热）；OCR 基准测试耗时数字合理（>1s 场景）；新增预热状态机/竞速仲裁单测 ≥5 例（mock 注入）。

### 2.C UI 交互组（H7–H12 + M8 / M9 / M15 / M17）
| 步骤 | 修复 | 要点 |
|---|---|---|
| 2.C.1 | **H7 关闭设置错配** | 统一键名 `dismiss_mode` 与取值（clickOutside/manualEsc）：FloatingPanel 改读同键同值；OmniPanel 基类 resignKey 改为调用可覆写的 `shouldOrderOutOnResign()`，FloatingPanel 覆写尊重 closeMethod + 0.1s 防误关 |
| 2.C.2 | **H8 热键 0 哨兵** | resolvedKey/resolvedMods 改用 `UserDefaults.object(forKey:) != nil` 判断是否设置（0 是合法 keyCode）；AppState:114 重置逻辑同步 |
| 2.C.3 | **H9 录制 monitor 泄漏** | GeneralTab 持有 monitor token，onDisappear + 开始新录制时 removeMonitor；换行录制先停旧 |
| 2.C.4 | **H10 剪贴板全保真** | 备份改 `NSPasteboardItem` 全类型快照（types + data(forType:)），恢复时 declareTypes 逐类型写回；TextCaptureStrategies 与 TextReplacementService 共用一个 `PasteboardSnapshot` 工具 struct |
| 2.C.5 | **H11 选区恢复** | 扩选前经 AX 记录原选区 range；扩选采样后恢复原 range；AX 不可用时**跳过扩选**（不破坏用户选区） |
| 2.C.6 | **H12 动画门控** | AnimationGate.refresh() 移至所有 registerDefaults 之后；animations_enabled 注册默认 true；GeneralTab 补「动画效果」开关写入该键（否则门控无意义） |
| 2.C.7 | **M8 窗口竞态** | hide 动画回调持 generation token，重显递增 token，回调校验后才 orderOut；SettingsWindowManager 延迟置 nil 前比对窗口实例同一性 |
| 2.C.8 | **M9 监控抑制** | suppressNext 改抑制计数器 `suppressCount`（替换流程置 2：写入+恢复）；copyResult 前置 1 |
| 2.C.9 | **M15 防抖串写** | 调度防抖时捕获 providerID 快照，执行时比对当前 ID，不一致则丢弃 |
| 2.C.10 | **M17 热键注册校验** | RegisterEventHotKey 返回非 noErr 时日志 + 设置页冲突提示；引导页权限行加定时 AXIsProcessTrusted/CGPreflightScreenCaptureAccess 状态刷新 |

验证：手动矩阵——关闭方式两档各测 3 次；录制 A 键重启后仍为 A；复制图片→⌥D→确认图片仍在剪贴板；扩选后 ⌥R 只替换原选区；动画开关生效；快速开关面板 10 次无泄漏/闪烁。

### 2.D 存储/并发组（M5 / M14 + L6 / L7）
| 步骤 | 修复 | 要点 |
|---|---|---|
| 2.D.1 | **M14 原子写** | HistoryActor.rewriteArchive 改 `data.write(to: url, options: .atomic)` |
| 2.D.2 | **M5 隔离域** | MemoryPurgeHelper 压力回调改 `Task { @MainActor in purgeBackendCache() }` |
| 2.D.3 | **L6 缓存失效** | ConfigurationStore init 注册 UserDefaults.didChangeNotification 观察者调 invalidateCache()（持 token，deinit 移除）；或删注释与死方法——二选一，建议实现观察者 |
| 2.D.4 | **L7 退出 flush** | applicationWillTerminate 改同步等待 flush（带 1s 上限的信号量）或接受现状并注释说明 JSONL 已即时追加——建议后者（最小改动） |

**阶段 2 验收**：每组独立 commit；`swift build` 0 warning；`swift test` 全绿 + 累计新增 ≥15 例；手动矩阵全过。

---

## 阶段 3（P2）：低危清理与仓库卫生

| 步骤 | 内容 |
|---|---|
| 3.1 | 死代码清除（L11 清单约 10 处）：captureWithOCR 整链、posRegex、attachExamples、clearOCRStatus、loadRecentHistory、entries()、stripHTML、extractXMLTag、connectTimeout、FrameTracker、updateWindowSize、ShakeEffect、DisplayGeometry:78-91、重复 import。每删一处 grep 确认零引用 |
| 3.2 | **R1 版本统一**：建议回归 semver `0.7.0`（承接 0.6.x 系列）；kAppVersion、build fallback、README 同步；打 tag `v0.7.0`（需用户确认版本号决策——6.5 与 0.7 的取舍由用户定） |
| 3.3 | **R3 删 ATS 例外**：Info.plist 生成模板移除 aliyuncs.com 三条 http 例外（已验证远端全 https）；真机回归阿里云翻译 |
| 3.4 | **R2 entitlements 验证**：真机测试移除 allow-unsigned-executable-memory 后 Translation/ANE 是否正常；按需保留 disable-library-validation；结论写入注释 |
| 3.5 | **R4 文档更新**：README（构建命令改 build.sh、结构树对齐现状、macOS 15+/Swift 6.4）；docs/architecture.md 重写组件清单；memories/repo/macos-compat-fixes.md 追加本次修复记录 |
| 3.6 | L4/L5/L8/L9/L10 小修：探测缓存按 provider 键控、拖拽限速接线或删除死参数、高度通知接线或删除、DateFormatter 复用、AboutTab 图标缓存、contentsScale 按所在屏、spring duration 生效、测试 barrier 修复 |
| 3.7 | R6：MCP 配置过期路径修正或移出版本控制；.freebuff 加 gitignore |

---

## 阶段 4（P3）：测试加固（填补零覆盖区）

| 步骤 | 内容 |
|---|---|
| 4.1 | 捕获层：SingleFrameStreamOutput 取消矩阵（阶段 1 已建）、ActiveStreamGate 并发 acquire/release、ContentCache TTL/拓扑失效 |
| 4.2 | 管线编排：OCRCapturePipeline 45s 硬上限、代际守卫与捕获取消联动（mock 注入） |
| 4.3 | 降级链：深度上限、CancellationError 短路、鉴权错误不降级（纯函数化后单测） |
| 4.4 | 窗口层：closeMethod 决策纯函数测试、hide/show generation 竞态 |
| 4.5 | 预热状态机：ensureCacheValid 不阻塞、markFailed 路径、进度一致性 |
| 4.6 | CI 建议：GitHub Actions 加 macos-15 runner 跑 swift build + swift test（当前 .github 无 workflow） |

---

## 提交与验证策略

- **提交粒度**：阶段 1 一个 commit（或 S1/S2/S3 各一）；阶段 2 按 A/B/C/D 四组各一；阶段 3/4 各一。全部提交需用户批准。
- **每阶段门禁**：`swift build`（0 error / 0 warning）→ `swift test` 全绿 → 该阶段手动冒烟清单 → 才进入下一阶段。
- **最终验收**：Release 构建 + 打包（build.sh）+ 完整手动矩阵（⌥D/⌥F/⌥R × TextEdit/Notes/Safari × 单屏/外接屏）+ 剪贴板保真 + 断网降级 + 闲置 5 分钟 OCR。
- **回滚**：每组独立 commit，任一组出问题可单独 revert；阶段 0 基线快照兜底。

## 风险与开放决策

| 项 | 说明 | 需用户决策 |
|---|---|---|
| 版本号 | 6.5 vs 0.7 取舍 | ✅ 阶段 3.2 前确认 |
| 未提交改动拆分 | 是否按阶段 0.2 拆分提交 | ✅ 开工前确认 |
| H11 选区恢复 | 依赖目标应用 AX 支持，不可用时降级为跳过扩选（上下文感知略减弱） | 知悉即可 |
| entitlements | 移除弱化权限需真机验证 ANE/Translation，可能需保留 | 验证后定 |
| S1 宽限期 | 0.5s 为经验值，极慢应用可调整常量 | 知悉即可 |