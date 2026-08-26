import Foundation
import CoreVideo

// MARK: - 文字识别协议

/// 文字识别抽象 —— 把 Vision 框架类型与竞速编排/组装层隔离。
protocol TextRecognizing: Sendable {
    /// 对一块 BGRA 像素缓冲执行 `.accurate` 级别文字识别。
    ///
    /// - Parameters:
    ///   - buffer: 待识别的 BGRA 像素缓冲（应已通过 `ImagePreprocessor` 控制面积）。
    ///   - track: 语言轨道配置（语言列表 + 是否语言校正）。
    /// - Returns: 归一化坐标的识别结果行；无文字时返回空数组。
    /// - Throws: Vision 底层错误；调用方取消 Task 时抛 `CancellationError`。
    func recognize(_ buffer: CVPixelBuffer, track: LanguageTrack) async throws -> [RecognizedLine]
}

/// 语言校正策略：全部开启 —— 即使 `.accurate` 模型精度更高，语言校正仍能
/// 修正数字/字母混淆、标点误识别等边缘情况。
enum RecognitionDefaults {
    static let usesLanguageCorrection = true
    /// 最小文字高度（归一化）：过滤极端微小噪声（图标/水印），
    /// 同时保留缩放后较小的正常文本行。
    static let minimumTextHeight: Float = 0.005
}
