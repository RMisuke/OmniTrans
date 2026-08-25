import XCTest
import os
@testable import OmniTrans

/// 覆盖「OCR 代际守卫」：防止连续触发 OCR 时旧结果串给新回调（方案 C）。
final class OCRGenerationGuardTests: XCTestCase {

    func testNextIncrementsFromOne() {
        let g = OCRGenerationGuard()
        XCTAssertEqual(g.next(), 1)
        XCTAssertEqual(g.next(), 2)
        XCTAssertEqual(g.current, 2)
    }

    func testIsValidOnlyForCurrentGeneration() {
        let g = OCRGenerationGuard()
        let gen = g.next()
        XCTAssertTrue(g.isValid(gen))
        XCTAssertFalse(g.isValid(gen + 1), "未来代际不应有效")
        XCTAssertFalse(g.isValid(gen - 1), "历史代际不应有效")
    }

    func testStaleGenerationInvalidatedAfterNewCapture() {
        let g = OCRGenerationGuard()
        let first = g.next()
        XCTAssertTrue(g.isValid(first))

        // 新一轮 OCR 接管（模拟用户再次触发 beginCapture）
        _ = g.next()

        XCTAssertFalse(g.isValid(first), "旧代际必须被判无效，防止结果串台")
        XCTAssertTrue(g.isValid(g.current), "当前代际应始终有效")
    }

    func testConcurrentNextIsStrictlyIncreasing() {
        let g = OCRGenerationGuard()
        let expect = expectation(description: "concurrent next")
        let queue = DispatchQueue(label: "test.ocrgen", attributes: .concurrent)
        let results = OSAllocatedUnfairLock(initialState: [Int]())

        for _ in 0..<200 {
            queue.async {
                let v = g.next()
                results.withLock { $0.append(v) }
            }
        }
        queue.async { expect.fulfill() }
        wait(for: [expect], timeout: 5)

        let values = results.withLock { $0 }
        XCTAssertEqual(values.count, 200, "应恰好产生 200 个代际号")
        XCTAssertEqual(Set(values).count, 200, "代际号不可重复")
        XCTAssertEqual(values.max(), 200, "代际号应严格递增到 200")
    }
}
