import Foundation

// MARK: - Translation Business Logic (Extracted from AppState)

/// Pure‑function helpers that were previously private members of `AppState`,
/// extracted to reduce the massive `@MainActor` class surface.
///
/// All methods are `static` and `Sendable`‑safe — they operate only on their
/// explicit parameters and return values without touching `AppState` state.
extension AppState {

    // MARK: - Fallback Chain

    /// Returns the next enabled provider after `current` in list order (wraps around).
    /// Returns nil if no other enabled provider exists.
    static func nextFallbackProvider(after current: APIProvider, in providers: [APIProvider]) -> APIProvider? {
        var enabled = providers.filter(\.isEnabled)
        guard enabled.count > 1 else { return nil }
        var nativeItems: [APIProvider] = []
        enabled.removeAll(where: { if $0.kind == .macOSNative { nativeItems.append($0); return true }; return false })
        enabled.append(contentsOf: nativeItems)
        guard let idx = enabled.firstIndex(where: { $0.id == current.id }) else { return enabled.first }
        let next = (idx + 1) % enabled.count
        return next == idx ? nil : enabled[next]
    }

    /// Returns full ordered fallback chain starting from `provider`.
    static func fallbackChain(from provider: APIProvider, in providers: [APIProvider]) -> [APIProvider] {
        var enabled = providers.filter(\.isEnabled)
        guard !enabled.isEmpty else { return [provider] }
        var nativeItems: [APIProvider] = []
        enabled.removeAll(where: { if $0.kind == .macOSNative { nativeItems.append($0); return true }; return false })
        enabled.append(contentsOf: nativeItems)
        guard let idx = enabled.firstIndex(where: { $0.id == provider.id }) else { return enabled }
        var chain: [APIProvider] = []
        for i in idx..<enabled.count { chain.append(enabled[i]) }
        for i in 0..<idx { chain.append(enabled[i]) }
        return chain
    }

    // MARK: - Cache Key

    /// Builds a composite cache key using `Hasher`.
    ///
    /// The key combines source text, language direction, provider identity,
    /// context-awareness state (toggle + intensity level), and the actual
    /// leading/trailing context strings.
    static func buildCacheKey(
        text: String, targetLang: TranslationLanguage,
        providerID: UUID, isContextAwareEnabled: Bool,
        contextIntensity: Int, context: CapturedContext?
    ) -> String {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(targetLang.rawValue)
        hasher.combine(providerID)
        hasher.combine(isContextAwareEnabled)
        if isContextAwareEnabled, let ctx = context {
            hasher.combine(ctx.leadingContext)
            hasher.combine(ctx.trailingContext)
            hasher.combine(contextIntensity)
        }
        return "ck_\(hasher.finalize())"
    }

    // MARK: - Dedup

    /// Removes adjacent duplicate entries (same providerName + output),
    /// keeping only the newest of each consecutive group.
    /// Array must be in newest-first order.
    static func deduplicateAdjacentEntries(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        guard entries.count > 1 else { return entries }
        var result: [HistoryEntry] = [entries[0]]
        for i in 1..<entries.count {
            let prev = result[result.count - 1]
            let curr = entries[i]
            if curr.output == prev.output && curr.providerName == prev.providerName {
                continue
            }
            result.append(curr)
        }
        return result
    }

    // MARK: - Error Localization

    /// Maps Translation framework errors to user‑friendly Chinese messages.
    static func friendlyNativeError(_ error: Error) -> String {
        let desc = error.localizedDescription.lowercased()
        if desc.contains("not installed") || desc.contains("notinstalled") {
            return "本地语言包未安装。请前往 系统设置 → 隐私与安全性 → 翻译语言 下载所需语言包。"
        }
        if desc.contains("unsupported") && desc.contains("language") {
            return "该语言对暂时不被系统原生翻译支持。请切换至云端 API。"
        }
        if desc.contains("unable") && desc.contains("identify") {
            return "系统无法识别源文本语言，请手动指定源语言后重试。"
        }
        if desc.contains("nothing") && desc.contains("translate") {
            return "未检测到可翻译的文本内容。"
        }
        if desc.contains("internal") {
            return "系统翻译引擎内部错误，请稍后重试或切换至云端 API。"
        }
        return "原生翻译失败: \(error.localizedDescription)"
    }
}
