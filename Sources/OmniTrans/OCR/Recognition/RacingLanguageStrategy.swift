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
struct RacingLanguageStrategy: Sendable {

    nonisolated private static let log = OSLog(subsystem: AppLogging.subsystem, category: "OCRRace")

    private let recognizer: any TextRecognizing
    private let policyMemory: RacePolicyMemory

    /// 小区域面积阈值：低于此值只跑 mixed 单轨（约 480×300 像素）。
    private static let smallAreaPixels = 150_000
    /// 早期采纳阈值：首条完成的轨道平均置信度 ≥ 此值即接受并取消另一轨。
    /// 纯中文内容上 en 轨乱码的置信度显著低于该阈值。
    private static let earlyAcceptConfidence: Float = 0.72
    /// 整体兜底超时：极端情况下（推理挂起）仍保证调用方在时限内得到响应。
    private static let overallTimeout: Duration = .seconds(20)

    init(recognizer: any TextRecognizing, policyMemory: RacePolicyMemory = RacePolicyMemory()) {
        self.recognizer = recognizer
        self.policyMemory = policyMemory
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

    // MARK: - 单轨执行

    private mutating func runSolo(_ track: LanguageTrack, buffer: CVPixelBuffer) async -> [RecognizedLine]? {
        let state = OCRMetrics.begin(.inference)
        defer { OCRMetrics.end(.inference, state) }
        do {
            let lines = try await recognizer.recognize(buffer, track: track)
            await policyMemory.record(winner: track)
            return lines.isEmpty ? nil : lines
        } catch is CancellationError {
            return nil
        } catch {
            os_log(.error, log: Self.log, "solo %@ failed: %@", track.rawValue, error.localizedDescription)
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
        let recognizer = self.recognizer
        // 双轨道**只读**共享同一像素缓冲：Vision 对输入缓冲区仅做只读锁定，
        // 并发安全；经 Sendable 盒显式声明该不变量（消除 sending 闭包告警）。
        let sharedBuffer = PixelBufferBox(buffer)

        let winner: TrackResult? = await withTaskGroup(of: TrackResult.self) { group in
            group.addTask(priority: .userInitiated) {
                TrackResult(track: .english,
                            result: await Self.runTrack(recognizer, .english, sharedBuffer.value))
            }
            group.addTask(priority: .userInitiated) {
                TrackResult(track: .mixed,
                            result: await Self.runTrack(recognizer, .mixed, sharedBuffer.value))
            }
            // 整体兜底超时：到点后取消组内全部任务（新 Vision API 原生响应取消）。
            group.addTask(priority: .utility) {
                try? await Task.sleep(for: Self.overallTimeout)
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

    private static func runTrack(_ recognizer: any TextRecognizing,
                                 _ track: LanguageTrack,
                                 _ buffer: CVPixelBuffer) async -> Result<[RecognizedLine], Error> {
        let state = OCRMetrics.begin(.inference)
        defer { OCRMetrics.end(.inference, state) }
        do {
            return .success(try await recognizer.recognize(buffer, track: track))
        } catch {
            return .failure(error)
        }
    }

    /// 平均置信度（空数组返回 0）—— 竞速仲裁的质量度量。
    nonisolated static func meanConfidence(_ lines: [RecognizedLine]) -> Float {
        guard !lines.isEmpty else { return 0 }
        return lines.reduce(0) { $0 + $1.confidence } / Float(lines.count)
    }
}
