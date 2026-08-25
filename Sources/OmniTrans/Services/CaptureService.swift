import Cocoa
@preconcurrency import ScreenCaptureKit
@preconcurrency import CoreVideo
import os
import DisplayGeometry

// MARK: - Capture Service Protocol

protocol CaptureServiceProtocol: Sendable {
    /// Captures a screen region and returns the raw `CVPixelBuffer` for
    /// zero-copy handoff to Vision.  Callers must lock the buffer (read-only)
    /// for the duration of Vision processing and unlock immediately after.
    func capture(appKitRect: CGRect, excludingWindowID: CGWindowID) async -> CVPixelBuffer?
}

// MARK: - Shareable Content Cache

/// 缓存 `SCShareableContent` —— 该枚举调用是 ScreenCaptureKit 最昂贵的同步操作
/// （需向 WindowServer 枚举全部窗口/显示器，典型耗时 100–500ms），每次截图都重新
/// 枚举是 OCR 首帧延迟的最大来源（审计 A1）。
///
/// 失效策略：
/// 1. **屏幕拓扑变化** —— 监听 `NSApplication.didChangeScreenParametersNotification`
///    （插拔显示器 / 分辨率调整 / Space 切换布局变化）立即失效。
/// 2. **TTL 兜底** —— 30 秒后过期，防止未覆盖到的窗口列表漂移
///    （如目标窗口在两次 OCR 之间被关闭导致 excludingWindows 匹配失败——
///     该情况只影响排除列表，不影响 display 关联，故长 TTL 安全）。
actor SCShareableContentCache {
    static let shared = SCShareableContentCache()

    private var cached: SCShareableContent?
    private var cachedAt: ContinuousClock.Instant = .now
    private var observer: (any NSObjectProtocol)?

    /// 缓存有效期。display/window 拓扑由通知失效兜底，TTL 仅作保险。
    private static let ttl: Duration = .seconds(30)

    nonisolated private static let log = OSLog(subsystem: AppLogging.subsystem, category: "Capture")

    func content() async throws -> SCShareableContent {
        // 命中且未过期 → 直接返回（亚毫秒级）
        if let cached, cachedAt.duration(to: .now) < Self.ttl {
            return cached
        }

        // 未命中 → 重新枚举。
        // Apple 文档要求该调用在主线程上下文执行，否则可能拿到过期的
        // 窗口列表或伪授权失败；此处 actor 非主线程，故 hop 到 MainActor。
        let fresh = try await Task { @MainActor in try await SCShareableContent.current }.value
        cached = fresh
        cachedAt = .now
        installObserverIfNeeded()
        return fresh
    }

    /// 屏幕参数变化时清空缓存（下一次捕获触发重新枚举）。
    private func installObserverIfNeeded() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.invalidate() }
        }
    }

    func invalidate() {
        cached = nil
    }
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

    nonisolated private static let log = OSLog(subsystem: AppLogging.subsystem, category: "Capture")

    func capture(appKitRect: CGRect, excludingWindowID: CGWindowID) async -> CVPixelBuffer? {
        do {
            // ── 使用缓存的 shareable content（审计 A1：省去每帧全量枚举）──
            let content = try await SCShareableContentCache.shared.content()

            // ── 屏幕选择：AppKit 坐标匹配 NSScreen.frame（bottom-left 一致）──
            // 绝不用 SCDisplay.frame.contains() 判断 —— 那是 top-left CG 坐标，
            // 与 AppKit 坐标混用会令外接屏（上/下/左/右）回退到主屏。
            let midPoint = CGPoint(x: appKitRect.midX, y: appKitRect.midY)
            guard let screen = DisplayGeometry.screen(containing: midPoint)
                    ?? DisplayGeometry.nearestScreen(to: midPoint) else { return nil }

            // ── 用 CGDirectDisplayID 精确关联 SCDisplay，杜绝坐标系错配 ──
            guard let displayID = DisplayGeometry.displayID(for: screen),
                  let display = DisplayGeometry.scDisplay(in: content, matching: displayID)
            else { return nil }

            // ── 统一坐标转换：AppKit 全局 → display-local（top-left）──
            // DisplayGeometry 在单个屏幕 frame 内完成 Y-flip，兼容负坐标与
            // 任意排列方向；缩放因子动态读取 SCDisplay.scaleFactor。
            let scale = DisplayGeometry.scaleFactor(for: display, screen: screen)
            let sourceRect = DisplayGeometry.displayLocalSourceRect(forAppKitGlobal: appKitRect,
                                                                    screenFrame: screen.frame)
            let pixel = DisplayGeometry.outputPixelSize(forLocalRect: sourceRect, scale: scale)

            let excluded = content.windows.filter { $0.windowID == excludingWindowID }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)

            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.sourceRect = sourceRect
            config.width  = pixel.width
            config.height = pixel.height
            config.queueDepth = 1
            // 不捕获音频通道（默认即无，显式声明避免系统默认值漂移带来的额外开销）
            config.capturesAudio = false

            os_log(.debug, log: Self.log, "OCR capture region=local%@ scale=%.2f output=%dx%d",
                   NSStringFromRect(sourceRect), scale, pixel.width, pixel.height)

            return try await captureSingleFrame(filter: filter, configuration: config)
        } catch let error as SCStreamError {
            // SCStreamError: -3808 = user-declined screen capture permission;
            // -3815 = stream already started; others = transient.
            let code = error.code
            if code.rawValue == -3808 {
                os_log(.error, log: Self.log, "Screen Recording permission denied — grant in System Settings → Privacy → Screen Recording")
            } else {
                os_log(.error, log: Self.log, "Stream error %d: %@", code.rawValue, error.localizedDescription)
            }
            return nil
        } catch {
            os_log(.error, log: Self.log, "Capture failed: %@", error.localizedDescription)
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

        // 任务组元素类型用 `PixelBufferBox?`（Sendable），避免 CVBuffer 非 Sendable
        // 导致的 TaskGroup 关联类型告警；最终经 `result?.value` 解包回 CVPixelBuffer。
        return try await withThrowingTaskGroup(of: PixelBufferBox?.self) { group in
            // Frame task — resumes when the first buffer arrives (or on error)
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PixelBufferBox?, Error>) in
                    streamOutput.onFrame = { @Sendable box in
                        continuation.resume(returning: box)
                    }
                    streamOutput.onError = { error in
                        continuation.resume(throwing: error)
                    }
                    streamOutput.stream = stream
                }
            }

            // Timeout task — fires after 3 s (was 1.5s — M1 SCStream
            // need more time during display congestion)
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                os_log(.debug, log: Self.log, "Frame capture timed out after 3.0s")
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

            return result?.value
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
    nonisolated(unsafe) var onFrame: (@Sendable (PixelBufferBox) -> Void)?
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

        // Fire-and-forget stopCapture — SCStream.stopCapture() can block
        // indefinitely on certain macOS versions; we never await it.
        Task.detached { try? await stream.stopCapture() }
        // CVBuffer 非 Sendable：经 PixelBufferBox 包装后跨线程传递（审计并发告警）。
        onFrame?(PixelBufferBox(pixelBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !markFired() else { return }
        onError?(error)
    }
}

/// CVBuffer（`CVPixelBuffer`）非 Sendable 的显式包装：由调用方保证在跨线程
/// 回调期间缓冲区生命周期有效（消除 `@Sendable` 闭包捕获告警）。
private final class PixelBufferBox: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}

// MARK: - Capture Service Factory

enum CaptureServiceFactory {
    static func makeService() -> CaptureServiceProtocol {
        ScreenCaptureService()
    }
}
