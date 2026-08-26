import Foundation
import CoreGraphics

// MARK: - OCR 结果模型（模块唯一权威定义）
//
// 旧实现中 `OCRLineResult` / `OCRResult` 定义在 `OCRSelectionOverlay.swift`
// （UI 文件）内；重构后移入识别引擎层，UI 层仅消费。

/// OCR 识别出的一行文字及其在屏幕上的区域。
struct OCRLineResult: Sendable, Equatable {
    let text: String
    let confidence: Float
    /// 该行在屏幕上的区域（**AppKit 全局坐标**，bottom-left origin）。
    /// 由 Vision 归一化 boundingBox 经 `DisplayGeometry` 映射而来，
    /// 供原位替换/区域定位使用。
    let appKitFrame: CGRect
}

/// 一次 OCR 的完整结果：拼接文本 + 每行文字的区域坐标。
struct OCRResult: Sendable, Equatable {
    let text: String
    let lines: [OCRLineResult]
}

// MARK: - 引擎内部模型

/// 单条识别结果（引擎坐标系）：文字 + 置信度 + **归一化** boundingBox。
///
/// 与 Vision 解耦的中间表示 —— `VisionTextRecognizer` 负责从框架类型映射而来，
/// `OCRResultAssembler` 只依赖此类型，保证组装逻辑纯函数可单测。
struct RecognizedLine: Sendable, Equatable {
    let text: String
    let confidence: Float
    /// Vision 归一化 boundingBox（0~1，origin 左下、y 向上，相对整幅输入图）。
    let normalizedBoundingBox: CGRect

    /// 置信度 × 字符数的质量分 —— 用于竞速仲裁时比较两条候选结果。
    var qualityScore: Double {
        Double(confidence) * Double(max(text.count, 1))
    }
}

// MARK: - 错误

/// OCR 捕获/识别管线的错误类型。
enum OCRError: Error, Sendable, Equatable {
    /// 屏幕捕获失败（权限缺失 / 显示器拓扑变化 / SCStream 无帧等）。
    case captureFailed(String)
    /// 预处理失败（缓冲区不可读等极端情况）。
    case preprocessingFailed(String)
}

// MARK: - 语言轨道

/// 竞速策略中的语言配置轨道。
enum LanguageTrack: String, Sendable, Equatable {
    /// 纯英文 —— 模型最轻，英文场景最快且准确率最高。
    case english
    /// 中英混合 —— 本应用的主场景（中文 UI / 中英混排文档）。
    case mixed

    /// Vision `recognitionLanguages` 列表。刻意最小化：
    /// 语言越多模型越重、推理越慢、字符混淆概率越高。
    var languages: [String] {
        switch self {
        case .english: return ["en-US"]
        case .mixed:   return ["zh-Hans", "en-US"]
        }
    }
}
