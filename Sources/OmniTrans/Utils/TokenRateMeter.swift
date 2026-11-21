import Foundation

/// 流式 token 速率估计（P2）。
///
/// 在 AppState 的 batch 消费点采样（不改引擎协议）：每批估算 token 数，
/// 批级瞬时速率做 EMA 平滑，UI 以 ≤2Hz 发布；完成时冻结为整体均值
/// （排除首字延迟 TTFT）。
///
/// token 估算为 BPE 近似：CJK（含日文假名/韩文）字符 ×1.35（o200k 实测中位，
/// backlog 校准），其他字符 ÷4.0。标签以 `≈` 前缀表明为估算值。
struct TokenRateMeter {
    private(set) var totalTokens: Double = 0
    /// 实时速率（tok/s），首个可测间隔之前为 nil。
    private(set) var rate: Double?
    /// 首字延迟（请求开始 → 首个 batch）。
    private(set) var ttft: TimeInterval?

    private let startAt: Date
    private var firstBatchAt: Date?
    private var lastBatchAt: Date?
    private var lastPublishAt: Date = .distantPast

    /// UI 发布间隔（秒）—— 2Hz。
    static let publishInterval: TimeInterval = 0.5

    init(startAt: Date = Date()) {
        self.startAt = startAt
    }

    /// 估算一段文本的 token 数。
    static func estimateTokens(_ text: String) -> Double {
        var cjk = 0, other = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v)      // CJK 统一表意
                || (0x3400...0x4DBF).contains(v)  // CJK 扩展 A
                || (0x3040...0x30FF).contains(v)  // 日文假名
                || (0xAC00...0xD7AF).contains(v) { // 韩文音节
                cjk += 1
            } else {
                other += 1
            }
        }
        return Double(cjk) * 1.35 + Double(other) / 4.0
    }

    /// 喂入一个 batch。
    /// - Returns: `true` 表示本次应发布到 UI（≤2Hz 节流）。
    mutating func feed(_ batch: String, now: Date = Date()) -> Bool {
        totalTokens += Self.estimateTokens(batch)
        if firstBatchAt == nil {
            firstBatchAt = now
            ttft = now.timeIntervalSince(startAt)
        }
        if let last = lastBatchAt {
            let dt = now.timeIntervalSince(last)
            if dt > 0.001 {
                let instant = Self.estimateTokens(batch) / dt
                rate = rate.map { $0 * 0.7 + instant * 0.3 } ?? instant
            }
        }
        lastBatchAt = now
        guard rate != nil, now.timeIntervalSince(lastPublishAt) >= Self.publishInterval else {
            return false
        }
        lastPublishAt = now
        return true
    }

    /// 完成时的整体均值（排除首字延迟）。样本不足（单 batch / 非流式）返回 nil。
    func finalRate() -> Double? {
        guard let first = firstBatchAt, let last = lastBatchAt,
              last.timeIntervalSince(first) > 0.001 else { return nil }
        return totalTokens / last.timeIntervalSince(first)
    }

    /// 用服务端真实 completion_tokens 校准终值（OpenAI 系 usage 上报，backlog）。
    /// 真实 token 数 / 生成时长（排除 TTFT），比字符估算更准。
    func finalRate(actualTokens: Int?) -> Double? {
        guard let actualTokens, actualTokens > 0,
              let first = firstBatchAt, let last = lastBatchAt,
              last.timeIntervalSince(first) > 0.001 else { return nil }
        return Double(actualTokens) / last.timeIntervalSince(first)
    }
}