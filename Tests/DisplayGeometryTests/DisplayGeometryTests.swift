import XCTest
import CoreGraphics
@testable import DisplayGeometry

/// 多屏坐标转换单元测试 —— 覆盖外接屏位于主屏上/下/左/右、负坐标区域、
/// 双外接、不同分辨率/缩放率组合，以及 Vision 归一化坐标 → 屏幕坐标映射。
///
/// 所有场景均为纯几何推演（不依赖真实硬件），通过显式传入 `screenFrame`
/// 模拟任意显示布局。
final class DisplayGeometryTests: XCTestCase {

    // MARK: - 布局模型（AppKit 全局坐标，bottom-left origin）

    /// 主屏（内屏）：1440×900，Retina 2x
    private let mainScreen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// 外接屏：1920×1080，非 Retina（1x）—— 混合缩放率
    private let ext1080 = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // MARK: - 1. 外接屏位于主屏右侧

    func testExternalOnRight() {
        // 主屏 (0,0,1440,900)，外接在右侧 (1440,0,1920,1080)，顶部对齐
        let rightScreen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        // 外接屏内、AppKit 全局的一个框选区域
        let appKitRect = CGRect(x: 1600, y: 200, width: 400, height: 100)

        let local = DisplayGeometry.displayLocalSourceRect(forAppKitGlobal: appKitRect,
                                                           screenFrame: rightScreen)

        // X：1600 - 1440 = 160
        XCTAssertEqual(local.minX, 160, accuracy: 0.001)
        // 屏内 bottom-left y = 200，翻转后 top-left y = 1080 - 200 - 100 = 780
        XCTAssertEqual(local.minY, 780, accuracy: 0.001)
        XCTAssertEqual(local.width, 400, accuracy: 0.001)
        XCTAssertEqual(local.height, 100, accuracy: 0.001)
        // sourceRect 必须落在该屏 display-local 范围内
        XCTAssertTrue(rightScreen.contains(CGRect(x: local.minX + rightScreen.minX,
                                                  y: local.minY + rightScreen.minY,
                                                  width: local.width, height: local.height)))
        // 在屏内
        XCTAssertGreaterThanOrEqual(local.minX, 0)
        XCTAssertLessThanOrEqual(local.maxX, rightScreen.width)
        XCTAssertGreaterThanOrEqual(local.minY, 0)
        XCTAssertLessThanOrEqual(local.maxY, rightScreen.height)
    }

    // MARK: - 2. 外接屏位于主屏左侧（负 X 坐标区域）

