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
            let content = try await SCShareableContent.current
            let midPoint = CGPoint(x: appKitRect.midX, y: appKitRect.midY)

            guard let display = content.displays.first(where: { $0.frame.contains(midPoint) })
                    ?? content.displays.first else { return nil }

            // Convert global AppKit rect → display-local CG rect
            let displayOrigin = display.frame.origin
            let displayHeight  = display.frame.height

            let localX = appKitRect.origin.x - displayOrigin.x
            let localY = appKitRect.origin.y - displayOrigin.y
            // Y-flip: AppKit bottom-left → CG top-left
            let cgY = displayHeight - (localY + appKitRect.height)

            let sourceRect = CGRect(
                x: localX, y: cgY,
                width: appKitRect.width, height: appKitRect.height
            )

            let excluded = content.windows.filter { $0.windowID == excludingWindowID }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)

            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.sourceRect = sourceRect
            config.width  = Int(sourceRect.width)
            config.height = Int(sourceRect.height)
            config.queueDepth = 1

            return try await captureSingleFrame(filter: filter, configuration: config)
        } catch {
            print("[SCK] Capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Creates an ephemeral `SCStream`, attaches a single-shot output handler,
    /// starts the stream, waits for the first `CVPixelBuffer`, then stops.
    private func captureSingleFrame(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CVPixelBuffer? {
        let streamOutput = SingleFrameStreamOutput()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()

        // Wait for the first frame (or error) with a continuation
        return try await withCheckedThrowingContinuation { continuation in
            streamOutput.onFrame = { buffer in
                continuation.resume(returning: buffer)
            }
            streamOutput.onError = { error in
                continuation.resume(throwing: error)
            }
            // Stream teardown happens inside the callbacks
            streamOutput.stream = stream
        }
    }
}

// MARK: - Single-Frame SCStreamOutput

/// Captures the first `CVPixelBuffer` from an `SCStream` and fires the
/// completion callback exactly once, then stops the stream.
///
/// Uses `@unchecked Sendable` with internal synchronization via a
/// `OSAllocatedUnfairLock`-guarded flag to satisfy Swift 6 concurrency
/// safety while allowing the mutable `hasFired` state required by the
/// `SCStreamOutput` delegate pattern.
private final class SingleFrameStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    var stream: SCStream?

    private nonisolated(unsafe) var _hasFired = false
    private let _lock = NSLock()

    private var hasFired: Bool {
        get { _lock.withLock { _hasFired } }
        set { _lock.withLock { _hasFired = newValue } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard !hasFired else { return }
        hasFired = true

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            onError?(NSError(domain: "SCK", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No pixel buffer in sample"]))
            return
        }

        // Stop the stream asynchronously, then deliver the buffer.
        // The pixel buffer is retained by the sample buffer's lifetime;
        // we deliver it before the stream fully stops to avoid pool teardown.
        let buffer = pixelBuffer
        Task {
            try? await stream.stopCapture()
            self.onFrame?(buffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !hasFired else { return }
        hasFired = true
        onError?(error)
    }
}

// MARK: - Capture Service Factory

enum CaptureServiceFactory {
    static func makeService() -> CaptureServiceProtocol {
        ScreenCaptureService()
    }
}
