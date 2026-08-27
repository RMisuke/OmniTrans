import Foundation
import CoreVideo
import os

// MARK: - 竞速仲裁记忆（自适应降并发）

/// 会话级竞速统计 —— 连续多次英文轨获胜时切换为英文单轨模式；
/// 任何一次 mixed 轨胜出立即回到竞速模式。
///
/// 典型纯英文工作区（代码编辑器/终端）可彻底消除竞速的并发开销；
/// 中文内容天然让 mixed 胜出，不会误入单轨。
actor RacePolicyMemory {
    /// 连续 en 胜出次数达到该值 → 切换单轨。
    private static let soloThreshold = 3

    private var consecutiveEnglishWins = 0

    /// 是否跳过竞速直接单跑英文轨。
    var shouldRunEnglishSolo: Bool {
        consecutiveEnglishWins >= Self.soloThreshold
    }

    func record(winner: LanguageTrack) {
        switch winner {
        case .english: consecutiveEnglishWins += 1
        case .mixed:   consecutiveEnglishWins = 0
        }
    }

    /// 无结果（两轨皆空）不影响统计；显式重置入口供测试使用。
    func reset() {
        consecutiveEnglishWins = 0
    }
}

// MARK: - 竞速语言策略

/// 并行竞速识别编排：英文轨道与中英混合轨道同时启动，先产出高质量结果者胜出。
///
/// ## 为什么能提速且不掉准确率
/// - 英文内容：en-only 模型最轻，通常先完成 → 提前返回，节省等待混排模型的尾延迟。
/// - 中英内容：en-only 会返回低置信度乱码 → 仲裁器拒绝采纳，等 mixed 结果，
///   最终准确率与串行「先 en 后 mixed」一致，且无串行等待的额外开销。
/// - 落败轨道经新 Vision API 原生取消，ANE 推理立即终止，不浪费算力也不拖内存。
///
/// ## 启发式降并发
/// - 小区域（像素面积低于阈值）大概率是单行 UI 文字（常为中英混排），只跑 mixed 单轨。
/// - 自适应记忆：连续多次英文轨获胜时，后续直接单跑英文轨（典型纯英文工作区）。
///
/// ## 韧性（E5RT 冷启动故障复现后的加固）
/// - **失败重试**：ANE 管线未就绪时 Vision 抛瞬态错误（E5RT Code 13），
///   单次失败立即重试一次即可恢复，用户无感。
/// - **真实超时**：每次推理经 `withInferenceDeadline` 包裹 —— 到点即返回，
///   挂起的 Vision 调用弃管。修复旧实现「solo 路径无超时、竞速路径的
///   withTaskGroup 兜底被不响应取消的挂起调用卡死」的缺陷。
/// - **超时不重试**：超时意味着管线大概率已卡死，重试只会延长卡死时间；
///   仅对快速落错的瞬态错误（如 E5RT Code 13）自动重试。
/// - **并发闸门 + 熔断**：所有推理经 `OCRInferenceGate` 串行化排队，
///   连续超时触发 `OCRInferenceBreaker` 冷却期，防止连续识别时弃管任务
///   无限堆积、反复撞击卡死的 ANE 管线。
struct RacingLanguageStrategy: Sendable {

    nonisolated private static let log = OSLog(subsystem: AppLogging.subsystem, category: "OCRRace")

    private let recognizer: any TextRecognizing
    private let policyMemory: RacePolicyMemory

    /// 单次推理的真实超时（弃管语义，见 `withInferenceDeadline`）。
    /// 覆盖 E5RT 冷启动停滞（真机实测 ~40s）——到点即向调用方返回。
    /// 20s → 12s：配合「超时后不再重试」策略，把最坏无反馈等待从 ~41s 压到 ~12s。
    private let inferenceDeadline: Duration
    /// 推理失败后的重试退避间隔。
    private let retryBackoff: Duration
    /// 单条轨道的最大尝试次数（1 = 不重试）。
    private let maxAttempts: Int

