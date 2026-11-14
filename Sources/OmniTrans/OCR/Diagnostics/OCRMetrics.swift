import Foundation
import os

// MARK: - OCR 性能指标埋点

/// 用 `OSSignposter` 对捕获 / 预处理 / 推理三个阶段打点，
/// 供 Instruments（os_signpost）与统一日志分析端到端耗时。
///
/// 取消语义验证也依赖此埋点：被取消的竞速落败方会在
/// `endInference` 处留下 `cancelled=true` 标记，证明推理真正终止、
/// 后台无线程空转。
enum OCRMetrics {
    private static let signposter = OSSignposter(subsystem: AppLogging.subsystem, category: "OCRMetrics")

    /// 阶段名。
    enum Phase: String, Sendable {
        case capture = "Capture"
        case preprocess = "Preprocess"
        case inference = "Inference"
    }

    /// 开始一个阶段，返回可传递的 signpost state。
    /// （`beginInterval` 要求 StaticString 名称，故按阶段显式分发。）
    static func begin(_ phase: Phase) -> OSSignpostIntervalState {
        switch phase {
        case .capture:    return signposter.beginInterval("OCR.Capture")
        case .preprocess: return signposter.beginInterval("OCR.Preprocess")
        case .inference:  return signposter.beginInterval("OCR.Inference")
        }
    }

    /// 结束一个阶段。
    static func end(_ phase: Phase, _ state: consuming OSSignpostIntervalState) {
        switch phase {
        case .capture:    signposter.endInterval("OCR.Capture", state)
        case .preprocess: signposter.endInterval("OCR.Preprocess", state)
        case .inference:  signposter.endInterval("OCR.Inference", state)
        }
    }

    /// 记录一次完整 OCR 的耗时摘要（统一日志，便于 grep 统计 P50/P95）。
    static func logSummary(total: Duration,
                           inference: Duration?,
                           track: LanguageTrack?,
                           cancelledOtherTrack: Bool,
                           textLength: Int) {
        // components.attoseconds 仅是亚秒余数 —— 必须加上整秒部分，
        // 否则 >1s 的耗时全部记错（2.5s → 500ms）（审计 M10）。
        let ms = Double(total.components.seconds) * 1000 + Double(total.components.attoseconds) / 1e15
        let infMs = inference.map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 }
        os_log(.info, log: OSLog(subsystem: AppLogging.subsystem, category: "OCRMetrics"),
               "OCR summary: total=%.1fms inference=%@ms track=%@ otherCancelled=%d chars=%d",
               ms,
               infMs.map { String(format: "%.1f", $0) } ?? "nil",
               track.map { $0.rawValue } ?? "none",
               cancelledOtherTrack ? 1 : 0,
               textLength)
    }

    // MARK: - E5RT 故障与韧性埋点
    //
    // 诊断入口（Console.app 按 subsystem 过滤即可看到完整证据链）：
    // ```
    // log stream --predicate 'subsystem == "<bundle-id>" AND category == "OCRMetrics"'
    // ```
    // 注意错误描述一律 %{public}@ —— 系统框架错误（如 E5RT Code 13）
    // 默认 <private>，不显式声明公开则 Console 里完全不可读。

    private static let metricsLog = OSLog(subsystem: AppLogging.subsystem, category: "OCRMetrics")

    /// 单次推理失败（含 E5RT 冷启动故障、超时弃管、Vision 底层错误）。
    static func recordInferenceFailure(track: LanguageTrack?, attempt: Int, error: Error) {
        signposter.emitEvent("OCR.InferenceFailure",
                             "track \(track?.rawValue ?? "none", privacy: .public) attempt \(attempt) kind \(String(describing: error), privacy: .public)")
        os_log(.error, log: metricsLog,
               "OCR inference failed (track=%@ attempt=%d): %{public}@",
               track?.rawValue ?? "none", attempt, String(describing: error))
    }

    /// 推理失败后的自动重试。
    static func recordInferenceRetry(track: LanguageTrack?, attempt: Int) {
        signposter.emitEvent("OCR.InferenceRetry",
                             "track \(track?.rawValue ?? "none", privacy: .public) afterAttempt \(attempt)")
        os_log(.info, log: metricsLog,
               "OCR inference retry (track=%@ after failed attempt %d)",
               track?.rawValue ?? "none", attempt)
    }

    /// ANE 冷启动预热进度（成功即停；失败重试期间每次尝试都有记录）。
    static func recordWarmup(attempt: Int, success: Bool, error: Error?) {
        if success {
            signposter.emitEvent("OCR.ANEWarmupReady", "attempt \(attempt)")
            os_log(.info, log: metricsLog,
                   "OCR ANE warmup ready (attempt %d) — pipeline operational", attempt)
        } else {
            signposter.emitEvent("OCR.ANEWarmupFailed",
                                 "attempt \(attempt) error \(error.map { String(describing: $0) } ?? "unknown", privacy: .public)")
            os_log(.error, log: metricsLog,
                   "OCR ANE warmup attempt %d failed: %{public}@",
                   attempt, error.map { String(describing: $0) } ?? "unknown")
        }
    }
}
