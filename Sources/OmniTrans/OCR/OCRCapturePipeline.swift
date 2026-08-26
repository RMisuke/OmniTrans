import Foundation
import CoreVideo
import os

// MARK: - OCR 捕获识别管线（门面）

/// 「捕获 → 预处理 → 竞速识别 → 组装」一站式编排入口。
///
/// UI 层（框选 overlay / 划词兜底策略）只依赖此门面，不接触任何
/// Vision / ScreenCaptureKit 类型。无实例状态（`Sendable` struct），
/// 可安全并发复用。
struct OCRCapturePipeline: Sendable {

    nonisolated private static let log = OSLog(subsystem: AppLogging.subsystem, category: "OCRPipeline")

    private let captureService: any ScreenRegionCapturing
    /// 内部可见：基准测试直接驱动竞速编排（绕过屏幕捕获）。
    var racer: RacingLanguageStrategy

    init(captureService: any ScreenRegionCapturing = SCStreamRegionCapture(),
         recognizer: any TextRecognizing = VisionTextRecognizer()) {
        self.captureService = captureService
        self.racer = RacingLanguageStrategy(recognizer: recognizer)
    }

    /// 默认共享实例（生产路径）。
    static let shared = OCRCapturePipeline()

    /// 完整执行一次「框选区域 → 识别结果」。
    ///
    /// - Parameters:
    ///   - appKitRect: **AppKit 全局坐标**（bottom-left）的目标区域。
    ///   - excludingWindowID: 从捕获中排除的窗口（overlay 自身）。
    /// - Returns: 识别结果；区域无文字返回 nil。
    /// - Throws: `OCRError.captureFailed` —— 屏幕捕获失败（区别于「无文字」）。
    mutating func captureAndRecognize(appKitRect: CGRect,
                                      excludingWindowID: CGWindowID) async throws -> OCRResult? {
        let totalStart = ContinuousClock.now

        // ── 1. 捕获 ──
        let captureState = OCRMetrics.begin(.capture)
        guard let buffer = await captureService.capture(appKitRect: appKitRect,
                                                        excludingWindowID: excludingWindowID) else {
            OCRMetrics.end(.capture, captureState)
            throw OCRError.captureFailed("SCStream returned no frame for \(appKitRect)")
        }
        OCRMetrics.end(.capture, captureState)

        // ── 2. 预处理（面积预算降采样，预算内零拷贝直通）──
        let processed = try ImagePreprocessor.prepare(buffer)

        // ── 3. 竞速识别 + 4. 组装 ──
        let inferenceStart = ContinuousClock.now
        let lines = await racer.recognizeBest(processed)
        let inferenceDuration = ContinuousClock.now - inferenceStart

        guard let lines else {
            OCRMetrics.logSummary(total: ContinuousClock.now - totalStart,
                            inference: inferenceDuration,
                            track: nil, cancelledOtherTrack: false, textLength: 0)
            return nil
        }

        guard let result = OCRResultAssembler.assemble(lines, appKitRect: appKitRect) else {
            OCRMetrics.logSummary(total: ContinuousClock.now - totalStart,
                            inference: inferenceDuration,
                            track: nil, cancelledOtherTrack: false, textLength: 0)
            return nil
        }

        OCRMetrics.logSummary(total: ContinuousClock.now - totalStart,
                        inference: inferenceDuration,
                        track: nil, cancelledOtherTrack: false,
                        textLength: result.text.count)
        return result
    }

    // MARK: - 同步桥接（划词兜底策略专用）

    /// 同步版本的「捕获 + 识别」，供旧的同步 `TextCaptureStrategy.tryCapture()`
    /// 协议桥接调用。信号量等待，带超时保护，不会永久阻塞调用线程。
    ///
    /// - Parameter timeout: 最长等待时间。
    static func captureAndRecognizeSync(appKitRect: CGRect,
                                        excludingWindowID: CGWindowID = 0,
                                        timeout: TimeInterval = 10) -> String? {
        let box = OSAllocatedUnfairLock(initialState: nil as OCRResult?)
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached(priority: .userInitiated) {
            defer { semaphore.signal() }
            var pipeline = OCRCapturePipeline.shared
            let result = try? await pipeline.captureAndRecognize(appKitRect: appKitRect,
                                                                 excludingWindowID: excludingWindowID)
            box.withLock { $0 = result }
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        return box.withLock { $0 }?.text
    }
}
