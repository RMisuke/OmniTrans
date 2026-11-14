import Foundation
import CoreVideo
import os

// MARK: - ANE 冷启动预热

/// 进程启动后立即在后台预热 Apple 神经引擎（ANE/E5RT）文字识别管线。
///
/// ## 背景（真机日志实锤，2026-08-26）
/// app 启动后 1–2 分钟内，`com.apple.TextRecognition` 反复报
/// `e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options
/// call failed (Code: 13)` —— 文字识别模型的 ANE 计算管线尚未就绪，
/// 此窗口内所有 `RecognizeTextRequest.perform()` 要么失败、要么停滞 ~40s。
/// 用户侧表现为「启动后 OCR 取词一直解析中，2–3 分钟后恢复正常」。
///
/// ## 策略
/// 启动即用合成噪声图在后台跑真实识别，强制系统提前完成 ANE 管线的
/// 编译/加载；失败（E5RT 未就绪）则按固定间隔重试直至成功或达到上限。
/// 预热完成后，用户首次真实 OCR 不再支付冷启动成本。
///
/// 预热不经过竞速编排（`RacingLanguageStrategy`），避免污染
/// `RacePolicyMemory` 的自适应单轨统计。
enum ANEWarmup {

    nonisolated private static let log = OSLog(subsystem: AppLogging.subsystem, category: "OCRWarmup")

