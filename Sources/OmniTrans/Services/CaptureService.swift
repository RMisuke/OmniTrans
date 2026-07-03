import Cocoa
import ScreenCaptureKit

// MARK: - Capture Service Protocol

protocol CaptureServiceProtocol {
    func capture(appKitRect: CGRect, excludingWindowID: CGWindowID) async -> CGImage?
}

// MARK: - ScreenCaptureKit (macOS 15+) — sourceRect zero-copy

/// Uses `SCStreamConfiguration.sourceRect` so the system returns a pre-cropped
/// `CGImage` at exactly the selection size.  No manual pixel scaling, no Y-flip
/// math — ScreenCaptureKit handles everything in hardware.
@available(macOS 15.0, *)
final class ScreenCaptureKitCaptureService: CaptureServiceProtocol {
    func capture(appKitRect: CGRect, excludingWindowID: CGWindowID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.current
            let midPoint = CGPoint(x: appKitRect.midX, y: appKitRect.midY)

            guard let display = content.displays.first(where: { $0.frame.contains(midPoint) })
                    ?? content.displays.first else { return nil }

            // Find matching NSScreen for precise Y-axis conversion
            let screen = NSScreen.screens.first { $0.frame == display.frame }
                ?? NSScreen.screens.first { $0.frame.contains(midPoint) }
                ?? NSScreen.main

            // Convert global AppKit rect → display-local CG rect
            let displayOrigin = display.frame.origin
            let displayHeight  = display.frame.height

            let localX = appKitRect.origin.x - displayOrigin.x
            let localY = appKitRect.origin.y - displayOrigin.y
            // Y-flip: AppKit bottom-left → CG top-left (within the display's own coords)
            let cgY = displayHeight - (localY + appKitRect.height)

            let sourceRect = CGRect(
                x: localX,
                y: cgY,
                width: appKitRect.width,
                height: appKitRect.height
            )

            let excluded = content.windows.filter { $0.windowID == excludingWindowID }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)

            let config = SCStreamConfiguration()
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.sourceRect = sourceRect       // ← kernel-level crop
            config.width  = Int(sourceRect.width)
            config.height = Int(sourceRect.height)

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            print("[SCK] Capture failed: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - CGWindowList (macOS 14 fallback)

final class CGWindowCaptureService: CaptureServiceProtocol {
    func capture(appKitRect: CGRect, excludingWindowID: CGWindowID) async -> CGImage? {
        // CGWindowListCreateImage expects GLOBAL CG screen coordinates
        // (origin at top-left of the main display).
        let cgScreenHeight = NSScreen.screens.map { $0.frame.maxY }.max()
            ?? NSScreen.main?.frame.maxY
            ?? 0
        let cgRect = CGRect(
            x: appKitRect.origin.x,
            y: cgScreenHeight - (appKitRect.origin.y + appKitRect.height),
            width: appKitRect.width,
            height: appKitRect.height
        )

        guard let image = CGWindowListCreateImage(
            cgRect,
            .optionOnScreenOnly,
            excludingWindowID,
            .nominalResolution
        ) else {
            print("[CGWindow] Capture failed")
            return nil
        }
        return image
    }
}

// MARK: - Capture Service Factory

enum CaptureServiceFactory {
    static func makeService() -> CaptureServiceProtocol {
        if #available(macOS 15.0, *) {
            return ScreenCaptureKitCaptureService()
        } else {
            return CGWindowCaptureService()
        }
    }
}
