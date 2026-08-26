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
        let ms = Double(total.components.attoseconds) / 1e15
        let infMs = inference.map { Double($0.components.attoseconds) / 1e15 }
        os_log(.info, log: OSLog(subsystem: AppLogging.subsystem, category: "OCRMetrics"),
               "OCR summary: total=%.1fms inference=%@ms track=%@ otherCancelled=%d chars=%d",
               ms,
               infMs.map { String(format: "%.1f", $0) } ?? "nil",
               track.map { $0.rawValue } ?? "none",
               cancelledOtherTrack ? 1 : 0,
               textLength)
    }
}
