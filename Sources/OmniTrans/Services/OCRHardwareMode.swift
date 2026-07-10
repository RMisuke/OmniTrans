import Foundation
import Vision
import CoreVideo

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

    private init() {}

    /// Call once at app startup (from `applicationDidFinishLaunching`).
    /// Runs asynchronously on a background Task; the probe result is stored
    /// in `OCRHardwareMode.current` and consumed by `performOCR()`.
    func run() async {
        // ── Step 1: .accurate with ANE ──
        let step1 = await probeAccurate(timeout: 3.0)
        if step1 {
            print("[OCRDiag] ✅ .accurate with ANE works → ane mode")
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
            print("[OCRDiag] ✅ .accurate on CPU (VNDisableANE) works → cpu mode")
            OCRHardwareMode.current = .cpu
            return
        }

        // ── Step 3: Both failed → fast only ──
        print("[OCRDiag] ⚠️ .accurate unavailable → fast mode (E5 model bundles missing)")
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
            print("[OCRDiag] ⚠️ Failed to allocate test pixel buffer")
            return false
        }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en"]
            request.minimumTextHeight = 0.01

            let queue = DispatchQueue(label: "ocr-diag")
            var success = false
            let semaphore = DispatchSemaphore(value: 0)

            queue.async {
                let handler = VNImageRequestHandler(cvPixelBuffer: testBuffer, options: [:])
                do {
                    try handler.perform([request])
                    success = true
                } catch {
                    // Expected when E5 bundles are corrupt: CRImageReaderError
                    success = false
                }
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + timeout)
            continuation.resume(returning: success)
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