    /// 小区域面积阈值：低于此值只跑 mixed 单轨（约 480×300 像素）。
    private static let smallAreaPixels = 150_000
    /// 早期采纳阈值：首条完成的轨道平均置信度 ≥ 此值即接受并取消另一轨。
    /// 纯中文内容上 en 轨乱码的置信度显著低于该阈值。
    private static let earlyAcceptConfidence: Float = 0.72

    init(recognizer: any TextRecognizing,
         policyMemory: RacePolicyMemory = RacePolicyMemory(),
         inferenceDeadline: Duration = .seconds(12),
         retryBackoff: Duration = .seconds(1),
         maxAttempts: Int = 2) {
        self.recognizer = recognizer
        self.policyMemory = policyMemory
        self.inferenceDeadline = inferenceDeadline
        self.retryBackoff = retryBackoff
        self.maxAttempts = maxAttempts
    }

    /// 竞速识别主入口。返回 nil 表示两条轨道均无有效文字。
    mutating func recognizeBest(_ buffer: CVPixelBuffer) async -> [RecognizedLine]? {
        // ── 启发式 1：小区域单轨 ──
        let pixels = CVPixelBufferGetWidth(buffer) * CVPixelBufferGetHeight(buffer)
        if pixels < Self.smallAreaPixels {
            return await runSolo(.mixed, buffer: buffer)
        }

        // ── 启发式 2：自适应单轨 ──
        if await policyMemory.shouldRunEnglishSolo {
            return await runSolo(.english, buffer: buffer)
        }

        return await race(buffer: buffer)
    }

    // MARK: - 闸门 + 超时 + 重试的单次识别

    /// 执行一次识别：并发闸门 + 真实超时包裹 + 瞬态失败自动重试（E5RT 冷启动故障加固）。
    private func recognizeResilient(_ track: LanguageTrack,
                                    _ buffer: CVPixelBuffer) async -> Result<[RecognizedLine], Error> {
        // 熔断器冷却期内直接快速失败 —— 让 UI 立即提示「引擎繁忙」，
        // 而不是每次都撞满整个超时时长。
        guard await OCRInferenceBreaker.shared.allowAttempt() else {
            return .failure(InferenceGateError.busy)
        }

        // 只读共享盒：消除 sending 闭包对非 Sendable CVPixelBuffer 的捕获告警。
        let box = PixelBufferBox(buffer)
        let recognizer = self.recognizer
        let deadline = inferenceDeadline

        for attempt in 1...max(1, maxAttempts) {
            // 并发闸门：排队超过时限（或任务被取消）→ 快速失败。
            // 防止弃管任务无限堆积占满协作线程池（连续识别卡死的根因之一）。
            do {
                try await OCRInferenceGate.shared.acquire()
            } catch {
                OCRMetrics.recordInferenceFailure(track: track, attempt: attempt, error: error)
                return .failure(error)
            }
            let result = await withInferenceDeadline(deadline) {
                try await recognizer.recognize(box.value, track: track)
            }
            // 到点即释放许可（不等底层操作自然落错）—— 停滞调用可挂 ~40s，
            // 等它会让一次停滞锁死闸门；残留争抢由熔断器冷却期兜底。
            OCRInferenceGate.shared.release()

            switch result {
            case .success:
                await OCRInferenceBreaker.shared.recordSuccess()
                return result
            case .failure(let error):
                OCRMetrics.recordInferenceFailure(track: track, attempt: attempt, error: error)
                if error is InferenceDeadlineError {
                    await OCRInferenceBreaker.shared.recordTimeout()
                    // 超时弃管后不重试 —— 管线大概率已卡死，再跑一轮只是把卡死时间翻倍。
                    return result
                }
                guard attempt < maxAttempts, !Task.isCancelled else { return result }
                OCRMetrics.recordInferenceRetry(track: track, attempt: attempt)
                try? await Task.sleep(for: retryBackoff)
            }
        }
        // 循环必经 return；防御性兜底
        return .failure(InferenceDeadlineError.exceeded)
    }

