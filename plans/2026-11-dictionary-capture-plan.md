# 词典重构 / API 验证 / 取词修复 / 速度标签 — 分析与计划（2026-11-20）

> 状态：**P0 + P1 已执行**（P0：66684d1/a78529f/b85a710；P1-A：dbf6dc7；P1-B 随后），
> 86 例测试 0 失败，Debug 0 警告。P2（token 速度标签等）待批准。
> 偏差说明：P1-A 词典请求仍走流式传输但**停止增量解析**（收全流后单次解析 +
> 校验）——获得非流式的全部收益（无 O(n²)、无硬锁定、单次校验）且避免复制三套
> provider 非流式请求代码；P1-B 的 Ollama 心跳并入降级链延后（降级链已覆盖
> 启用的 Ollama provider，独立心跳的边际收益低）。
> 关联：docs/audit-2026-11.md（上一轮审计）、plans/fix-plan-2026-11.md（已执行完毕）

---

## 0. 问题域与优先级总览

| 域 | 用户报告 | 调查结论 | 优先级 |
|---|---|---|---|
| 词典回退 | AI 失效不回落原生词典 | **5 个确认 bug**，主因是「HTTP 200 但 JSON 解析失败」走成功路径，根本不进 catch | P0 |
| 词/句判断 | 判断不精准 | WordDetector 不检查空格、中文整句判词、大小写缓存污染 | P0 |
| 词典设计 | 需要重构 | 9 项设计缺陷（状态漂移/O(n²)解析/schema 错位/坏数据永不自愈等） | P1 |
| API 验证 | 架构需重设计 | 4 套并行机制、3 套判定标准、状态灯自动烧配额、FallbackRouter 核心是死代码 | P1 |
| Typora 取词 | 单词偶发失败 | 90ms 轮询窗口 + Electron 异步选区 + AX 兜底未激活（放大器） | P0 |
| 速度标签 | AI 输出下显示 tok/s | 新功能，测量点/估算/UI 已设计 | P2 |

---

## 1. 词典域

### 1.1 回退失效 — 根因（均已复核）

**R1【主因】解析失败走成功路径**（AppState.swift:464-477）
AI 流 HTTP 200 但词典 JSON 解析失败 → `parser.flush()` 返回 nil → `dictionaryEntry = nil` → 置 `isTranslating=false` + 成功脉冲。**不进 catch、无任何回退**，面板空白。
触发极常见：仅 `.openAICompat` 开 `json_object` response_format（TranslationActor.swift:382-384），其余 provider 全靠 prompt 约束；maxTokens 默认 1024 截断 JSON 即触发。
→ 修复：flush nil/空结果视同失败，接入 native 回退（与 catch 共用一个 `fallbackToNativeDictionary(text:)`）；支持 json_object 的 provider 全部启用；词典 maxTokens 提升（1024→2048）。

**R2 未收录被当成功 + 永久缓存**（AppState.swift:497-498、MacOSNativeProvider.swift:32-37）
catch 回退里 `if entry.isWord` 才写入；DCS 未收录返回 isWord=false → 保留 AI 残缺结果却报成功；missing 结果被 NSCache 永久缓存，本会话永不重查。
→ 修复：显式「未收录」状态（UI 提示 + 建议切换引擎）；missing 不缓存或短 TTL（60s）。

**R3 native 作词典源时卡死**（MacOSNativeEngineAdapter.swift:29-31、AppState.swift:491/509/525）
native 未收录即 throw → catch 回退条件排除 native；`fallback_on_failure` **全仓库仅一处读取、无任何写入/默认值/UI 开关 → 恒 false**；:525 又排除 native → catch 空转，isTranslating 永真，转圈卡死。即使开关为 true，递归后 :302 仍按 dictProviderID 选回 native → 死循环到深度上限，沿途改写 selectedProviderID。
→ 修复：native 词典源未收录返回结构化空结果（不 throw）；**删除 fallback_on_failure 开关，回退改为默认行为**（词典→native 无条件；翻译 provider 链默认启用，深度上限已有 H1 保护）；降级递归不沿 dictProviderID 重选。

