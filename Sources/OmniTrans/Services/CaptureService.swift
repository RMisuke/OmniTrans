import Cocoa
import ScreenCaptureKit

// MARK: - Capture Service Protocol

protocol CaptureServiceProtocol: Sendable {
    /// Captures a screen region and returns the raw `CVPixelBuffer` for
    /// zero-copy handoff to Vision.  Callers must lock the buffer (read-only)
    /// for the duration of Vision processing and unlock immediately after.
    func capture(appKitRect: CGRect, excludingWindowID: CGWindowID) async -> CVPixelBuffer?
}

// MARK: - SCStream Single-Frame Capture Helper (macOS 14+)

/// Uses `SCStream` + custom `SCStreamOutput` to capture exactly one frame
/// as a `CVPixelBuffer`, then stops the stream.  This avoids the
/// `CGImage`-backed `SCScreenshotManager.captureImage` path entirely,
/// eliminating the CPU-side pixel copy / colour-space conversion that
/// `CGImage` imposes on high-DPI displays.
///
/// The returned buffer uses `kCVPixelFormatType_32BGRA` (set in the
/// `SCStreamConfiguration`) — the native Vision-friendly format —
/// and can be handed directly to `VNImageRequestHandler(cvPixelBuffer:)`.
final class ScreenCaptureService: CaptureServiceProtocol {

    func capture(appKitRect: CGRect, excludingWindowID: CGWindowID) async -> CVPixelBuffer? {
        do {
            // SCShareableContent.current must be called from the main actor
            // per Apple's documentation; failing to do so can produce stale
            // window lists or spurious authorization failures.
            let content = try await Task { @MainActor in try await SCShareableContent.current }.value
            let midPoint = CGPoint(x: appKitRect.midX, y: appKitRect.midY)

            guard let display = content.displays.first(where: { $0.frame.contains(midPoint) })
                    ?? content.displays.first else { return nil }

            // Convert global AppKit rect → display-local CG rect.
            // Use NSScreen (AppKit coords) for ALL coordinate math to
            // avoid the NSScreen.frame (bottom-left origin) vs
            // SCDisplay.frame (top-left origin) mismatch that causes
            // capture-region offset on non-primary displays.
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(midPoint) })
                    ?? NSScreen.main else { return nil }
            let screenFrame = screen.frame
            let scale = screen.backingScaleFactor

            let localAppKitX = appKitRect.origin.x - screenFrame.origin.x
            let localAppKitY = appKitRect.origin.y - screenFrame.origin.y
            // Y-flip within this single screen's frame — no cross-coordinate-system arithmetic
            let localCGY = screenFrame.height - localAppKitY - appKitRect.height
            let sourceRect = CGRect(
                x: localAppKitX, y: localCGY,
                width: appKitRect.width, height: appKitRect.height
            )

            let excluded = content.windows.filter { $0.windowID == excludingWindowID }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)

            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.sourceRect = sourceRect
            config.width  = Int(sourceRect.width * scale)
            config.height = Int(sourceRect.height * scale)
            config.queueDepth = 1

            print("[OCR] Capturing region=local\(sourceRect) scale=\(scale) output=\(config.width)×\(config.height) screen=\(screenFrame)")

            return try await captureSingleFrame(filter: filter, configuration: config)
        } catch let error as SCStreamError {
            // SCStreamError: -3808 = user-declined screen capture permission;
            // -3815 = stream already started; others = transient.
            let code = error.code
            if code.rawValue == -3808 {
                print("[SCK] Screen Recording permission denied — grant in System Settings → Privacy → Screen Recording")
            } else {
                print("[SCK] Stream error \(code.rawValue): \(error.localizedDescription)")
            }
            return nil
        } catch {
            print("[SCK] Capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Creates an ephemeral `SCStream`, attaches a single-shot output handler,
    /// starts the stream, waits for the first `CVPixelBuffer`, then stops.
    ///
    /// Wrapped in a 3-second timeout — if `SCStream.startCapture()` succeeds
    /// but never produces a frame (known SCK issue during display topology
    /// changes, GPU starvation, or window-server congestion), the continuation
    /// is resumed with `nil` rather than hanging the calling `Task` forever.
    private func captureSingleFrame(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CVPixelBuffer? {
        let streamOutput = SingleFrameStreamOutput()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()

        return try await withThrowingTaskGroup(of: CVPixelBuffer?.self) { group in
            // Frame task — resumes when the first buffer arrives (or on error)
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CVPixelBuffer?, Error>) in
                    streamOutput.onFrame = { @Sendable buffer in
                        continuation.resume(returning: buffer)
                    }
                    streamOutput.onError = { error in
                        continuation.resume(throwing: error)
                    }
                    streamOutput.stream = stream
                }
            }

            // Timeout task — fires after 3 s (was 1.5s — M1 SCStream
            // need more time during display congestion)
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                print("[OCR] ⏱ Frame capture timed out after 3.0s")
                // Stop the stream best-effort; don't wait for completion
                Task { try? await stream.stopCapture() }
                return nil
            }

            // Return whichever completes first
            let result = try await group.next() ?? nil
            group.cancelAll()

            // Fire-and-forget stream teardown — stopCapture() can block
            // indefinitely on some macOS versions; we never await it.
            Task.detached { try? await stream.stopCapture() }

            return result
        }
    }
}

// MARK: - Single-Frame SCStreamOutput

/// Captures the first `CVPixelBuffer` from an `SCStream` and fires the
/// completion callback exactly once, then stops the stream.
///
/// Uses `@unchecked Sendable` with internal synchronization via an
/// `NSLock`-guarded flag to satisfy Swift 6 concurrency safety while
/// allowing the mutable state required by the `SCStreamOutput` delegate
/// pattern.  `markFired()` performs an atomic check-and-set so that
/// `didOutputSampleBuffer` and `didStopWithError` cannot both resume
/// the continuation.
private final class SingleFrameStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    nonisolated(unsafe) var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    nonisolated(unsafe) var onError: (@Sendable (Error) -> Void)?
    nonisolated(unsafe) var stream: SCStream?

    private nonisolated(unsafe) var _hasFired = false
    private let _lock = NSLock()

    /// Atomically checks whether the output has already fired.
    /// Returns `true` if it has; otherwise sets the flag and returns `false`.
    private func markFired() -> Bool {
        _lock.lock()
        defer { _lock.unlock() }
        if _hasFired { return true }
        _hasFired = true
        return false
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard !markFired() else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            onError?(NSError(domain: "SCK", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No pixel buffer in sample"]))
            return
        }

        let buffer = pixelBuffer
        // Fire-and-forget stopCapture — SCStream.stopCapture() can block
        // indefinitely on certain macOS versions; we never await it.
        Task.detached { try? await stream.stopCapture() }
        onFrame?(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !markFired() else { return }
        onError?(error)
    }
}

// MARK: - Capture Service Factory

enum CaptureServiceFactory {
    static func makeService() -> CaptureServiceProtocol {
        ScreenCaptureService()
    }
}
