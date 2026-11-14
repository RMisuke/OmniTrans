import XCTest
import CoreVideo
@testable import OmniTrans

// MARK: - 审计 S2 回归：首帧等待的取消/帧/错误三路竞速

/// SingleFrameStreamOutput 必须在任意交错下恰好恢复 continuation 一次，
/// 绝不悬挂（旧 OnceGate 实现：取消先于存入 → 闸门空耗 → 永久挂起）。
/// 用 expectation + fulfillment 做看门狗：泄漏时测试失败而非挂死 CI。
final class SingleFrameOutputTests: XCTestCase {

    private func makeBuffer() throws -> CVPixelBuffer {
        var buf: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 4, 4,
                                         kCVPixelFormatType_32BGRA, nil, &buf)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buf)
    }

    /// 取消先于 continuation 存入（onCancel 先跑）→ 返回 nil，不挂起。
    func testCancelBeforeStorageResumesNil() async throws {
        let output = SingleFrameStreamOutput()
        let exp = expectation(description: "resumed")
        let task = Task { () -> PixelBufferBox? in
            defer { exp.fulfill() }
            return try? await output.waitFirstFrame()
        }
        task.cancel()
        await fulfillment(of: [exp], timeout: 2.0)
        let result = await task.value
        XCTAssertNil(result)
    }

    /// 取消后于 continuation 存入 → 返回 nil，不挂起。
    func testCancelAfterStorageResumesNil() async throws {
        let output = SingleFrameStreamOutput()
        let exp = expectation(description: "resumed")
        let task = Task { () -> PixelBufferBox? in
            defer { exp.fulfill() }
            return try? await output.waitFirstFrame()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await fulfillment(of: [exp], timeout: 2.0)
        let result = await task.value
        XCTAssertNil(result)
    }

    /// 正常帧到达 → 返回同一缓冲区。
    func testFrameDeliveryResumesBuffer() async throws {
        let output = SingleFrameStreamOutput()
        let buffer = try makeBuffer()
        let exp = expectation(description: "resumed")
        let task = Task { () -> PixelBufferBox? in
            defer { exp.fulfill() }
            return try? await output.waitFirstFrame()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        output.finish(.success(PixelBufferBox(buffer)))
        await fulfillment(of: [exp], timeout: 2.0)
        let result = await task.value
        XCTAssertTrue(result?.value === buffer)
    }

    /// 帧先于 waitFirstFrame 到达（startCapture 与等待之间的窗口）→ 早到结果被取走，不挂起。
    func testEarlyFrameBeforeWaitIsDelivered() async throws {
        let output = SingleFrameStreamOutput()
        let buffer = try makeBuffer()
        output.finish(.success(PixelBufferBox(buffer)))

        let exp = expectation(description: "resumed")
        let task = Task { () -> PixelBufferBox? in
            defer { exp.fulfill() }
            return try? await output.waitFirstFrame()
        }
        await fulfillment(of: [exp], timeout: 2.0)
        let result = await task.value
        XCTAssertTrue(result?.value === buffer)
    }

    /// 重复 finish → 恰好一次 resume（二次 resume 会崩溃，本测试即崩溃探测器）。
    func testDoubleFinishResumesExactlyOnce() async throws {
        let output = SingleFrameStreamOutput()
        let buffer = try makeBuffer()
        let exp = expectation(description: "resumed")
        let task = Task { () -> PixelBufferBox? in
            defer { exp.fulfill() }
            return try? await output.waitFirstFrame()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        output.finish(.success(PixelBufferBox(buffer)))
        output.finish(.failure(NSError(domain: "test", code: -1)))
        await fulfillment(of: [exp], timeout: 2.0)
        let result = await task.value
        XCTAssertTrue(result?.value === buffer)
    }

    /// 随机时刻取消/给帧压力交错 → 全部在时限内落定，无挂起无崩溃。
    func testStressRandomInterleavings() async throws {
        for i in 0..<50 {
            let output = SingleFrameStreamOutput()
            let buffer = try makeBuffer()
            let exp = expectation(description: "resumed-\(i)")
            let task = Task { () -> PixelBufferBox? in
                defer { exp.fulfill() }
                return try? await output.waitFirstFrame()
            }
            try await Task.sleep(nanoseconds: UInt64.random(in: 0...3_000_000))
            if Bool.random() {
                task.cancel()
            } else {
                output.finish(.success(PixelBufferBox(buffer)))
            }
            await fulfillment(of: [exp], timeout: 2.0)
            _ = await task.value
        }
    }
}