**R4 dictProviderID 失效路径错误**（AppState.swift:302-309、translate():259）
dictProviderID 指向已禁用/删除 provider → 回落 selectedProvider；若其为传统 MT → isDict=false 永不进词典。translate() 要求 selectedProvider 有效，纯 native 查词也被挡。
→ 修复：词典源失效回落「默认 AI provider」而非 selectedProvider；native 查词不依赖 selectedProvider 有效性。

**R5 成功路径无取消检查**（AppState.swift:421 起）
H1 短路只护 catch；旧任务在 await flush/lookupWord 挂起期间被取消，恢复后仍覆盖新请求状态。
→ 修复：成功路径关键写状态前查 `Task.isCancelled`。

**需真机验证的假设**：Dictionary.app 未勾选词典 → DCS 恒 nil（叠加 R2 表现为回退无效）；waitsForConnectivity=true 使断网错误延迟最长 60s 才到 catch。

### 1.2 词/句判断 — 缺陷与新规则

现行规则（DictionaryEntry.swift:121-131）：非空、≤50 字符、无换行、含字母、删 `-`/`.` 后非空。

| 输入 | 现判定 | 应为 | 缺陷 |
|---|---|---|---|
| `how are you` | 词 | 句 | 不检查空格 |
| `今天天气不错` | 词 | 句 | 中文 ≤50 字全判词 |
| `用AI翻译` | 词 | 句 | 中英混合无规则 |
| `wait—what?` | 词 | 句 | 内部标点不检查 |
| `iPhone 15 Pro` | 词 | 句 | 空格+数字 |
| `US` vs `us` | 缓存互染 | 区分 | 键 lowercased 但语义不同 |

**新规则提案**（配单元测试矩阵）：
1. trim 后含内部空格 → 句（`state-of-the-art` 无空格不受影响）
2. 纯 CJK：≤4 字 → 词（词语/成语），>4 → 句；阈值可配置
3. 拉丁：≤30 字符、仅允许字母/数字/`-`/`.`/`'`，首尾标点（.,!?;:引号）剥离后判断；内部 `—`/`/`/`,` → 句
4. 数字占比 >50% → 非词
5. 缓存键保留原始大小写（US≠us），展示层归一
6. 混合脚本（CJK+拉丁）→ 句（查词场景罕见）

### 1.3 词典重构 — 设计问题与目标架构

| # | 问题 | 位置 | 重构方向 |
|---|---|---|---|
| D1 | isDictionaryMode 语义漂移（成功重置/回退不重置/缓存命中瞬切） | AppState:332/350/485/506 | 显式状态机 `DictionaryQueryState`：idle/loading/success(entry)/notFound/error；displayMode 由其派生 |
| D2 | native 词条查两次、流内容为无用 summary | MacOSNativeEngineAdapter:23、AppState:423 | 引擎直接返回结构化 entry，不走流 |
| D3 | 每 chunk 全 buffer 正则重解析 O(n²)，固定字段顺序、不支持转义引号 | DictionaryEntry:152-159/190 | **决策点**：A 增量 JSON 解析器（复杂）/ B 词典改非流式一次性 JSON（简单可靠，查词无需逐字）。**推荐 B** |
| D4 | prompt 输出 `is_word`、解码 `isWord`，字段永错位（?? true 掩盖） | TranslationActor:775、DictionaryEntry:108 | 统一 CodingKeys + prompt/解码契约测试 |
| D5 | write-once 不校验即持久化，坏 JSON 因 INSERT OR IGNORE 永不自愈 | AppState:454-462、LocalDictionaryRepository:125 | 落库前 parse 校验；坏行标记可覆写 |
| D6 | lastValidDictionaryJson 只写不读（消费者已删）、detectedIsWord 无读写 | Stores:34/24 | 删除死状态 |
| D7 | native 历史存纯文本，recallHistoryEntry JSON 解码必失败 | AppState:484/620-622 | 历史统一存 entry JSON |
| D8 | 复制/朗读词典只取 entry.word；displayMode 多布尔推断 | FloatingPanelContent:1047/1063/112-119 | 复制/朗读完整词条；状态机派生 |
| D9 | AI/native 双源互斥无合并（phonetic/inflections 仅 native 有，AI 覆盖后丢失） | 全局 | 字段级合并策略：native 供音标/变形，AI 供释义/例句 |

---

## 2. API 验证架构重设计

