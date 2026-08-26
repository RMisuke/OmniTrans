import Foundation
import CoreVideo
import CoreGraphics
import os
@preconcurrency import Vision

// MARK: - Vision 文字识别器（macOS 15 Swift API）

/// 封装 macOS 15 新 `RecognizeTextRequest`（WWDC24 Swift 并发 API）。
///
/// ## 相比旧 `VNRecognizeTextRequest.perform()` 的关键收益
/// 1. **原生 async/await**：无需 DispatchQueue + CheckedContinuation 桥接，
///    无需 `ResumeOnceGate` 超时硬切 —— 旧方案超时后后台线程仍空转烧 CPU。
/// 2. **原生任务取消**：`Task.cancel()` 直接终止底层神经网络推理。
///    竞速落败方的 ANE/CPU 资源被立即释放，而不是继续跑完整个请求。
/// 3. **自动硬件调度**：系统按芯片状态自动选择 ANE/GPU/CPU，
///    旧实现的手动硬件探测（`OCRHardwareDiagnostic` 三步探针 + 自适应降级）
///    整体不再必要，已删除。
struct VisionTextRecognizer: TextRecognizing {

    nonisolated private static let log = OSLog(subsystem: AppLogging.subsystem, category: "OCRInference")

    func recognize(_ buffer: CVPixelBuffer, track: LanguageTrack) async throws -> [RecognizedLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = RecognitionDefaults.usesLanguageCorrection
        // 新 API 的语言类型是 `Locale.Language`（非字符串）。
        request.recognitionLanguages = track.languages.map { Locale.Language(identifier: $0) }
        request.minimumTextHeightFraction = RecognitionDefaults.minimumTextHeight

        let observations = try await request.perform(on: buffer)

        var lines: [RecognizedLine] = []
        lines.reserveCapacity(observations.count)
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(RecognizedLine(
                text: text,
                confidence: candidate.confidence,
                normalizedBoundingBox: Self.normalizedBoundingBox(of: obs)))
        }
        return lines
    }

    // MARK: - 坐标换算

    /// 新 API 不再直接暴露归一化 boundingBox，而是四角归一化点
    /// （`topLeft/topRight/bottomLeft/bottomRight`）。取极值重构为轴对齐矩形，
    /// 与旧 `VNRecognizedTextObservation.boundingBox` 语义一致：
    /// 归一化坐标（0~1）、origin 左下、y 向上。
    private static func normalizedBoundingBox(of obs: RecognizedTextObservation) -> CGRect {
        let points = [obs.topLeft.cgPoint, obs.topRight.cgPoint,
                      obs.bottomLeft.cgPoint, obs.bottomRight.cgPoint]
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