    // MARK: - 单轨执行

    private mutating func runSolo(_ track: LanguageTrack, buffer: CVPixelBuffer) async -> [RecognizedLine]? {
        let state = OCRMetrics.begin(.inference)
        defer { OCRMetrics.end(.inference, state) }
        switch await recognizeResilient(track, buffer) {
        case .success(let lines):
            await policyMemory.record(winner: track)
            return lines.isEmpty ? nil : lines
        case .failure(let error):
            if !(error is InferenceDeadlineError) {
                os_log(.error, log: Self.log, "solo %@ failed: %@", track.rawValue, String(describing: error))
            }
            return nil
        }
    }

    // MARK: - 双轨竞速

    private struct TrackResult {
        let track: LanguageTrack
        let result: Result<[RecognizedLine], Error>
    }

    private mutating func race(buffer: CVPixelBuffer) async -> [RecognizedLine]? {
        let memory = policyMemory
        // mutating 方法内不可直接捕获 self —— 复制不可变副本供子任务捕获。
        let runner = self
        let deadline = inferenceDeadline
        // 双轨道**只读**共享同一像素缓冲：Vision 对输入缓冲区仅做只读锁定，
        // 并发安全；经 Sendable 盒显式声明该不变量（消除 sending 闭包告警）。
        let sharedBuffer = PixelBufferBox(buffer)

        let winner: TrackResult? = await withTaskGroup(of: TrackResult.self) { group in
            group.addTask(priority: .userInitiated) {
                TrackResult(track: .english,
                            result: await runner.recognizeResilient(.english, sharedBuffer.value))
            }
            group.addTask(priority: .userInitiated) {
                TrackResult(track: .mixed,
                            result: await runner.recognizeResilient(.mixed, sharedBuffer.value))
            }
            // 整体兜底超时：到点后取消组内全部任务。
            // （每条轨道自身已有 `withInferenceDeadline` 弃管式真实超时，
            //  保证子任务必然落定，此处兜底才能真实生效。）
            group.addTask(priority: .utility) {
                try? await Task.sleep(for: deadline)
                return TrackResult(track: .english, result: .failure(CancellationError()))
            }

            var successes: [TrackResult] = []
            for await item in group {
                switch item.result {
                case .success(let lines):
                    // 高质量首达 → 立即采纳，取消其余轨道（原生终止推理）。
                    // 注意：中文内容上 en 轨往往返回**空数组**、mixed 轨单行
                    // 置信度偏低（实测 ~0.5），都不能阻塞后续更好的结果。
                    if !lines.isEmpty,
                       Self.meanConfidence(lines) >= Self.earlyAcceptConfidence {
                        group.cancelAll()
                        return item
                    }
                    if !lines.isEmpty { successes.append(item) }
                case .failure(let err):
                    if err is CancellationError {
                        // 兜底超时触发：放弃等待，返回已有最佳结果
                        group.cancelAll()
                        return successes.first
                    }
                    // 单轨失败不致命 —— 继续等另一轨
                }
            }
            // 两轨都完成但均未达早期采纳阈值 → 取质量分更高者。
            return successes.max { a, b in
                guard case .success(let la) = a.result,
                      case .success(let lb) = b.result else { return false }
                return OCRResultAssembler.qualityScore(la) < OCRResultAssembler.qualityScore(lb)
            }
        }

        guard let winner, case .success(let lines) = winner.result, !lines.isEmpty else {
            return nil
        }
        await memory.record(winner: winner.track)
        return lines
    }

    /// 平均置信度（空数组返回 0）—— 竞速仲裁的质量度量。
    nonisolated static func meanConfidence(_ lines: [RecognizedLine]) -> Float {
        guard !lines.isEmpty else { return 0 }
        return lines.reduce(0) { $0 + $1.confidence } / Float(lines.count)
    }
}
