import XCTest
@testable import OmniTrans

// MARK: - P1-B：探测分类与策略分层

final class ProbeErrorTests: XCTestCase {

    func testClassifyHTTPStatusCodes() {
        XCTAssertEqual(ProbeError.classify(NSError(domain: "x", code: 401)), .auth(401))
        XCTAssertEqual(ProbeError.classify(NSError(domain: "x", code: 403)), .auth(403))
        XCTAssertEqual(ProbeError.classify(NSError(domain: "x", code: 429)), .quota(429))
        XCTAssertEqual(ProbeError.classify(NSError(domain: "x", code: 404)), .model(404))
        XCTAssertEqual(ProbeError.classify(NSError(domain: "x", code: 503)), .server(503))
        XCTAssertEqual(ProbeError.classify(NSError(domain: "x", code: -1)), .config(NSError(domain: "x", code: -1).localizedDescription))
    }

    func testURLErrorClassifiedAsNetwork() {
        guard case .network = ProbeError.classify(URLError(.cannotConnectToHost)) else {
            return XCTFail("URLError 应归为 network")
        }
    }

    /// 仅 auth/network 属于连通性故障（红灯范围）；配额/模型错误不占连通灯。
    func testConnectivityScope() {
        XCTAssertTrue(ProbeError.auth(401).isConnectivityFailure)
        XCTAssertTrue(ProbeError.network("offline").isConnectivityFailure)
        XCTAssertFalse(ProbeError.quota(429).isConnectivityFailure)
        XCTAssertFalse(ProbeError.model(404).isConnectivityFailure)
        XCTAssertFalse(ProbeError.server(500).isConnectivityFailure)
    }

    /// 免费/计费探测分层：计费供应商不得被状态灯自动触发。
    func testProbeStrategyLayers() {
        XCTAssertEqual(ProbeService.strategy(for: .macOSNative), .local)
        XCTAssertEqual(ProbeService.strategy(for: .openAI), .free)
        XCTAssertEqual(ProbeService.strategy(for: .openAICompat), .free)
        XCTAssertEqual(ProbeService.strategy(for: .ollama), .free)
        XCTAssertEqual(ProbeService.strategy(for: .gemini), .free)
        XCTAssertEqual(ProbeService.strategy(for: .bingMT), .free)
        XCTAssertEqual(ProbeService.strategy(for: .anthropic), .paid)
        XCTAssertEqual(ProbeService.strategy(for: .googleMT), .paid)
        XCTAssertEqual(ProbeService.strategy(for: .alibabaMT), .paid)
        XCTAssertEqual(ProbeService.strategy(for: .volcengineMT), .paid)
    }
}