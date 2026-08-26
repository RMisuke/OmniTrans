# OCR 重构基准报告（2026-08）

## 重构概述

| 维度 | 旧架构 | 新架构 |
|---|---|---|
| 识别 API | `VNRecognizeTextRequest` + 同步 `perform()`（DispatchQueue + Continuation 桥接） | macOS 15 Swift 并发 API `RecognizeTextRequest`（原生 async/await + 原生任务取消） |
| 语言策略 | 串行四级降级链：accurate+en → accurate+5语言 → fast+en → fast+all，单级超时 25s，最坏 60s+ | 双轨并行竞速（en vs zh-Hans+en），高质量首达即采纳并**原生取消**落败方；两轨完成后按质量分仲裁兜底 |
| 预处理 | 固定长边 ≤2000px；纵向最近邻 + **横向截断**（潜在精度缺陷） | 面积预算 ≤4M px 等比 vImage 双线性缩放（`ImagePreprocessor`） |
| 硬件探测 | 启动三步探针（ANE/CPU/fast）+ 会话自适应降级 | 已删除 —— 新 API 自动调度 ANE/GPU/CPU |
| 架构分层 | UI + 捕获 + 识别耦合在 `OCRSelectionOverlay`（900 行） | `Sources/OmniTrans/OCR/` 四层模块：Capture / Preprocess / Recognition / Assembly + Pipeline 门面 |

## 基准结果

环境：macOS 27.0 (26A5416b) · Apple Silicon arm64 · Debug 构建（`swift test`）。
测试图：运行时 CoreGraphics 合成渲染（白底黑字、系统字体），真实 Vision 推理。

| 场景 | 字符准确率 | 端到端耗时 |
|---|---|---|
| 纯英文段落（1600×400 @32pt） | **1.0000** | 203 ms |
| 中文段落（1600×400 @34pt） | **1.0000** | 310 ms |
| 中英混排行（1400×200 @30pt） | **1.0000** | 77 ms |
| 小区域单行「确定 Cancel」（480×120） | **1.0000** | 226 ms |

### 与旧架构对比

旧实现的实测问题（来自 `docs/audit-2026-08.md` 与 git 历史）：
- 3000+ px 大区域 `.accurate` 需 20–60s（像素数近似二次方），且常触发超时降级到 `.fast`（英文乱码根因）
- 中英混排场景必然先跑完 en 尝试（最长 25s 超时）才开始多语言尝试 —— **串行双倍等待**
- 语言盲猜失败时用户感知延迟秒级起步

新实现：
- 合成基准下端到端 **80–310ms**（含捕获外的全部管线阶段）
- 准确率四场景满分 —— 重构未降低准确率
- 最坏情况有界：整体兜底超时 20s 且落败轨道被原生取消（不再有线程空转）

> 注：合成图面积均在预算内，代表典型框选场景。超大区域（>4M px）会先经
> 双线性降采样再推理，耗时由面积预算上界保证。

## 复现方式

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcrun swift test --build-system native --filter OCRBenchmarkTests
# 输出行格式：BENCH|<scenario>|accuracy=<x>|latency_ms=<ms>
```

## 已知设计权衡

1. **早期采纳阈值 0.72**：首达轨道平均置信度 ≥0.72 才提前返回。中文内容上
   mixed 轨单行置信度可能只有 ~0.5（实测），此时等待双轨完成并按质量分
   （Σ 置信度×字符数）仲裁 —— 正确性优先于极端低延迟。
2. **en 轨在纯中文内容上返回空数组**（Vision 行为）：仲裁器已针对此修正，
   空结果不再阻塞更好的后续结果（重构过程中发现并修复的真实缺陷）。
3. **小区域（<150K px）只跑 mixed 单轨**：单行 UI 文字大概率中英混排，
   竞速收益低于并发开销。
4. **自适应单轨**：连续 3 次 en 胜出后直接单跑英文轨（纯英文工作区），
   任何一次 mixed 胜出立即回退竞速。
