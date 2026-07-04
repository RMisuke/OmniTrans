import Foundation

// MARK: - Fallback Eligibility

extension TranslationService.TranslationError {
    /// Whether this error should trigger automatic fallback to the next engine.
    var shouldFallback: Bool {
        let desc = self.errorDescription?.lowercased() ?? ""
        if desc.contains("429") || desc.contains("rate") || desc.contains("quota") || desc.contains("rpm") { return true }
        if desc.contains("timeout") || desc.contains("network") || desc.contains("connection") || desc.contains("dns") { return true }
        if desc.contains("500") || desc.contains("502") || desc.contains("503") || desc.contains("server error") { return true }
        if desc.contains("overloaded") || desc.contains("unavailable") || desc.contains("capacity") { return true }
        if desc.contains("api error") || desc.contains("invalid response") { return true }
        return false
    }
}

// MARK: - Translation Pipeline (Sequential API Fallback + 30ms Token Batching)

/// Iterates through all enabled providers **in list order**, trying each one
/// until a translation succeeds. Respects the user's "auto-fallback" setting.
///
/// ## Token Batching (30ms Throttling)
/// Instead of forwarding every engine-emitted chunk directly to the UI
/// continuation, the pipeline accumulates tokens into a `tokenBuffer` and
/// flushes them on a **30 ms** cadence.  This matches a ~30 fps UI refresh
/// rate, preventing Liquid Glass / Mica backdrop recomposition on every
/// single SSE token while preserving fluid streaming animation.
actor TranslationPipeline {

    /// Accumulated token buffer — flushed every ~30ms to the continuation.
    private var tokenBuffer: String = ""

    /// Timer task for the 30ms flush window.
    private var flushTask: Task<Void, Never>?

    /// Build the ordered fallback chain: starting from `provider`, then every
    /// other enabled provider in list order, skipping disabled ones.
    private func orderedFallbackChain(from provider: APIProvider) async -> [APIProvider] {
        let all = await MainActor.run { AppState.shared.enabledProviders }
        guard !all.isEmpty else { return [provider] }

        // If fallback is disabled, only try the current provider
        let fallbackEnabled = UserDefaults.standard.bool(forKey: "fallback_on_failure")
        if !fallbackEnabled { return [provider] }

        // Build chain: start with current provider, then remaining enabled in order
        var seen = Set<UUID>()
        var chain: [APIProvider] = []

        // First: find and add the current provider
        if let idx = all.firstIndex(where: { $0.id == provider.id }) {
            chain.append(all[idx])
            seen.insert(all[idx].id)
            // Then add remaining from current position onward
            for i in (idx + 1)..<all.count where !seen.contains(all[i].id) {
                chain.append(all[i])
                seen.insert(all[i].id)
            }
            // Then wrap around from beginning
            for i in 0..<idx where !seen.contains(all[i].id) {
                chain.append(all[i])
                seen.insert(all[i].id)
            }
        } else {
            // Provider not in list — just try all enabled
            chain = all
        }

        // .macOSNative always goes last (ultimate fallback)
        var nativeItems: [APIProvider] = []
        chain.removeAll(where: {
            if $0.kind == .macOSNative { nativeItems.append($0); return true }
            return false
        })
        chain.append(contentsOf: nativeItems)
        return chain
    }

    // MARK: - Execute

    func execute(
        text: String,
        provider: APIProvider,
        isDictionaryMode: Bool,
        sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage,
        context: CapturedContext? = nil
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                let chain = await self.orderedFallbackChain(from: provider)
                var lastError: Error?

                for (index, p) in chain.enumerated() {
                    if index > 0 {
                        let fallbackOn = UserDefaults.standard.bool(forKey: "fallback_on_failure")
                        guard fallbackOn else {
                            // Flush any remaining buffered tokens before failing
                            self.flushBuffer(to: continuation)
                            continuation.finish(throwing: lastError ?? TranslationService.TranslationError.apiError("翻译失败: \(p.name)"))
                            return
                        }
                        print("[Pipeline] 🔄 Fallback #\(index) → \(p.name) · \(p.modelName)")
                    }

                    let ctx = EngineRoutingContext(text: text, provider: p, isWord: isDictionaryMode)
                    let engine = TranslationEngineFactory.makeEngine(context: ctx)
                    let stream = engine.execute(
                        text: text, provider: p,
                        isDictionaryMode: isDictionaryMode,
                        sourceLang: sourceLang, targetLang: targetLang,
                        context: context
                    )

                    do {
                        var yielded = false
                        for try await chunk in stream {
                            yielded = true
                            // ── Token batching: buffer, don't immediately yield ──
                            self.bufferAndScheduleFlush(chunk: chunk, continuation: continuation)
                        }
                        // Flush any remaining buffered tokens at stream end
                        self.flushBuffer(to: continuation)
                        if yielded {
                            continuation.finish()
                            return
                        }
                    } catch {
                        self.flushBuffer(to: continuation)
                        lastError = error
                        let te = error as? TranslationService.TranslationError
                        let eligible = te?.shouldFallback ?? false
                        print("[Pipeline] ❌ \(p.name) failed (fallback: \(eligible)): \(error.localizedDescription)")
                        if !eligible { continuation.finish(throwing: error); return }
                    }
                }

                self.flushBuffer(to: continuation)
                continuation.finish(throwing: lastError ?? TranslationService.TranslationError.apiError("所有引擎均不可用"))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 30ms Token Batching

    /// 30 ms flush interval — yields ~33 fps UI updates.  Balances streaming
    /// fluidity against Liquid Glass backdrop recomposition cost.
    private static let flushIntervalNs: UInt64 = 30_000_000  // 30ms

    /// Appends a chunk to the internal buffer and schedules a 30ms deferred flush.
    /// If a flush is already scheduled, the new chunk simply extends the buffer
    /// (the pending timer will flush everything together).
    private func bufferAndScheduleFlush(
        chunk: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        tokenBuffer += chunk

        // If a flush is already pending, just let it accumulate
        guard flushTask == nil else { return }

        flushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.flushIntervalNs)
            guard !Task.isCancelled else { return }
            await self.flushBuffer(to: continuation)
        }
    }

    /// Immediately flushes the accumulated `tokenBuffer` to the continuation
    /// and resets the flush timer.
    private func flushBuffer(
        to continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        flushTask?.cancel()
        flushTask = nil

        guard !tokenBuffer.isEmpty else { return }
        let text = tokenBuffer
        tokenBuffer = ""
        continuation.yield(text)
    }
}
