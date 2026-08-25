import AppKit
import CoreGraphics
import ScreenCaptureKit

// MARK: - 屏幕坐标系统一转换层（多屏安全）

/// 屏幕坐标系统一转换层 —— 全应用唯一的跨坐标系换算出口。
///
/// ## 坐标系约定（务必牢记，禁止在调用方混用）
/// - **AppKit 全局坐标**（`NSScreen.frame` / `NSEvent.mouseLocation` / `NSWindow.frame`）：
///   origin 在主屏 **bottom-left**，Y 轴向上。副屏可位于主屏上方（y > 主屏高）、
///   下方（y < 0）、左侧（x < 0）、右侧（x > 主屏宽）。
/// - **CG 全局坐标**（`CGDisplayBounds` / `SCDisplay.frame`）：
///   origin 在主屏 **top-left**，Y 轴向下。
/// - **display-local 坐标**（`SCStreamConfiguration.sourceRect`）：
///   origin 在目标显示器 **top-left**，Y 轴向下。
///
/// 多屏坐标错配（副屏在上/下/左/右取不到字、区域偏移）的根因，就是上述坐标系
/// 之间被直接混用：`SCDisplay.frame`（top-left）与 `NSScreen.frame`（bottom-left）
/// 的 Y 语义相反，`NSScreen.frame`（bottom-left）与 CG 坐标（top-left）也不能直接相减。
///
/// ## 修复要点
/// 1. 屏幕选择统一用 **AppKit 坐标** 匹配 `NSScreen.frame`，再用 `CGDirectDisplayID`
///    精确关联 `SCDisplay`，彻底移除 `SCDisplay.frame.contains()` 这种跨坐标系判断。
/// 2. `AppKit 全局 rect → display-local sourceRect` 在单个屏幕 frame 内完成 Y-flip，
///    兼容负坐标、任意排列方向、混合分辨率/缩放率。
/// 3. 缩放因子动态读取（`SCDisplay.scaleFactor` 优先，回退 `backingScaleFactor`），
///    无任何硬编码缩放值。
/// 4. Vision 归一化区域（origin 左下、y 向上）→ AppKit 全局 rect → 窗口局部 rect，
///    供 OCR 结果区域映射/原位替换/区域定位使用。
public enum DisplayGeometry {

    // MARK: - 屏幕选择（不依赖主屏）

    /// 返回包含给定 **AppKit 全局点** 的屏幕。点永远落在某屏内，正常必有命中。
    public static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// 返回离给定 AppKit 全局点**最近**的屏幕（用于点落在屏间间隙等边界情形），
    /// 彻底消除对 `NSScreen.main` 的依赖。
    public static func nearestScreen(to point: CGPoint) -> NSScreen? {
        NSScreen.screens.min {
            squaredDistance(from: point, to: $0.frame) < squaredDistance(from: point, to: $1.frame)
        }
    }

    /// 点到矩形（屏幕 frame）的平方欧氏距离；点在矩形内为 0。
    /// 纯函数，便于单元测试。
    public static func squaredDistance(from p: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return dx * dx + dy * dy
    }

    // MARK: - NSScreen ↔ CGDirectDisplayID 关联

    /// 从 `NSScreen` 取 `CGDirectDisplayID`（键 `NSScreenNumber`）。
    public static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// 从 `SCShareableContent` 中按 `CGDirectDisplayID` 精确查找 `SCDisplay`。
    /// 用 displayID 关联而非 `SCDisplay.frame.contains()` —— 后者用错坐标系会
    /// 在多屏下回退到主屏，是外接屏失效的根因。
    public static func scDisplay(in content: SCShareableContent,
                                 matching displayID: CGDirectDisplayID) -> SCDisplay? {
        content.displays.first { $0.displayID == displayID }
    }

    // MARK: - AppKit 全局 ↔ CG 全局

    /// AppKit 全局坐标系（bottom-left）的顶边 = 所有屏幕 `frame.maxY` 的最大值。
    /// 这是把 AppKit 全局坐标翻转为 CG 全局坐标（top-left）的基准。
    public static func appKitGlobalTop(screens: [NSScreen] = NSScreen.screens) -> CGFloat {
        screens.map { $0.frame.maxY }.max() ?? 0
    }

