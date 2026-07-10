import Foundation

/// Simple in-memory probe result cache with TTL expiry.
/// Eliminates redundant network probes when translations happen in quick
/// succession (e.g. rapid hotkey invocations). (P5)
private actor ProbeCache {
    private var primaryResult: (alive: Bool, expiresAt: Date)?
    private var ollamaResult: (alive: Bool, expiresAt: Date)?

    func getPrimary() -> Bool? {
        guard let r = primaryResult, r.expiresAt > Date() else { return nil }
        return r.alive
    }
    func setPrimary(_ alive: Bool) {
        primaryResult = (alive, Date().addingTimeInterval(NetworkConfig.probeCacheTTL))
    }
    func invalidatePrimary() { primaryResult = nil }

    func getOllama() -> Bool? {
        guard let r = ollamaResult, r.expiresAt > Date() else { return nil }
        return r.alive
    }
    func setOllama(_ alive: Bool) {
        ollamaResult = (alive, Date().addingTimeInterval(NetworkConfig.ollamaProbeCacheTTL))
    }
}

/// Isolated fallback routing: probes local Ollama health and remaps providers
/// when the primary API is unreachable. Extracted from TranslationActor for
/// independent evolution and testability.
enum FallbackRouter {
    private static let probeCache = ProbeCache()

    /// Default Ollama endpoint — overridable via `UserDefaults.standard`.
    /// Set key "ollamaBaseURL" to change the fallback address (e.g. Docker).
    private static var ollamaBaseURL: String {
        UserDefaults.standard.string(forKey: "ollamaBaseURL")
            ?? "http://127.0.0.1:11434/v1"
    }
    private static let fallbackModel = "qwen2.5:1.5b"

    /// Heartbeat probe: returns true if local Ollama is alive and responding.
    /// Results are cached for `NetworkConfig.ollamaProbeCacheTTL` seconds.
    static func probeLocalOllama() async -> Bool {
        if let cached = await probeCache.getOllama() { return cached }
        guard let url = URL(string: "\(ollamaBaseURL)/models") else {
            return false
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = NetworkConfig.ollamaProbeTimeout
        do {
            let (_, resp) = try await sharedURLSession.data(for: req)
            let alive = (resp as? HTTPURLResponse)?.statusCode == 200
            await probeCache.setOllama(alive)
            return alive
        } catch {
            return false
        }
    }

    /// Lightweight connectivity check against the primary provider. (M2)
    /// Uses a HEAD request instead of a full translation call,
    /// avoiding API quota consumption and unnecessary latency.
    /// On failure, probes local Ollama and — if alive — remaps the provider
    /// to the local endpoint.
    /// - Returns: The resolved provider and a flag indicating whether fallback is active.
    static func resolveWithFallback(_ provider: APIProvider) async -> (APIProvider, Bool) {
        let alive = await probeProvider(provider)
        if alive { return (provider, false) }

        guard await probeLocalOllama() else {
            return (provider, false)
        }
        var local = provider
        local.baseURL = ollamaBaseURL
        local.modelName = fallbackModel
        local.kind = .ollama
        return (local, true)
    }

    /// Invalidates the primary probe cache. Called when the user switches providers
    /// to force a fresh connectivity probe on the next translation attempt.
    static func invalidatePrimaryProbe() {
        Task { await probeCache.invalidatePrimary() }
    }

    /// Minimal connectivity probe: HEAD request to provider's base URL.
    /// Non‑destructive — does not consume API quota.
    /// Results cached via `ProbeCache` for `NetworkConfig.probeCacheTTL`.
    private static func probeProvider(_ provider: APIProvider) async -> Bool {
        guard provider.kind != .macOSNative,
              let url = URL(string: provider.baseURL)
        else { return false }
        // Check cache first
        if let cached = await probeCache.getPrimary() { return cached }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = NetworkConfig.probeTimeout
        do {
            let (_, resp) = try await sharedURLSession.data(for: req)
            let alive = (resp as? HTTPURLResponse)?.statusCode ?? 0 < 500
            await probeCache.setPrimary(alive)
            return alive
        } catch {
            return false
        }
    }
}
