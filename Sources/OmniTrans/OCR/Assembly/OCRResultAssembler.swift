import Foundation
import CoreGraphics
import DisplayGeometry

// MARK: - 结果组装器

/// 把引擎层的 `[RecognizedLine]` 组装成面向业务的 `OCRResult`。
///
/// 全部为纯函数（无状态、无 IO），可脱离 Vision 直接单测。
enum OCRResultAssembler {

    /// 置信度下限：过滤低质量噪声行（图标误识别等）。
    /// 沿用旧实现验证过的 0.35 阈值 —— 过滤噪声的同时不丢合法文字。
    static let minConfidence: Float = 0.35

    /// 行分组阈值（归一化，相对整幅捕获图高度）：Y 差超过该值视为不同行。
    static let rowThreshold: CGFloat = 0.025

    /// 组装入口：过滤 → 坐标映射 → 空间排序 → 拼接。
    ///
    /// - Parameters:
    ///   - lines: 引擎识别结果（归一化坐标）。
    ///   - appKitRect: 捕获时的 AppKit 全局区域（bottom-left），
    ///     归一化坐标经 `DisplayGeometry` 映射回屏幕全局坐标。
    /// - Returns: 完整结果；无有效文字时返回 nil。
    static func assemble(_ lines: [RecognizedLine],
                         appKitRect: CGRect) -> OCRResult? {
        guard !lines.isEmpty else { return nil }

        // ── 过滤 + 坐标映射 ──
        let mapped = lines.compactMap { line -> OCRLineResult? in
            guard line.confidence >= minConfidence else { return nil }
            let frame = DisplayGeometry.appKitGlobalRect(fromVisionNormalized: line.normalizedBoundingBox,
                                                         within: appKitRect)
            return OCRLineResult(text: line.text,
                                 confidence: line.confidence,
                                 appKitFrame: frame)
        }
        guard !mapped.isEmpty else { return nil }

        // ── 空间排序：行（Y 相差超阈值）从上到下，同行内从左到右 ──
        let ordered = mapped.sorted { a, b in
            if abs(a.appKitFrame.minY - b.appKitFrame.minY) > rowThreshold * appKitRect.height {
                return a.appKitFrame.minY > b.appKitFrame.minY
            }
            return a.appKitFrame.minX < b.appKitFrame.minX
        }

        // ── 行拼接 ──
        var text = ""
        var lastY: CGFloat = .greatestFiniteMagnitude
        var prevText = ""
        for item in ordered {
            if item.text == prevText { continue }  // 相邻重复去重（竞速双轨重叠场景防御）
            prevText = item.text
            if lastY != .greatestFiniteMagnitude,
               abs(item.appKitFrame.minY - lastY) > rowThreshold * appKitRect.height {
                text += "\n"
            } else if !text.isEmpty {
                text += " "
            }
            text += item.text
            lastY = item.appKitFrame.minY
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return OCRResult(text: trimmed, lines: ordered)
    }

    /// 结果质量分：Σ(置信度 × 字符数)。供竞速仲裁比较两条候选结果；
    /// 中文单字信息量大，字符数加权天然偏向内容更完整的结果。
    static func qualityScore(_ lines: [RecognizedLine]) -> Double {
        lines.reduce(0) { $0 + $1.qualityScore }
    }
}
