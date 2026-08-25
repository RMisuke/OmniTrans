import Foundation
import os
@preconcurrency import Vision
@preconcurrency import CoreVideo

// MARK: - OCR Execution Modes

/// The optimal execution strategy for Vision text recognition on this system,
/// determined by a startup probe.
///
/// The probe performs a tiny `.accurate` recognition on a synthetic image with
/// a 3-second timeout.  This tests the entire Vision pipeline: model loading,
/// ANE compilation, neural-network inference, and result decoding.
///
/// The result persists in memory for the lifetime of the process.  It is
/// re-evaluated on every app launch so that future macOS updates that fix
/// the E5 model bundles are automatically detected.
enum OCRHardwareMode: Sendable, Equatable {
    /// `.accurate` with ANE acceleration — fastest and highest quality.
    /// Used when the full E5 model bundle is available on this chip.
    case ane

    /// `.accurate` on CPU (Espresso engine) — same neural-network accuracy,
    /// but 2-3× slower than ANE.  Used when ANE is broken but the model
    /// files themselves are loadable.
    case cpu

    /// `.fast` CRNN classifier — lightweight, CPU-only, no ANE dependency.
    /// Slightly lower accuracy (character substitutions possible) but
    /// guaranteed to work even with corrupt system frameworks.
    case fast

    // ─────────────────────────────────────────────────────────────
    //  Thread-safe singleton — written once by the probe, then read
    //  from `nonisolated` OCR code without synchronization.
    // ─────────────────────────────────────────────────────────────

    /// The active execution mode, determined at startup by `OCRDiagnostic.run()`.
    /// Defaults to `.fast` (safest) until the probe completes.
    nonisolated(unsafe) static var current: OCRHardwareMode = .fast
}

// MARK: - Startup Probe

/// Runs a lightweight Vision recognition test at app startup to determine
/// which OCR execution mode is available on this system.
///
/// ## Probe sequence
/// 1. `.accurate` with ANE allowed — 3 s timeout
/// 2. `.accurate` with `VNDisableANE=1` — 3 s timeout (only if step 1 failed)
/// 3. If both fail → `.fast` (model files corrupt / unavailable)
///
/// ## Why a runtime probe is necessary
/// The E5 ANE model bundles (`cr_tr_model_*_e5.mlmodelc.bundle`) are loaded
/// lazily by the TextRecognition framework.  File-existence checks alone
/// cannot distinguish between "ANE temporarily busy" and "model bundle
/// permanently corrupt".  Running a real (tiny) recognition request is the
/// only reliable diagnostic.
@MainActor
final class OCRHardwareDiagnostic {
    static let shared = OCRHardwareDiagnostic()

    /// 幂等守卫 —— 确保探测只执行一次（审计 C3：惰性触发入口）。
    private var hasRun = false

    nonisolated private static let diagLog = OSLog(subsystem: AppLogging.subsystem, category: "OCRDiag")

    private init() {}

    /// 首次 OCR 时调用（替代启动时立即探测）。幂等：已运行过则立即返回。
    func runIfNeeded() async {
        guard !hasRun else { return }
        hasRun = true
        await run()
    }

    /// Runs the probe sequence. Call once (via `runIfNeeded`).
    func run() async {
        // ── Step 1: .accurate with ANE ──
        let step1 = await probeAccurate(timeout: 3.0)
        if step1 {
            os_log(.debug, log: Self.diagLog, ".accurate with ANE works → ane mode")
            OCRHardwareMode.current = .ane
            return
        }

        // ── Step 2: .accurate on CPU (VNDisableANE) ──
        // Set the env var BEFORE the probe so Vision's model loader
        // sees it.  Even if the env var was already set elsewhere,
        // setting it again is harmless.
        setenv("VNDisableANE", "1", 1)
        let step2 = await probeAccurate(timeout: 3.0)
        if step2 {
            os_log(.debug, log: Self.diagLog, ".accurate on CPU (VNDisableANE) works → cpu mode")
            OCRHardwareMode.current = .cpu
            return
        }

        // ── Step 3: Both failed → fast only ──
        os_log(.default, log: Self.diagLog, ".accurate unavailable → fast mode (E5 model bundles missing)")
        OCRHardwareMode.current = .fast
    }

    // MARK: - Private Helpers

    /// Creates a tiny test image (white, 100×30) and runs `.accurate`
    /// text recognition with the given timeout.
    ///
    /// Uses a real `VNImageRequestHandler` + `CVPixelBuffer` — the same
    /// code path as production OCR — so the probe detects *actual*
    /// system-level failures (missing E5 bundles, ANE compilation hangs,
    /// framework permissions, etc.).
    private func probeAccurate(timeout: Double) async -> Bool {
        guard let testBuffer = Self.createTestPixelBuffer() else {
            os_log(.error, log: Self.diagLog, "Failed to allocate test pixel buffer")
            return false
        }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en"]
            request.minimumTextHeight = 0.01

            // 单次 resume 门控：结果回调与超时回调竞态安全，避免双重 resume。
            let gate = ResumeOnceGate()
            let queue = DispatchQueue(label: "ocr-diag")
            // CVBuffer 非 Sendable：用显式 Sendable 盒声明「后台执行期间生命周期由调用方保证」。
            let pb = PixelBufferBox(testBuffer)

            queue.async {
                let handler = VNImageRequestHandler(cvPixelBuffer: pb.value, options: [:])
                do {
                    try handler.perform([request])
                    gate.runOnce { continuation.resume(returning: true) }
                } catch {
                    // Expected when E5 bundles are corrupt: CRImageReaderError
                    gate.runOnce { continuation.resume(returning: false) }
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                gate.runOnce { continuation.resume(returning: false) }
            }
        }
    }

    /// Allocates a 100×30 white BGRA pixel buffer.
    private static func createTestPixelBuffer() -> CVPixelBuffer? {
        let w = 100, h = 30
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: w,
            kCVPixelBufferHeightKey: h,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary,
                                  &pixelBuffer) == kCVReturnSuccess,
              let buf = pixelBuffer
        else { return nil }

        CVPixelBufferLockBaseAddress(buf, [])
        memset(CVPixelBufferGetBaseAddress(buf), 0xFF, CVPixelBufferGetDataSize(buf))
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }
}

// MARK: - Single-resume Gate

/// 保证 `CheckedContinuation` 只被 resume 一次（超时与结果竞态门控）。
private final class ResumeOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func runOnce(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        block()
    }
}

/// CVBuffer（`CVPixelBuffer`）非 Sendable 的显式包装：由调用方保证在后台
/// 队列执行期间缓冲区生命周期有效（消除 `@Sendable` 闭包捕获告警）。
private final class PixelBufferBox: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}
