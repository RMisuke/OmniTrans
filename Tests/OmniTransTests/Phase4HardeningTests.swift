import XCTest
import Carbon
import os
@testable import OmniTrans

// MARK: - 阶段 4 加固：降级链 / 关闭策略 / 剪贴板快照 / 火山签名 / 预热状态机 / 流闸门

/// 降级链纯函数：回绕语义 + 原生置底 + 单 provider 无降级。
@MainActor
final class FallbackChainTests: XCTestCase {

    private func provider(_ name: String, kind: ProviderKind = .openAI) -> APIProvider {
        var p = APIProvider(name: name, kind: kind, baseURL: "https://example.com", modelName: "m")
        p.isEnabled = true
        return p
    }

    func testSingleEnabledProviderHasNoFallback() {
        let p = provider("A")
        XCTAssertNil(AppState.nextFallbackProvider(after: p, in: [p]))
    }

    func testFallbackWrapsAround() {
        let a = provider("A"), b = provider("B"), c = provider("C")
        let list = [a, b, c]
        XCTAssertEqual(AppState.nextFallbackProvider(after: c, in: list)?.id, a.id)
        XCTAssertEqual(AppState.nextFallbackProvider(after: a, in: list)?.id, b.id)
    }

    func testNativeProviderOrderedLast() {
        let a = provider("A")
        let native = provider("Native", kind: .macOSNative)
        let chain = AppState.fallbackChain(from: a, in: [native, a])
        XCTAssertEqual(chain.last?.kind, .macOSNative)
    }

    func testDisabledProvidersExcluded() {
        var a = provider("A"), b = provider("B")
        b.isEnabled = false
        XCTAssertNil(AppState.nextFallbackProvider(after: a, in: [a, b]))
    }
}

/// 关闭策略键值映射（审计 H7 回归）。
final class CloseMethodTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "dismiss_mode")
        super.tearDown()
    }

    func testManualMapsToManualEsc() {
        UserDefaults.standard.set("manual", forKey: "dismiss_mode")
        XCTAssertEqual(CloseMethod.current, .manualEsc)
    }

    func testClickOutsideMapsCorrectly() {
        UserDefaults.standard.set("clickOutside", forKey: "dismiss_mode")
        XCTAssertEqual(CloseMethod.current, .clickOutside)
    }

    func testUnsetDefaultsToClickOutside() {
        UserDefaults.standard.removeObject(forKey: "dismiss_mode")
        XCTAssertEqual(CloseMethod.current, .clickOutside)
    }
}

/// 剪贴板全保真快照（审计 H10 回归）：多类型数据往返一致。
final class PasteboardSnapshotTests: XCTestCase {

    func testMultiTypeRoundTrip() throws {
        let pb = NSPasteboard(name: .init("com.omnitrans.test.snapshot"))
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        item.setData(bytes, forType: .png)
        pb.writeObjects([item])

        let snapshot = PasteboardSnapshot(pb)
        pb.clearContents()
        pb.setString("overwritten", forType: .string)
        snapshot.restore(to: pb)

        XCTAssertEqual(pb.string(forType: .string), "hello")
        XCTAssertEqual(pb.data(forType: .png), bytes)
    }

    func testEmptySnapshotRestoreClears() {
        let pb = NSPasteboard(name: .init("com.omnitrans.test.empty"))
        pb.clearContents()
        let snapshot = PasteboardSnapshot(pb)
        pb.setString("x", forType: .string)
        snapshot.restore(to: pb)
        XCTAssertNil(pb.string(forType: .string))
    }
}

/// 火山 TextList 必须是合法 JSON 数组（审计 H2 回归）。
final class VolcengineTextListTests: XCTestCase {

    private func textList(from query: String) throws -> [String] {
        var comps = URLComponents()
        comps.percentEncodedQuery = query
        let raw = try XCTUnwrap(comps.queryItems?.first(where: { $0.name == "TextList" })?.value)
        let data = try XCTUnwrap(raw.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String])
    }

    func testPlainTextProducesValidJSONArray() throws {
        let q = VolcengineSigner.signedQuery(accessKey: "ak", secretKey: "sk", sourceText: "hello world")
        XCTAssertEqual(try textList(from: q), ["hello world"])
    }

    func testSpecialCharactersAreEscaped() throws {
        let text = "引号\"反斜杠\\换行\n中文 emoji 🎉"
        let q = VolcengineSigner.signedQuery(accessKey: "ak", secretKey: "sk", sourceText: text)
        XCTAssertEqual(try textList(from: q), [text])
    }
}

/// 预热状态机（审计 M13/L2 配套）：不触发真实预热的安全路径。
@MainActor
final class OCRWarmupStateTests: XCTestCase {

    func testMarkCompleteRecordsTimestamp() {
        let s = OCRWarmupState.shared
        s.markComplete()
        XCTAssertFalse(s.isWarmingUp)
        XCTAssertFalse(s.warmupFailed)
        XCTAssertNotNil(s.lastWarmupCompletedAt)
        XCTAssertEqual(s.maxAttempts, ANEWarmup.defaultMaxAttempts)
    }

    func testFreshCacheDoesNotBlockOrRewarm() {
        let s = OCRWarmupState.shared
        s.markComplete()
        // 缓存新鲜 → ensureCacheValid 返回 true 且不置 isWarmingUp
        XCTAssertTrue(s.ensureCacheValid())
        XCTAssertFalse(s.isWarmingUp)
    }
}

/// 活跃流闸门（审计 H5 配套）：并发 acquire 严格串行。
final class ActiveStreamGateTests: XCTestCase {

    func testConcurrentAcquiresAreSerialized() async {
        let gate = ActiveStreamGate.shared
        let active = OSAllocatedUnfairLock(initialState: 0)
        let maxActive = OSAllocatedUnfairLock(initialState: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await gate.acquire()
                    let n = active.withLock { $0 += 1; return $0 }
                    maxActive.withLock { $0 = max($0, n) }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    active.withLock { $0 -= 1 }
                    await gate.release()
                }
            }
        }
        XCTAssertEqual(maxActive.withLock { $0 }, 1)
    }
}