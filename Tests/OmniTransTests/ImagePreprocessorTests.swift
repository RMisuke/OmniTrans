import XCTest
import CoreVideo
@testable import OmniTrans

/// 覆盖「面积预算预处理器」：预算内零拷贝直通、超预算等比缩放且不越界。
final class ImagePreprocessorTests: XCTestCase {

    private func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        guard let buf = ImagePreprocessor.createBuffer(width: width, height: height) else {
            throw XCTSkip("CVPixelBufferCreate failed")
        }
        return buf
    }

    /// 面积在预算内的缓冲必须原样返回（零拷贝 —— 同一对象）。
    func testWithinBudgetReturnsSameBuffer() throws {
        let buf = try makeBuffer(width: 800, height: 600)  // 0.48M px < 4M
        let out = try ImagePreprocessor.prepare(buf)
        XCTAssertTrue(buf === out, "预算内必须零拷贝直通")
    }

    /// 恰好在预算边界上也不缩放。
    func testExactlyAtBudgetReturnsSameBuffer() throws {
        let buf = try makeBuffer(width: 2000, height: 2000)  // 4M px == budget
        let out = try ImagePreprocessor.prepare(buf)
        XCTAssertTrue(buf === out)
    }

    /// 超出预算时等比缩小，且面积不超预算、比例保持。
    func testOverBudgetDownscaledProportionally() throws {
        let src = try makeBuffer(width: 4000, height: 3000)  // 12M px
        let out = try ImagePreprocessor.prepare(src)

        let w = CVPixelBufferGetWidth(out)
        let h = CVPixelBufferGetHeight(out)
        XCTAssertLessThanOrEqual(w * h, ImagePreprocessor.maxPixelBudget)
        // 等比：宽高比保持 4:3（允许取整误差）
        let ratio = Double(w) / Double(h)
        XCTAssertEqual(ratio, 4.0 / 3.0, accuracy: 0.02)
        // 原缓冲不被修改
        XCTAssertEqual(CVPixelBufferGetWidth(src), 4000)
    }

    /// 竖长条区域同样被正确处理（旧实现固定长边策略的盲区）。
    func testTallRegionDownscaled() throws {
        let src = try makeBuffer(width: 1000, height: 6000)  // 6M px
        let out = try ImagePreprocessor.prepare(src)
        let w = CVPixelBufferGetWidth(out)
        let h = CVPixelBufferGetHeight(out)
        XCTAssertLessThanOrEqual(w * h, ImagePreprocessor.maxPixelBudget)
        XCTAssertEqual(Double(w) / Double(h), 1.0 / 6.0, accuracy: 0.02)
    }
}
