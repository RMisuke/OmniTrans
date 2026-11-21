import Foundation

// MARK: - 探测错误分类（P1-B：替代字符串匹配）

enum ProbeError: Error, Equatable {
    case config(String)     // 无效地址 / 缺密钥
    case network(String)    // 断网 / 超时 / TLS
    case auth(Int)          // 401 / 403
    case quota(Int)         // 429
    case model(Int)         // 404 / 模型不存在
    case server(Int)        // 5xx / 其他

    /// 是否属于连通性故障（状态灯红灯范围）。
    /// 配额/模型错误不占连通灯 —— 它们不是「连不上」。
    var isConnectivityFailure: Bool {
        switch self {
        case .network, .auth: return true
        default: return false
        }
    }

    var localizedDescription: String {
        switch self {
        case .config(let m): return m
        case .network(let m): return "网络不可达：\(m)"
        case .auth: return "鉴权失败（API Key 无效或无权限）"
        case .quota: return "配额不足（HTTP 429）"
        case .model: return "模型或地址不存在（HTTP 404）"
        case .server(let c): return "服务端错误（HTTP \(c)）"
        }
    }

    static func classify(_ error: Error) -> ProbeError {
        if let pe = error as? ProbeError { return pe }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return .network(ns.localizedDescription)
        }
        switch ns.code {
        case 400: return .server(400)
        case 401, 403: return .auth(ns.code)
        case 404: return .model(404)
        case 429: return .quota(429)
        case 500...599: return .server(ns.code)
        default:
            // -1 等本地构造错误（无效地址）归为配置问题
            return ns.code == -1 ? .config(ns.localizedDescription) : .network(ns.localizedDescription)
        }
    }
}

// MARK: - 探测结果

struct ProbeResult: Sendable, Equatable {
    let providerID: UUID
    let isSuccess: Bool
    let error: ProbeError?
    let latencyMs: Int
}

// MARK: - 统一探测服务（P1-B 三层架构）

/// - **策略层**：免费探测（GET /models、/languages、本地 native）可自动执行；
///   计费探测（Anthropic POST、GoogleMT/阿里/火山真实翻译）仅在用户手动
///   触发（设置页按钮）时执行 —— 状态灯永不自动烧配额。
/// - **分类层**：`ProbeError` 枚举，替代 localizedDescription 字符串匹配。
/// - **缓存层**：(providerID + 配置指纹) 键控，30s TTL；in-flight 去重
///   保证同 key 并发共享一个探测；指纹包含密钥/地址/模型，切换配置即失效。
actor ProbeService {
    static let shared = ProbeService()

    enum Strategy: Sendable { case free, paid, local }

    static func strategy(for kind: ProviderKind) -> Strategy {
        switch kind {
        case .macOSNative: return .local
        case .openAI, .openAICompat, .ollama, .gemini, .bingMT: return .free
        case .anthropic, .googleMT, .alibabaMT, .volcengineMT: return .paid
        }
    }

    private struct Entry {
        let result: ProbeResult
        let expiresAt: Date
    }

    private var cache: [String: Entry] = [:]
    private var inflight: [String: Task<ProbeResult, Never>] = [:]
    private let cacheTTL: TimeInterval = 30

    /// 配置指纹：密钥/地址/模型任一变化即失效 ——
    /// 杜绝「切换供应商后旧探测结果污染新供应商」（旧实现竞态根因）。
    private func fingerprint(_ p: APIProvider) -> String {
        "\(p.id.uuidString)|\(p.kind.rawValue)|\(p.baseURL)|\(p.modelName)|\(p.apiKey)|\(p.apiSecret)|\(p.customRegion)"
    }

    /// 探测给定供应商。
    /// - Parameters:
    ///   - allowPaid: 是否允许计费探测（状态灯传 false；设置页手动测试传 true）
    ///   - force: 忽略缓存（手动测试语义）
    /// - Returns: 探测结果；计费供应商在 allowPaid=false 且无新鲜缓存时返回 nil
    ///   （不触发、不亮灯，UI 显示「未验证」灰灯）
    func probe(_ provider: APIProvider, allowPaid: Bool, force: Bool = false) async -> ProbeResult? {
        if provider.kind == .macOSNative {
            return ProbeResult(providerID: provider.id, isSuccess: true, error: nil, latencyMs: 0)
        }
        let key = fingerprint(provider)
        let strategy = Self.strategy(for: provider.kind)
        if strategy == .paid && !allowPaid && !force {
            guard let e = cache[key], e.expiresAt > Date() else { return nil }
            return e.result
        }
        if !force, let e = cache[key], e.expiresAt > Date() {
            return e.result
        }
        if let t = inflight[key] {
            return await t.value
        }
        let task = Task<ProbeResult, Never> { [provider] in
            let start = Date()
            do {
                try await APITestService.testConnectionThrowing(for: provider)
                return ProbeResult(providerID: provider.id, isSuccess: true, error: nil,
                                   latencyMs: Int(Date().timeIntervalSince(start) * 1000))
            } catch {
                return ProbeResult(providerID: provider.id, isSuccess: false,
                                   error: ProbeError.classify(error),
                                   latencyMs: Int(Date().timeIntervalSince(start) * 1000))
            }
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        cache[key] = Entry(result: result, expiresAt: Date().addingTimeInterval(cacheTTL))
        return result
    }

    /// 显式失效（供应商删除/密钥重置时调用）。
    func invalidate(providerID: UUID) {
        cache = cache.filter { !$0.key.hasPrefix(providerID.uuidString + "|") }
    }
}