    /// 合成预热图：960×640 BGRA 随机噪声。
    ///
    /// 用噪声而非纯色/空白 —— 空输入可能被框架短路，跑不到完整的
    /// 神经网络前向路径；噪声保证整条 ANE 管线被真实执行。
    static func makeSyntheticBuffer() -> CVPixelBuffer? {
        guard let buffer = ImagePreprocessor.createBuffer(width: 960, height: 640) else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            let ptr = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
            arc4random_buf(ptr, rowBytes)
        }
        return buffer
    }

    /// 执行预热：混合轨道与英文轨道各跑一次（两套语言模型都要暖），
    /// 失败按 `interval` 重试，成功即停。
    ///
    /// 每次尝试经 `withInferenceDeadline` 包裹（弃管式真实超时）：
    /// E5RT 停滞期的单次调用实测可阻塞 ~60s，不设超时会让重试节奏失灵
    /// （一次尝试就卡满一分钟）。到点弃管后按 `interval` 重试，
    /// ANE 就绪后的首次调用必在时限内成功。
    ///
    /// 每次尝试后向 `OCRWarmupState.shared` 报告进度，供 UI 显示进度条。
    ///
    /// - Parameters:
    ///   - recognizer: 识别器（生产传 `VisionTextRecognizer()`，测试可注入 mock）。
    ///   - maxAttempts: 最大尝试次数（默认 12 次 ≈ 覆盖实测 1–2 分钟冷启动窗口）。
    ///   - interval: 失败重试间隔。
    ///   - attemptDeadline: 单次尝试的超时（弃管语义）。
    static func run(recognizer: any TextRecognizing,
                    maxAttempts: Int = 10,
                    baseInterval: Duration = .seconds(3),
                    maxInterval: Duration = .seconds(10),
                    attemptDeadline: Duration = .seconds(20)) async {
        guard let buffer = makeSyntheticBuffer() else {
            os_log(.error, log: log, "ANE warmup skipped: synthetic buffer creation failed")
            return
        }
        // 只读共享盒：消除 sending 闭包捕获告警（与竞速策略同法）。
        let box = PixelBufferBox(buffer)

        // E5RT Code 13 连续计数器：连续 2+ 次 Code 13 → 清理缓存重试
        var consecutiveE5RT13 = 0
        // E5 模型不可用计数器：连续 2+ 次 "Unable to find a valid E5" → 放弃 ANE，使用 CPU 模式
        var consecutiveE5NotFound = 0

        for attempt in 1...max(1, maxAttempts) {
            // 报告预热进度（主线程更新 @Published）
            await MainActor.run {
                OCRWarmupState.shared.updateProgress(attempt: attempt - 1)
            }

            var failed: Error?
            // 用户 OCR 排队等待中 → 预热立即让出，不竞争闸门。
            // 检测方式：闸门队列中有等待者时暂停预热。
            if OCRInferenceGate.shared.queuedCount > 0 {
                os_log(.info, log: log, "Warmup yielding — user OCR queued")
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            // 预热也经全局推理闸门 —— 若用户识别正占用管线，本轮尝试按失败处理、
            // 按 interval 重试，避免与真实 OCR 抢 ANE。
            do {
                try await OCRInferenceGate.shared.acquire()
            } catch {
                failed = error
            }
            if failed == nil {
                do {
                    _ = try await withInferenceDeadline(attemptDeadline) {
                        try await recognizer.recognize(box.value, track: .mixed)
                    }.get()
                    _ = try await withInferenceDeadline(attemptDeadline) {
                        try await recognizer.recognize(box.value, track: .english)
                    }.get()
                } catch {
                    failed = error
                }
                // 到点即释放（与竞速路径同策略），停滞调用不长期占住闸门。
                OCRInferenceGate.shared.release()
            }
            if let failed {
                // 检测 E5 模型不可用（"Unable to find a valid E5"）
                if Self.isE5ModelNotFound(failed) {
                    consecutiveE5NotFound += 1
                    if consecutiveE5NotFound >= 2 {
                        os_log(.error, log: log,
                               "ANE warmup: E5 Neural Engine models not available — OCR will use CPU-only Vision")
                        // 不标记失败，标记完成（降级模式）
                        await MainActor.run {
                            OCRWarmupState.shared.markComplete()
                        }
                        return
                    }
                } else {
                    consecutiveE5NotFound = 0
                }
                // 检测 E5RT Code 13（E5 bundle 资源缺失/损坏）
                if Self.isE5RTCode13(failed) {
                    consecutiveE5RT13 += 1
                    if consecutiveE5RT13 >= 2 {
                        os_log("ANE warmup: %d consecutive E5RT Code 13 errors — clearing E5RT cache and retrying",
                               log: log, type: .error,
                               consecutiveE5RT13)
                        Self.clearE5RTCache()
                        consecutiveE5RT13 = 0
                        // 给系统时间重建缓存
                        try? await Task.sleep(for: .seconds(3))
                    }
                } else {
                    consecutiveE5RT13 = 0
                }
                OCRMetrics.recordWarmup(attempt: attempt, success: false, error: failed)
            } else {
                OCRMetrics.recordWarmup(attempt: attempt, success: true, error: nil)
                await MainActor.run {
                    OCRWarmupState.shared.markComplete()
                }
                return
            }
            guard !Task.isCancelled else { return }
            // Adaptive backoff: 3s → 5s → 8s → 10s (capped), covers ~120s window
            let backoffSeconds = min(
                Double(baseInterval.components.seconds) * (1.0 + Double(attempt) * 0.6),
                Double(maxInterval.components.seconds)
            )
            try? await Task.sleep(for: .seconds(Int(backoffSeconds)))
        }
        os_log(.error, log: log,
               "ANE warmup gave up after %d attempts — OCR may be slow/unreliable until pipeline ready", maxAttempts)
        // 达到上限仍失败 → 标记失败（用户可通过 OCR 快捷键手动重试）
        await MainActor.run {
            OCRWarmupState.shared.markFailed()
        }
    }

    // MARK: - E5 模型检测

    /// 检测 E5 Neural Engine 模型是否不可用（硬件不支持或模型未安装）。
    /// 系统日志："Unable to find a valid E5 in provided path ... Found bundles : { }"
    private static func isE5ModelNotFound(_ error: Error) -> Bool {
        let desc = String(describing: error)
        return desc.contains("Unable to find a valid E5")
            || desc.contains("Found bundles : { }")
            || (desc.contains("GetE5PathFromCompositeBundle") && !desc.contains("timeout"))
    }

    // MARK: - E5RT 缓存清理

    /// 检测是否为 E5RT Code 13 错误（E5 bundle 资源缺失/损坏）。
    private static func isE5RTCode13(_ error: Error) -> Bool {
        let desc = String(describing: error)
        return desc.contains("e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options")
            && desc.contains("13")
    }

    /// 清理 E5RT 缓存目录，强制系统下次调用时重新编译 ANE 模型。
    ///
    /// 真机日志显示 E5RT 缓存目录中可能存在不完整的 bundle（`Found bundles : { }`），
    /// 导致反复 Code 13 错误。清理后系统会在下次 Vision 调用时重新编译。
    private static func clearE5RTCache() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let e5rtCache = cachesDir?.appendingPathComponent("com.apple.e5rt.e5bundlecache")

        guard let cachePath = e5rtCache?.path else {
            os_log("E5RT cache path unavailable — skipping cleanup", log: log, type: .error)
            return
        }

        guard FileManager.default.fileExists(atPath: cachePath) else {
            os_log(.info, log: log, "E5RT cache directory does not exist — nothing to clean")
            return
        }

        do {
            try FileManager.default.removeItem(atPath: cachePath)
            os_log(.info, log: log, "E5RT cache cleared: %{public}@", cachePath)
        } catch {
            os_log(.error, log: log, "Failed to clear E5RT cache: %{public}@", error.localizedDescription)
        }
    }
}