    /// AppKit 全局点 → CG 全局点（X 不变，Y 翻转）。
    /// 纯函数：`globalTop` 显式传入，便于单元测试模拟任意布局。
    public static func cgPoint(fromAppKit p: CGPoint, globalTop top: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: top - p.y)
    }

    /// AppKit 全局 rect → CG 全局 rect。
    public static func cgRect(fromAppKit r: CGRect, globalTop top: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }

    // MARK: - AppKit 全局 rect → display-local sourceRect

    /// 把 **AppKit 全局 rect**（bottom-left）转为目标屏幕的 **display-local rect**
    /// （top-left，供 `SCStreamConfiguration.sourceRect` 使用）。
    ///
    /// 纯函数：`screenFrame` 传该屏幕的 `NSScreen.frame` 即可，便于单元测试
    /// 模拟副屏位于主屏上/下/左/右、负坐标、不同分辨率/缩放率的全部场景。
    ///
    /// 数学推导（screenFrame = (sx, sy, sw, sh)，sy 为 AppKit bottom-left 全局 y）：
    /// ```
    /// localX        = rect.minX - sx                          // X 两坐标系同向，直接减
    /// localBottomY  = rect.minY - sy                          // 屏内 bottom-left y
    /// localTopY     = sh - localBottomY - rect.height        // 屏内 Y-flip → top-left
    /// ```
    public static func displayLocalSourceRect(forAppKitGlobal rect: CGRect,
                                              screenFrame: CGRect) -> CGRect {
        let localX = rect.minX - screenFrame.minX
        let localBottomY = rect.minY - screenFrame.minY
        let localTopY = screenFrame.height - localBottomY - rect.height
        return CGRect(x: localX, y: localTopY, width: rect.width, height: rect.height)
    }

    // MARK: - 缩放因子

    /// 屏幕缩放因子（物理像素 / 逻辑点）。
    ///
    /// 优先使用 `SCDisplay.width / SCDisplay.frame.width` —— 物理像素与逻辑点
    /// 之比，与 SCK 输出缓冲区严格一致（覆盖 Retina、缩放布局、混合缩放率）。
    /// 回退到 `NSScreen.backingScaleFactor`，再回退 1.0。无任何硬编码缩放值。
    public static func scaleFactor(for display: SCDisplay?, screen: NSScreen) -> CGFloat {
        if let display, display.frame.width > 0 {
            let fromSC = CGFloat(display.width) / display.frame.width
            if fromSC > 0 { return fromSC }
        }
        let fromScreen = screen.backingScaleFactor
        return fromScreen > 0 ? fromScreen : 1.0
    }

    /// 把 display-local sourceRect（逻辑点）换算为输出像素尺寸，供
    /// `SCStreamConfiguration.width/height` 使用。四舍五入并钳制 ≥ 1，避免
    /// `Int()` 截断带来的 1px 输出偏移。
    public static func outputPixelSize(forLocalRect rect: CGRect,
                                       scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int((rect.width * scale).rounded())),
         max(1, Int((rect.height * scale).rounded())))
    }

    // MARK: - Vision normalized → 屏幕坐标

    /// 把 Vision 的 **normalized boundingBox**（origin 左下、Y 向上、0~1，相对整幅捕获图）
    /// 映射为屏幕上的 **AppKit 全局 rect**（bottom-left）。
    ///
    /// 推导：图像物理像素 W×H = appKitRect.size × scale；归一化坐标（左下）乘以
    /// 物理像素得像素坐标（左下），再除以 scale 得逻辑点（左下），最后平移到
    /// `appKitRect` 全局 origin。scale 在推导中约去：
    /// `ptX = nx × appKitRect.width`，`ptY = ny × appKitRect.height`。
    ///
    /// - Parameters:
    ///   - normalized: Vision 输出区域（`VNRecognizedTextObservation.boundingBox`）。
    ///   - appKitRect: 捕获时使用的 AppKit 全局区域（bottom-left）。
    public static func appKitGlobalRect(fromVisionNormalized normalized: CGRect,
                                        within appKitRect: CGRect) -> CGRect {
        CGRect(x: appKitRect.minX + normalized.minX * appKitRect.width,
               y: appKitRect.minY + normalized.minY * appKitRect.height,
               width: normalized.width * appKitRect.width,
               height: normalized.height * appKitRect.height)
    }

    /// AppKit 全局 rect → 目标窗口局部坐标（供原位替换/区域定位）。
    /// `windowFrame` 为目标窗口的 `NSWindow.frame`（AppKit 全局 bottom-left）。
    public static func windowLocalRect(fromAppKitGlobal rect: CGRect,
                                       windowFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX - windowFrame.minX,
               y: rect.minY - windowFrame.minY,
               width: rect.width, height: rect.height)
    }

    // MARK: - 诊断输出

    /// 汇总一块屏幕的几何信息，供 `[OCR]` 诊断日志与多屏集成验证使用。
    public static func describe(screen: NSScreen, display: SCDisplay?) -> String {
        let id = displayID(for: screen).map { String($0) } ?? "?"
        var parts = ["frame=\(screen.frame)",
                     "scale=\(screen.backingScaleFactor)",
                     "id=\(id)"]
        if let display, display.frame.width > 0 {
            parts += ["scFrame=\(display.frame)",
                      "scScale=\(String(format: "%.2f", CGFloat(display.width) / display.frame.width))"]
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - 显示布局诊断工具

/// 打印当前显示拓扑（NSScreen + SCDisplay + displayID 关联），
/// 供多屏集成验证：确认各屏 frame / 缩放率，以及 NSScreen ↔ SCDisplay
/// 是否能按 `CGDirectDisplayID` 精确关联（修复后应全部 matched）。
public enum DisplayLayoutDebug {

    /// 向控制台输出完整显示拓扑。读取 `SCShareableContent` 需要屏幕录制权限。
    @MainActor
    public static func dump() async {
        print("=== [DisplayLayout] NSScreen (AppKit, bottom-left) ===")
        for screen in NSScreen.screens {
            print("  NSScreen \(DisplayGeometry.describe(screen: screen, display: nil))")
        }
        do {
            let content = try await SCShareableContent.current
            print("=== [DisplayLayout] SCDisplay (CG, top-left) ===")
            for display in content.displays {
                let scale = display.frame.width > 0 ? CGFloat(display.width) / display.frame.width : 1
                print("  SCDisplay id=\(display.displayID) frame=\(display.frame) pixel=\(display.width)×\(display.height) scale=\(String(format: "%.2f", scale))")
            }
            print("=== [DisplayLayout] NSScreen ↔ SCDisplay 关联（按 CGDirectDisplayID）===")
            for screen in NSScreen.screens {
                let id = DisplayGeometry.displayID(for: screen)
                let matched = id.flatMap { DisplayGeometry.scDisplay(in: content, matching: $0) }
                print("  \(DisplayGeometry.describe(screen: screen, display: matched)) -> \(matched != nil ? "✅ matched" : "❌ NOT FOUND")")
            }
        } catch {
            print("[DisplayLayout] ⚠️ 读取 SCShareableContent 失败（需要屏幕录制权限）：\(error.localizedDescription)")
        }
    }
}