### 2.1 现状：4 套并行机制（互不共享）
1. 设置页测试按钮 → APITestService.testConnection，结果 5s 清空
2. 状态灯探测 → 同一 testConnection，面板出现/切供应商/翻译结束触发，仅视图内 lastProbeTime 节流 30s（@State 重建即重置）
3. FallbackRouter HEAD 探测 → **resolveWithFallback/probeLocalOllama 全仓库无调用方，死代码**；AppState:296 注释宣称"失败时才探测"与实际不符
4. MT 签名测试 → GET 签名 URL ==200，超时 20s 而非 probeTimeout

### 2.2 问题清单
- 判定三套标准：HEAD <500（401 算活）vs 2xx vs ==200
- **状态灯每 30s 自动触发计费探测**：Anthropic 真实 POST max_tokens=10、GoogleMT/阿里/火山真实翻译 → 烧配额
- **火山测试必错**：testConnectivity 用非法 JSON `[hello]`（TranslationActor_MT:275）——H2 只修了 signedQuery 漏了测试分支；端点硬编码忽略 provider.baseURL
- 错误分类靠 localizedDescription 字符串匹配（401/403/unauthorized），429 配额/模型不存在/断网混为一谈
- 探测竞态：Task 捕获旧 provider 无代号校验，旧结果污染新供应商红灯
- waitsForConnectivity=true → 断网探测挂 60s 黄灯长闪
- 灯语义混乱：绿灯含"从未探测/被节流"，红灯混淆翻译错误与连通性

### 2.3 目标架构：统一 ProbeService（actor）三层
1. **策略层** ProviderProbeStrategy：按 kind 分免费验证（OpenAI/Gemini GET /models、Bing /languages）与计费验证（Anthropic/GoogleMT/阿里/火山）；**计费探测仅设置页手动触发或首次配置跑一次，状态灯永不触发**；火山测试复用修好的 signedQuery
2. **分类层** ProbeError 枚举：network/auth/quota/model/server；AppState 降级与 RetryUtility.isRetryable 统一消费，替代字符串匹配
3. **缓存层**：(providerID+配置指纹) 键控；apiKey/baseURL/model 变更即失效；in-flight 去重（同 key 共享 Task）+ 代号校验防旧结果覆盖

**状态灯语义**：绿=最近验证通过；黄=验证中；红=仅 auth/network 失败；翻译错误（配额/模型）单独提示不占连通灯；未验证=灰。

**迁移路径**：① ProbeError + 统一 2xx → ② APITestService 迁入 ProbeService 加缓存/去重 → ③ 灯与设置页消费同一探测状态 → ④ FallbackRouter 死代码删除，Ollama 心跳（GET /models==200）并入降级链末端。

---

## 3. Typora 单词取词偶发失败

### 3.1 根因链（解释了"单词特异 + 偶发"）
1. **【主因】90ms 轮询窗口不足**（TextCaptureStrategies:41-46，30×3ms）：Typora/Electron 双击选词在 renderer 异步建立选区，Cmd+C 到达时选区未就绪 → 不写剪贴板；句子拖选松手即稳定。defer 恢复还会覆盖迟到写入。
2. **【放大器】AX 兜底未激活**：Chromium 系需设 `AXManualAccessibility=true` 才暴露完整 AX 树，代码从未设置 → Typora 的 AXSelectedText 读不到，主路径一失败即整体失败。
3. **【中】快照竞态窗口**：H10 全保真快照读取插在 initialCount 快照与 Cmd+C 之间（大剪贴板几十 ms），第三方写入被误认为复制结果 → 取到旧文本。
4. **【中】监控干扰**：取词路径从不 suppress；Cmd+C 写入 + H10 恢复（两次写入）触发 ClipboardMonitor 自动翻译，与 fire 交错。
5. **【低】连锁失败**：0.8s debounce 吞重试；失败即弹历史窗抢焦点 → 下次 Cmd+C 投给 OmniTrans。
6. 已排除：H11 仅在上下文路径，不碰主取词。

