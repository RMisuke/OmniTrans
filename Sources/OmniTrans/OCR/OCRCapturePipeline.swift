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

    /// ANE 冷启动预热入口 —— app 启动时在后台调用一次。
    /// 详见 `ANEWarmup`：把 E5RT 管线编译/加载成本移出用户首次 OCR 路径。
    static func warmUpANE() async {
        await ANEWarmup.run(recognizer: VisionTextRecognizer())
    }

    /// 完整执行一次「框选区域 → 识别结果」。
    ///
    /// 外层套 45s 端到端硬上限作最后兑底保险（正常路径各阶段已有自身上界：
    /// 捕获 3s 帧超时、推理闸门 + deadline）—— 保证调用方在有限时间内
    /// 必然拿到确定结果，UI 的「解析中」状态不会永久滞留。
    mutating func captureAndRecognize(appKitRect: CGRect,
                                      excludingWindowID: CGWindowID) async throws -> OCRResult? {
        let runner = self
        let outcome = await withInferenceDeadline(.seconds(45)) { () -> Result<OCRResult?, Error> in
            var r = runner
            do {
                return .success(try await r.performCaptureAndRecognize(appKitRect: appKitRect,
                                                                       excludingWindowID: excludingWindowID))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let inner):
            switch inner {
            case .success(let result): return result
            case .failure(let error): throw error
            }
        case .failure(InferenceDeadlineError.exceeded):
            throw OCRError.captureFailed("OCR pipeline exceeded 45s end-to-end deadline")
        case .failure(let error):
            throw error
        }
    }

    /// 管线主体（无总超时包裹），由 `captureAndRecognize` 兑底调用。
    private mutating func performCaptureAndRecognize(appKitRect: CGRect,
                                                     excludingWindowID: CGWindowID) async throws -> OCRResult? {
        let totalStart = ContinuousClock.now

        // ── 1. 捕获（含恢复性重试）──
        // 首次捕获失败（帧超时 / SCStream 资源争抢）后等待 0.5s 再试一次，
        // 给前一个累积的 SCStream 释放系统资源的窗口。仅重试一次，避免延长总超时。
        let captureState = OCRMetrics.begin(.capture)
        var buffer = await captureService.capture(appKitRect: appKitRect,
                                                   excludingWindowID: excludingWindowID)
        if buffer == nil {
            os_log(.info, log: Self.log,
                   "Capture returned nil (frame timeout?) — waiting 0.5s for recovery, then retrying")
            OCRMetrics.end(.capture, captureState)
            try? await Task.sleep(for: .milliseconds(500))
            let retryState = OCRMetrics.begin(.capture)
            buffer = await captureService.capture(appKitRect: appKitRect,
                                                   excludingWindowID: excludingWindowID)
            if buffer == nil {
                OCRMetrics.end(.capture, retryState)
                throw OCRError.captureFailed("SCStream returned no frame for \(appKitRect) (after retry)")
            }
            OCRMetrics.end(.capture, retryState)
        } else {
            OCRMetrics.end(.capture, captureState)
        }

        guard let buffer else {
            // Defensive: should be unreachable after the capture+retry block above
            throw OCRError.captureFailed("Internal error: buffer nil after capture retry")
        }

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
