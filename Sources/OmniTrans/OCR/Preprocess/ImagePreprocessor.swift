import Foundation
import CoreVideo
import CoreGraphics
import Accelerate
import os

// MARK: - 面积预算预处理器

/// 按像素**面积预算**自适应降采样。
///
/// ## 为什么按面积而非固定长边（旧 `PixelBufferScaler` 的缺陷）
/// 1. 旧实现固定「长边 ≤ 2000px」：竖长条区域（如 800×4000 的侧栏）不会被降采样，
///    面积仍可能超预算；而 2000×2000 正方形又被过度压缩。
/// 2. 旧实现的行拷贝只做了**纵向**最近邻采样，横向直接截断左侧 —— 宽度超出
///    目标宽度的右侧内容会被静默丢弃（潜在精度 bug）。
/// 3. `.accurate`（E5 模型）推理耗时与像素面积近似二次方关系。4M 像素预算
///    （约 2560×1536 或 2000×2000）在 Retina 缩放屏上把推理时间控制在秒级，
///    同时保留足够细节供小字号识别。
///
/// 缩放使用 vImage 双线性滤波（Accelerate），质量优于最近邻且单次毫秒级。
enum ImagePreprocessor {

    nonisolated private static let log = OSLog(subsystem: AppLogging.subsystem, category: "OCPPreprocess")

    /// 最大像素数预算：超过则整体等比缩到预算内。
    static let maxPixelBudget: Int = 4_000_000

    /// 返回可直接送入识别器的缓冲：面积在预算内原样返回（零拷贝）；
    /// 超出则返回等比缩小的新 BGRA 缓冲。
    static func prepare(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let srcW = CVPixelBufferGetWidth(source)
        let srcH = CVPixelBufferGetHeight(source)
        let pixels = srcW * srcH
        guard pixels > maxPixelBudget else { return source }

        // 等比缩放因子：sqrt(budget / pixels)
        let scale = sqrt(Double(maxPixelBudget) / Double(pixels))
        let dstW = max(Int((Double(srcW) * scale).rounded()), 32)
        let dstH = max(Int((Double(srcH) * scale).rounded()), 32)

        let metricsState = OCRMetrics.begin(.preprocess)
        defer { OCRMetrics.end(.preprocess, metricsState) }

        guard let dst = createBuffer(width: dstW, height: dstH) else {
            throw OCRError.preprocessingFailed("CVPixelBufferCreate \(dstW)x\(dstH) failed")
        }

        // ── vImage 双线性缩放（BGRA，8bpc）──
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(dst)
        else {
            throw OCRError.preprocessingFailed("base address unavailable")
        }

        var srcInfo = vImage_Buffer(
            data: srcBase,
            height: vImagePixelCount(srcH),
            width: vImagePixelCount(srcW),
            rowBytes: CVPixelBufferGetBytesPerRow(source))
        var dstInfo = vImage_Buffer(
            data: dstBase,
            height: vImagePixelCount(dstH),
            width: vImagePixelCount(dstW),
            rowBytes: CVPixelBufferGetBytesPerRow(dst))

        let error = vImageScale_ARGB8888(&srcInfo, &dstInfo, nil,
                                         vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else {
            throw OCRError.preprocessingFailed("vImageScale error \(error)")
        }

        os_log(.debug, log: Self.log, "Downscaled %dx%d → %dx%d (area budget)",
               srcW, srcH, dstW, dstH)
        return dst
    }

    /// 创建 IOSurface 后备的 BGRA 像素缓冲（Vision 友好格式）。
    static func createBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var newBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary,
                                  &newBuffer) == kCVReturnSuccess else { return nil }
        return newBuffer
    }
}