### 3.2 修复方案
1. 轮询改自适应 deadline：**上限 300ms，检测到 changeCount 变化即止**（正常路径均摊延迟不变，最坏 +210ms）
2. initialCount 快照移到 Cmd+C 投递前一刻（快照读取之后），收窄竞态窗口
3. 超时但 count 已变 → 恢复前先读一次（迟到写入不丢）
4. 前台应用为 Electron 系（bundle 检测或 AX 探测失败时）设置 AXManualAccessibility=true，激活 AX 兜底
5. 取词写入/恢复成对设置 suppressCount（+3：写入、clear、write）
6. 取词失败不弹历史窗，改状态栏气泡（保焦点）
7. 诊断埋点（DEBUG）：轮询 count/耗时、nil 原因、defer 恢复时 count 差值（>1 即迟到写入实锤）、AX err 码、debounce 拒绝

---

## 4. Token 速度标签（新功能）

### 4.1 测量与估算
- **测量点**：AppState 流消费循环（:399 for-await batch）——不改引擎协议，所有 AI provider 统一生效
- **估算**：CJK 字符 ×1.0 + 其他字符 ÷4.0（BPE 近似），标签前缀 `≈`；后续可接 OpenAI stream_options usage 用真实 completion_tokens 校准
- **算法**：滑动窗口（2s）+ EMA；首 batch 记 TTFT；结束冻结为 总估算 token ÷ (末 batch − 首 batch)
- **更新频率**：≤2Hz 写 session，避免高频重绘

### 4.2 状态与 UI
- TranslationSessionStore 新增 `tokenRate: Double?`（nil=隐藏）+ 可选 `ttft: TimeInterval?`
- translationResultView（FloatingPanelContent:811）ScrollView 下方加灰色小标签：`Text("≈ 200 tok/s").font(.system(size: 10)).foregroundColor(.secondary)`，可附 `首字 0.4s`
- 显示条件：AI 流式/完成；**缓存命中/native/MT/词典模式隐藏**（无 token 生成）
- 新请求重置 nil；流式中实时刷新，完成冻结均值

---

## 5. 执行分期（待批准后动手）

### P0 快速修复（0.5–1 天）
- 词典：R1 flush-nil 接回退 + json_object 全启用 + maxTokens 提升；R2 未收录显式态 + missing 短 TTL；R3 native 空结果不 throw + 删 fallback_on_failure 开关改默认回退；R4 词典源失效回落；R5 成功路径取消检查
- WordDetector 新规则 + 单元测试矩阵（含 US/us 缓存键）
- Typora：自适应轮询 + 快照时序 + AXManualAccessibility + suppress + 失败保焦点
- 火山 testConnectivity JSON 修复（H2 遗漏）
- 验证：断网/坏 key/截断 JSON 三场景词典回退真机冒烟；Typora 双击选词 ×20 次成功率

### P1 重构（2–3 天）
- 词典状态机 + 非流式 JSON（决策点 D3）+ schema 统一 + 持久化校验自愈 + 历史统一序列化
- ProbeService 三层 + 状态灯新语义 + FallbackRouter 死代码清理 + Ollama 心跳接线
- 验证：探测不烧配额（计费 provider 状态灯只走免费/缓存）；坏 JSON 落库自愈测试

### P2 增强（1 天）
- token 速度标签（测量+UI+状态）
- 双源字段合并（D9）、复制/朗读完整词条（D8）、死状态清理（D6）
- 验证：速度标签数值与 provider 控制台 usage 对比误差 <30%

## 6. 需用户决策
1. **词典流式 vs 一次性**：推荐一次性 JSON（查词无需逐字，消除 O(n²) 解析与 hard-lock hack）；保留流式则需增量解析器（+1 天）
2. **fallback_on_failure**：推荐删除开关、回退默认启用（现状恒 false 等于功能不存在）
3. **计费探测策略**：推荐状态灯只用免费探测，计费验证仅手动
4. **token 标签精度**：推荐先估算（≈前缀），usage 校准后续
5. **Typora 轮询上限**：300ms（最坏延迟 +210ms 换成功率），可调

## 7. 风险
- 词典改非流式：UI 从逐字变为一次性出结果，需 loading 态过渡（状态机已含）
- AXManualAccessibility：对非 Electron 应用无副作用，但需真机验证 Typora/Cursor/VSCode 各版本
- 删 fallback 开关：行为变化（默认开始降级），需在 release note 说明
- ProbeService 迁移：状态灯语义变化（灰=未验证），用户可感知