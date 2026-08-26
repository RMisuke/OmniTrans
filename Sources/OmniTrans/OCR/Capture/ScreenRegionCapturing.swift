import Cocoa
@preconcurrency import ScreenCaptureKit
@preconcurrency import CoreVideo
import os
import DisplayGeometry

// MARK: - 区域捕获协议

/// 屏幕区域捕获抽象 —— 把「屏幕像素 → CVPixelBuffer」与识别引擎解耦，
/// 便于测试注入 mock 与未来替换捕获后端（如多显示器独立流）。
protocol ScreenRegionCapturing: Sendable {
    /// 捕获一块屏幕区域，返回 BGRA `CVPixelBuffer` 供零拷贝直通 Vision。
    ///
    /// - Parameters:
    ///   - appKitRect: **AppKit 全局坐标**（bottom-left）的目标区域。
    ///   - excludingWindowID: 从捕获中排除的窗口（OCR 框选 overlay 自身）。
    /// - Returns: BGRA 像素缓冲；失败返回 nil（权限缺失/拓扑变化等）。
    func capture(appKitRect: CGRect, excludingWindowID: CGWindowID) async -> CVPixelBuffer?
}

// MARK: - Shareable Content Cache

/// 缓存 `SCShareableContent` —— 该枚举调用是 ScreenCaptureKit 最昂贵的同步操作
/// （需向 WindowServer 枚举全部窗口/显示器，典型耗时 100–500ms）。
///
/// 失效策略：
/// 1. **屏幕拓扑变化** —— 监听 `NSApplication.didChangeScreenParametersNotification`
///    （插拔显示器 / 分辨率调整 / Space 切换布局变化）立即失效。
/// 2. **TTL 兜底** —— 30 秒后过期，防止未覆盖到的窗口列表漂移。
actor SCContentCache {
    static let shared = SCContentCache()

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

// MARK: - SCStream Single-Frame Capture

/// 基于 `SCStream` + 自定义 `SCStreamOutput` 的单帧区域捕获实现。
///
/// 与旧实现的差异：仅去掉 `CaptureServiceProtocol` 工厂壳，核心路径不变 ——
/// 单帧流直出 `CVPixelBuffer`（BGRA），完全绕开 `CGImage` 路径的 CPU 端
/// 像素拷贝/色彩空间转换，零拷贝交接给 Vision。
final class SCStreamRegionCapture: ScreenRegionCapturing {

    nonisolated private static let log = OSLog(subsystem: AppLogging.subsystem, category: "Capture")

    func capture(appKitRect: CGRect, excludingWindowID: CGWindowID) async -> CVPixelBuffer? {
        do {
            // ── 使用缓存的 shareable content（省去每帧全量枚举）──
            let content = try await SCContentCache.shared.content()

            // ── 屏幕选择：AppKit 坐标匹配 NSScreen.frame（bottom-left 一致）──
            // 绝不用 SCDisplay.frame.contains() 判断 —— 那是 top-left CG 坐标，
            // 与 AppKit 坐标混用会令外接屏回退到主屏。
            let midPoint = CGPoint(x: appKitRect.midX, y: appKitRect.midY)
            guard let screen = DisplayGeometry.screen(containing: midPoint)
                    ?? DisplayGeometry.nearestScreen(to: midPoint) else { return nil }

            // ── 用 CGDirectDisplayID 精确关联 SCDisplay，杜绝坐标系错配 ──
            guard let displayID = DisplayGeometry.displayID(for: screen),
                  let display = DisplayGeometry.scDisplay(in: content, matching: displayID)
            else { return nil }

            // ── 统一坐标转换：AppKit 全局 → display-local（top-left）──
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
            config.capturesAudio = false

            os_log(.debug, log: Self.log, "OCR capture region=local%@ scale=%.2f output=%dx%d",
                   NSStringFromRect(sourceRect), scale, pixel.width, pixel.height)

            return try await captureSingleFrame(filter: filter, configuration: config)
        } catch let error as SCStreamError {
            // -3808 = user-declined screen capture permission; -3815 = stream already started.
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

    /// 创建临时 `SCStream`，等待首帧 `CVPixelBuffer` 后停止流。
    ///
    /// 包裹 3 秒超时 —— 若 `startCapture()` 成功但始终无帧（显示器拓扑变化 /
    /// GPU 饥饿期间已知的 SCK 问题），continuation 以 nil 收尾而非永久挂起。
    private func captureSingleFrame(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CVPixelBuffer? {
        let streamOutput = SingleFrameStreamOutput()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()

        return try await withThrowingTaskGroup(of: PixelBufferBox?.self) { group in
            // 帧任务：首帧到达（或出错）即恢复
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

            // 超时任务：3s 无帧则放弃（M1 在显示拥塞期需要更多时间）
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                os_log(.debug, log: Self.log, "Frame capture timed out after 3.0s")
                Task { try? await stream.stopCapture() }
                return nil
            }

            // 返回先完成者
            let result = try await group.next() ?? nil
            group.cancelAll()

            // Fire-and-forget 流销毁 —— stopCapture() 在部分 macOS 版本上可能无限阻塞。
            Task.detached { try? await stream.stopCapture() }

            return result?.value
        }
    }
}

// MARK: - Single-Frame SCStreamOutput

/// 捕获 `SCStream` 首帧 `CVPixelBuffer` 并精确触发一次回调后停止流。
private final class SingleFrameStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    nonisolated(unsafe) var onFrame: (@Sendable (PixelBufferBox) -> Void)?
    nonisolated(unsafe) var onError: (@Sendable (Error) -> Void)?
    nonisolated(unsafe) var stream: SCStream?

    private nonisolated(unsafe) var _hasFired = false
    private let _lock = NSLock()

    /// 原子 check-and-set：`didOutputSampleBuffer` 与 `didStopWithError` 不可能同时 resume。
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

        // stopCapture 可能无限阻塞 —— fire-and-forget，永不 await。
        Task.detached { try? await stream.stopCapture() }
        onFrame?(PixelBufferBox(pixelBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !markFired() else { return }
        onError?(error)
    }
}

// MARK: - CVBuffer Sendable Box

/// CVBuffer（`CVPixelBuffer`）非 Sendable 的显式包装：由调用方保证在跨线程
/// 回调期间缓冲区生命周期有效。
///
/// 仅在捕获层内部使用；新 Vision Swift API 的 async `perform(on:)` 路径
/// 不再需要手工包装（框架自身保证缓冲区在请求生命周期内有效）。
final class PixelBufferBox: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}