    func testExternalOnLeft() {
        // 外接屏在左侧 (-1920,0,1920,1080)，主屏在右侧
        let leftScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        // AppKit 全局负坐标区域内的框选
        let appKitRect = CGRect(x: -1600, y: 200, width: 400, height: 100)

        let local = DisplayGeometry.displayLocalSourceRect(forAppKitGlobal: appKitRect,
                                                           screenFrame: leftScreen)

        // X：-1600 - (-1920) = 320
        XCTAssertEqual(local.minX, 320, accuracy: 0.001)
        // Y 翻转与屏高有关：1080 - 200 - 100 = 780
        XCTAssertEqual(local.minY, 780, accuracy: 0.001)
        XCTAssertEqual(local.width, 400, accuracy: 0.001)
        XCTAssertEqual(local.height, 100, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(local.minX, 0)
        XCTAssertLessThanOrEqual(local.maxX, leftScreen.width)
    }

    // MARK: - 3. 外接屏位于主屏上方（Y > 主屏高度）

    func testExternalAbove() {
        // 外接屏在主屏上方 (0,900,1920,1080)，AppKit y 范围 [900, 1980]
        let aboveScreen = CGRect(x: 0, y: 900, width: 1920, height: 1080)
        let appKitRect = CGRect(x: 100, y: 950, width: 400, height: 100)

        let local = DisplayGeometry.displayLocalSourceRect(forAppKitGlobal: appKitRect,
                                                           screenFrame: aboveScreen)

        // X：100 - 0 = 100
        XCTAssertEqual(local.minX, 100, accuracy: 0.001)
        // 屏内 bottom-left y = 950 - 900 = 50；top-left y = 1080 - 50 - 100 = 930
        XCTAssertEqual(local.minY, 930, accuracy: 0.001)
        XCTAssertEqual(local.width, 400, accuracy: 0.001)
        XCTAssertEqual(local.height, 100, accuracy: 0.001)
    }

    // MARK: - 4. 外接屏位于主屏下方（负 Y 坐标区域）

    func testExternalBelow() {
        // 外接屏在主屏下方 (0,-1080,1920,1080)，AppKit y 范围 [-1080, 0]
        let belowScreen = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let appKitRect = CGRect(x: 100, y: -1000, width: 400, height: 100)

        let local = DisplayGeometry.displayLocalSourceRect(forAppKitGlobal: appKitRect,
                                                           screenFrame: belowScreen)

        // X：100 - 0 = 100
        XCTAssertEqual(local.minX, 100, accuracy: 0.001)
        // 屏内 bottom-left y = -1000 - (-1080) = 80；top-left y = 1080 - 80 - 100 = 900
        XCTAssertEqual(local.minY, 900, accuracy: 0.001)
        XCTAssertEqual(local.width, 400, accuracy: 0.001)
        XCTAssertEqual(local.height, 100, accuracy: 0.001)
    }

    // MARK: - 5. 双外接（主屏 + 右侧 + 上方，混合分辨率）

    func testDualExternal() {
        // 主屏 (0,0,1440,900) + 右侧 (1440,0,1920,1080) + 上方 (0,900,2560,1440)
        let rightScreen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let aboveScreen = CGRect(x: 0, y: 900, width: 2560, height: 1440)

        // 右侧屏内
        let rLocal = DisplayGeometry.displayLocalSourceRect(
            forAppKitGlobal: CGRect(x: 1500, y: 100, width: 300, height: 80),
            screenFrame: rightScreen)
        XCTAssertEqual(rLocal.minX, 60, accuracy: 0.001)
        XCTAssertEqual(rLocal.minY, 1080 - 100 - 80, accuracy: 0.001)

        // 上方屏内（更大分辨率）
        let aLocal = DisplayGeometry.displayLocalSourceRect(
            forAppKitGlobal: CGRect(x: 200, y: 1000, width: 500, height: 120),
            screenFrame: aboveScreen)
        XCTAssertEqual(aLocal.minX, 200, accuracy: 0.001)
        XCTAssertEqual(aLocal.minY, 1440 - (1000 - 900) - 120, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(aLocal.maxX, 0)
        XCTAssertLessThanOrEqual(aLocal.maxY, aboveScreen.height)
    }

    // MARK: - 6. 输出像素尺寸（动态缩放因子，无硬编码）

    func testOutputPixelSize() {
        let localRect = CGRect(x: 0, y: 0, width: 400, height: 100)

        // 2x Retina
        let r2 = DisplayGeometry.outputPixelSize(forLocalRect: localRect, scale: 2.0)
        XCTAssertEqual(r2.width, 800)
        XCTAssertEqual(r2.height, 200)

        // 1x
        let r1 = DisplayGeometry.outputPixelSize(forLocalRect: localRect, scale: 1.0)
        XCTAssertEqual(r1.width, 400)
        XCTAssertEqual(r1.height, 100)

        // 非整数缩放（缩放布局，如 1.5）
        let r15 = DisplayGeometry.outputPixelSize(forLocalRect: localRect, scale: 1.5)
        XCTAssertEqual(r15.width, 600)
        XCTAssertEqual(r15.height, 150)

        // 极端小区域不归零
        let tiny = DisplayGeometry.outputPixelSize(forLocalRect: CGRect(x: 0, y: 0, width: 0.4, height: 0.6),
                                                   scale: 2.0)
        XCTAssertGreaterThanOrEqual(tiny.width, 1)
        XCTAssertGreaterThanOrEqual(tiny.height, 1)
    }

    // MARK: - 7. AppKit ↔ CG 全局坐标互转

    func testAppKitToCGConversion() {
        // 主屏(0,0,1440,900) + 外接上(0,900,1920,1080) → 全局顶边 = 1980
        let globalTop: CGFloat = 1980

        // AppKit 全局点 (100, 950)（主屏之上、外接屏内）
        let cgPoint = DisplayGeometry.cgPoint(fromAppKit: CGPoint(x: 100, y: 950),
                                              globalTop: globalTop)
        XCTAssertEqual(cgPoint.x, 100, accuracy: 0.001)
        XCTAssertEqual(cgPoint.y, 1030, accuracy: 0.001) // 1980 - 950

        // AppKit 全局 rect → CG 全局 rect（Y 翻转取 maxY）
        let cgRect = DisplayGeometry.cgRect(fromAppKit: CGRect(x: 100, y: 900, width: 400, height: 100),
                                            globalTop: globalTop)
        XCTAssertEqual(cgRect.minY, 1980 - 1000, accuracy: 0.001) // top - maxY
        XCTAssertEqual(cgRect.minX, 100, accuracy: 0.001)
    }

    // MARK: - 8. Vision 归一化坐标 → AppKit 全局坐标（bottom-left）

    func testVisionNormalizedToAppKit() {
        // 外接屏在右侧，框选区域（AppKit 全局）
        let appKitRect = CGRect(x: 1600, y: 200, width: 400, height: 100)

        // normalized (0.5, 0.25) → 水平中心、离底部 25%
        let normalized = CGRect(x: 0.5, y: 0.25, width: 0.1, height: 0.2)
        let mapped = DisplayGeometry.appKitGlobalRect(fromVisionNormalized: normalized,
                                                      within: appKitRect)

        XCTAssertEqual(mapped.minX, 1600 + 0.5 * 400, accuracy: 0.001)
        XCTAssertEqual(mapped.minY, 200 + 0.25 * 100, accuracy: 0.001)
        XCTAssertEqual(mapped.width, 0.1 * 400, accuracy: 0.001)
        XCTAssertEqual(mapped.height, 0.2 * 100, accuracy: 0.001)
        // 映射结果必须落在原框选区域内部
        XCTAssertTrue(appKitRect.contains(mapped))
    }

    // MARK: - 9. Vision 归一化映射在外接屏各方位下保持正确（含负坐标）

    func testVisionNormalizedAcrossLayouts() {
        // 下方屏（负 Y）框选
        let below = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let sel = CGRect(x: 100, y: -1000, width: 400, height: 100)
        let m1 = DisplayGeometry.appKitGlobalRect(fromVisionNormalized: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                                  within: sel)
        XCTAssertEqual(m1.minX, 100, accuracy: 0.001)
        XCTAssertEqual(m1.minY, -1000, accuracy: 0.001)
        XCTAssertTrue(below.contains(m1))

        // 左侧屏（负 X）框选 —— normalized (0.9, 0.9) 让区域右上角恰好贴边
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let selL = CGRect(x: -1600, y: 200, width: 400, height: 100)
        let m2 = DisplayGeometry.appKitGlobalRect(fromVisionNormalized: CGRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1),
                                                  within: selL)
        XCTAssertEqual(m2.minX, -1240, accuracy: 0.001) // -1600 + 0.9*400
        XCTAssertEqual(m2.maxX, selL.maxX, accuracy: 0.001)
        XCTAssertEqual(m2.minY, 290, accuracy: 0.001)   // 200 + 0.9*100
        XCTAssertEqual(m2.maxY, selL.maxY, accuracy: 0.001)
        XCTAssertTrue(left.contains(m2))
    }

    // MARK: - 10. AppKit 全局 → 窗口局部（原位替换/区域定位）

    func testWindowLocalRect() {
        let appKitGlobal = CGRect(x: 1800, y: 225, width: 40, height: 20)
        let windowFrame = CGRect(x: 1700, y: 100, width: 600, height: 400)
        let local = DisplayGeometry.windowLocalRect(fromAppKitGlobal: appKitGlobal,
                                                    windowFrame: windowFrame)
        XCTAssertEqual(local.minX, 100, accuracy: 0.001)
        XCTAssertEqual(local.minY, 125, accuracy: 0.001)
        XCTAssertEqual(local.width, 40, accuracy: 0.001)
        XCTAssertEqual(local.height, 20, accuracy: 0.001)
    }

    // MARK: - 11. 点到屏的平方距离（用于最近屏选择，替代 NSScreen.main）

    func testSquaredDistance() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

        // 点在外接屏内 → 距离 0
        XCTAssertEqual(DisplayGeometry.squaredDistance(from: CGPoint(x: 1600, y: 400), to: right), 0)
        // 点在主屏内 → 距离 0
        XCTAssertEqual(DisplayGeometry.squaredDistance(from: CGPoint(x: 100, y: 100), to: main), 0)
        // 点在两屏间隙（x=1430 在主屏右边沿内，x=1450 在外接屏内）
        let gap = CGPoint(x: 1438, y: 500)
        let dMain = DisplayGeometry.squaredDistance(from: gap, to: main)
        let dRight = DisplayGeometry.squaredDistance(from: gap, to: right)
        XCTAssertLessThan(dMain, dRight)
        // 负坐标区域点（下方屏）
        let below = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        XCTAssertEqual(DisplayGeometry.squaredDistance(from: CGPoint(x: 500, y: -500), to: below), 0)
    }

    // MARK: - 12. 主屏几何与 display-local 往返一致性（同屏多矩形）

    func testRoundTripWithinMainScreen() {
        // 仅主屏（单屏）时也必须正确 —— 回归基线
        let rects = [
            CGRect(x: 100, y: 100, width: 300, height: 80),
            CGRect(x: 720, y: 450, width: 500, height: 200),
            CGRect(x: 0, y: 0, width: 1440, height: 900),
        ]
        for r in rects {
            let local = DisplayGeometry.displayLocalSourceRect(forAppKitGlobal: r,
                                                               screenFrame: mainScreen)
            XCTAssertEqual(local.width, r.width, accuracy: 0.001)
            XCTAssertEqual(local.height, r.height, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(local.minX, 0)
            XCTAssertLessThanOrEqual(local.maxX, mainScreen.width)
            XCTAssertGreaterThanOrEqual(local.minY, 0)
            XCTAssertLessThanOrEqual(local.maxY, mainScreen.height)
        }
    }
}
