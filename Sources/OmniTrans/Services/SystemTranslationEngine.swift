import Foundation
@preconcurrency import Translation
@preconcurrency import NaturalLanguage
import os

/// Logger for Translation framework diagnostics.
private let transLogger = OSLog(
    subsystem: AppLogging.subsystem,
    category: "system-translation"
)

// MARK: - SystemTranslationEngine

/// Isolated actor that drives macOS on-device Neural Engine translation.
///
/// Language-pack detection is cached: once a language pair is confirmed
/// installed, the expensive `LanguageAvailability.status()` check is skipped
/// on all future calls.  If the check fails (or was never run), the engine
/// immediately throws with Chinese download guidance — no request is ever
/// sent to the Translation daemon without a confirmed language pack.
///
/// The first call can take 5–15 s on slower hardware because macOS needs to
/// load ANE / CoreML models into memory.  Timeouts have been chosen
/// conservatively (15 s) to avoid spurious failures on cold boot.
@available(macOS 26.0, *)
actor SystemTranslationEngine {

    /// 共享单例 —— 避免每次翻译请求重建 actor + LanguageAvailability 实例。
    static let shared = SystemTranslationEngine()

    /// Timeout for language-availability check.  Generous because the first
    /// call after boot may need to enumerate all installed language packs.
    private static let availabilityTimeout: UInt64 = 15

    /// Timeout for the actual translation request.  ANE model loading on
    /// older (but supported) hardware can take 5–10 s on first use.
    private static let translateTimeout: UInt64 = 15
    private let availability = LanguageAvailability()

    // MARK: - Language pack cache

    /// In-memory mirror of `UserDefaults` bool per language-pair key.
    /// 用 `OSAllocatedUnfairLock` 保护静态缓存，消除多线程数据竞争（审计 M2）。
    private static let installedCacheLock = OSAllocatedUnfairLock(initialState: [String: Bool]())

    private static func packKey(_ source: Locale.Language, _ target: Locale.Language) -> String {
        "nlp_\(source.languageCode?.identifier ?? "?")_\(target.languageCode?.identifier ?? "?")"
    }

    private static func isPackKnownInstalled(source: Locale.Language, target: Locale.Language) -> Bool {
        let key = packKey(source, target)
        return installedCacheLock.withLock { cache in
            if let v = cache[key] { return v }
            let v = UserDefaults.standard.bool(forKey: key)
            cache[key] = v
            return v
        }
    }

    private static func markPackInstalled(source: Locale.Language, target: Locale.Language) {
        let key = packKey(source, target)
        installedCacheLock.withLock { cache in
            cache[key] = true
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    // MARK: - Public API

    /// Optionally called at app launch to pre-load Translation framework
    /// models so the first user-triggered translation completes faster.
    ///
    /// This is deliberately fire-and-forget — if it fails the engine
    /// will try again on first real use.
    nonisolated static func warmUp() {
        Task {
            do {
                try await Self.shared.warmUpWithRetry()
            } catch {
                os_log(.error, log: transLogger,
                       "预热失败 (非致命): %{public}s", String(describing: error))
            }
        }
    }

    /// 预热带重试 —— 冷启动时 `LanguageAvailability.status()` 枚举语言包可能需要
    /// 10-30 秒甚至更久，单次尝试容易因系统繁忙而超时。重试机制确保缓存
    /// 最终被建立，后续翻译不再走冷路径。
    @available(macOS 26.0, *)
    private func warmUpWithRetry() async throws {
        let en = Locale.Language(identifier: "en")
        let zh = Locale.Language(identifier: "zh-Hans")

        // 第一次尝试（给系统充足的启动时间）
        if await checkAndWarmPair(source: en, target: zh) {
            os_log(.info, log: transLogger, "引擎预热完成 (首次尝试)")
            return
        }

        // 等待 5 秒让系统服务就绪后重试
        os_log(.info, log: transLogger, "首次预热未就绪，5 秒后重试")
        try? await Task.sleep(for: .seconds(5))

        if await checkAndWarmPair(source: en, target: zh) {
            os_log(.info, log: transLogger, "引擎预热完成 (重试成功)")
            return
        }

        // 第二次等待 10 秒后再试一次
        os_log(.info, log: transLogger, "重试仍未就绪，10 秒后最终尝试")
        try? await Task.sleep(for: .seconds(10))

        if await checkAndWarmPair(source: en, target: zh) {
            os_log(.info, log: transLogger, "引擎预热完成 (最终尝试成功)")
        } else {
            os_log(.error, log: transLogger, "引擎预热最终未就绪，将在首次翻译时重试")
        }
    }

    /// 检查单个语言对是否可用并预热翻译会话。
    /// 使用 `ResumeGate` 保证 continuation 只恢复一次（超时 vs 正常完成互斥）。
    /// - Returns: `true` 如果语言包已安装且预热成功。
    @available(macOS 26.0, *)
    private func checkAndWarmPair(source: Locale.Language, target: Locale.Language) async -> Bool {
        let avail = self.availability
        let gate = ResumeGate()
        let status: LanguageAvailability.Status = await withCheckedContinuation { cont in
            let task = Task {
                let s = await avail.status(from: source, to: target)
                await gate.runOnce { cont.resume(returning: s) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(Self.availabilityTimeout))) {
                task.cancel()
                Task { await gate.runOnce {
                    cont.resume(returning: .unsupported)
                }}
            }
        }
        guard status == .installed || status == .supported else {
            os_log(.debug, log: transLogger,
                   "语言包不可用: %{public}s → %{public}s (status=%{public}s)",
                   source.languageCode?.identifier ?? "?",
                   target.languageCode?.identifier ?? "?",
                   String(describing: status))
            return false
        }
        do {
            let session = TranslationSession(installedSource: source, target: target)
            _ = try await session.translate("Hello")
            return true
        } catch {
            os_log(.debug, log: transLogger,
                   "checkAndWarmPair 翻译预热失败: %{public}s", String(describing: error))
            return false
        }
    }

    @available(macOS 26.0, *)
    func translate(
        text: String,
        sourceLang: TranslationLanguage,
        targetLang: TranslationLanguage
    ) async throws -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        let targetLocale = targetLang.systemLocaleLanguage

        let resolvedSource: Locale.Language
        if sourceLang == .auto {
            guard let detected = await Self.detectLanguage(of: cleaned) else {
                throw TranslationService.TranslationError.apiError(
                    "无法识别源文本语言，请手动指定源语言后重试。"
                )
            }
            resolvedSource = detected
        } else {
            resolvedSource = sourceLang.systemLocaleLanguage
        }

        // 1. Cached fast path: skip availability check if known-installed
        if Self.isPackKnownInstalled(source: resolvedSource, target: targetLocale) {
            return try await translateWithTimeout(
                text: cleaned, source: resolvedSource, target: targetLocale
            )
        }

        // 2. First-time / unknown: check availability (with timeout)
        let status = try await checkAvailability(source: resolvedSource, target: targetLocale)

        // 3. 仅真正 installed 才缓存；.supported（尚未下载）不得标记 installed，
        // 否则永久跳过可用性检查（审计 M16）
        if status == .installed {
            Self.markPackInstalled(source: resolvedSource, target: targetLocale)
        }
        return try await translateWithTimeout(
            text: cleaned, source: resolvedSource, target: targetLocale
        )
    }

    // MARK: - Timeout-wrapped translation

    @available(macOS 26.0, *)
    private func translateWithTimeout(
        text: String,
        source: Locale.Language,
        target: Locale.Language
    ) async throws -> String {
        os_log(.info, log: transLogger,
               "开始翻译: \"%{public}s\" (%{public}s → %{public}s)",
               String(text.prefix(60)), source.languageCode?.identifier ?? "?",
               target.languageCode?.identifier ?? "?")
        let gate = ResumeGate()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let t0 = DispatchTime.now().uptimeNanoseconds
            let task = Task {
                do {
                    let response = try await translateText(text, source: source, target: target)
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000
                    os_log(.info, log: transLogger,
                           "翻译完成 (%.2f s): \"%{public}s\"", elapsed, String(response.prefix(60)))
                    await gate.runOnce { cont.resume(returning: response) }
                } catch {
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000
                    os_log(.error, log: transLogger,
                           "翻译失败 (%.2f s): %{public}s", elapsed, String(describing: error))
                    await gate.runOnce { cont.resume(throwing: error) }
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .seconds(Int(Self.translateTimeout))
            ) {
                task.cancel()
                Task { await gate.runOnce {
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000
                    os_log(.error, log: transLogger,
                           "翻译超时 (%.2f s / limit %llu s)", elapsed, Self.translateTimeout)
                    cont.resume(throwing: TranslationService.TranslationError.apiError(
                        Self.translateTimedOutMessage
                    ))
                }}
            }
        }
    }

    /// Uses `TranslationSession(installedSource:target:)` (macOS 26.0+) for
    /// on-device Neural Engine translation.
    ///
    /// On macOS 27+, the session may auto-download the language pack on first
    /// use. On macOS 26, the pack must be pre-downloaded — if it throws we
    /// provide actionable guidance via `checkAvailability`.
    @available(macOS 26.0, *)
    private func translateText(
        _ text: String,
        source: Locale.Language,
        target: Locale.Language
    ) async throws -> String {
        do {
            let session = TranslationSession(installedSource: source, target: target)
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            os_log(.error, log: transLogger,
                   "TranslationSession 失败: %{public}s", String(describing: error))
            throw error
        }
    }

    // MARK: - Language availability

    private func checkAvailability(
        source: Locale.Language,
        target: Locale.Language
    ) async throws -> LanguageAvailability.Status {
        let avail = self.availability
        let gate = ResumeGate()

        let status: LanguageAvailability.Status = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<LanguageAvailability.Status, Error>) in
            let task = Task {
                os_log(.info, log: transLogger,
                       "检查语言包可用性: %{public}s → %{public}s",
                       source.languageCode?.identifier ?? "?",
                       target.languageCode?.identifier ?? "?")
                let t0 = DispatchTime.now().uptimeNanoseconds
                let s = await avail.status(from: source, to: target)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000
                os_log(.info, log: transLogger,
                       "语言包查询完成: %{public}s (%.2f s)",
                       String(describing: s), elapsed)
                await gate.runOnce { cont.resume(returning: s) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(Self.availabilityTimeout))) {
                task.cancel()
                Task { await gate.runOnce {
                    os_log(.error, log: transLogger,
                           "语言包可用性检查超时 (%llu s)", Self.availabilityTimeout)
                    cont.resume(throwing: TranslationService.TranslationError.apiError(
                        Self.languagePackMissingMessage
                    ))
                }}
            }
        }

        switch status {
        case .installed:
            return status
        case .supported:
            // macOS 26: 语言包状态为 .supported 但尚未 .installed。
            // macOS 27+ 在 TranslationSession 初始化时会自动下载，
            // macOS 26 上则需要手动下载。直接尝试翻译，让下层
            // TranslationSession 自己处理下载/报错。
            os_log(.info, log: transLogger,
                   "语言包状态为 .supported，尝试直接翻译 (macOS 27 可自动下载)")
            return status
        case .unsupported:
            throw TranslationService.TranslationError.apiError(
                "\"\(source.languageCode?.identifier ?? "?")\" → \"\(target.languageCode?.identifier ?? "?")\" 语言对暂不被系统原生翻译支持，请切换至云端 API。"
            )
        @unknown default:
            return status
        }
    }

    // MARK: - Language detection

    private static func detectLanguage(of text: String) async -> Locale.Language? {
        await withCheckedContinuation { continuation in
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            guard let hypothesis = recognizer.dominantLanguage else {
                continuation.resume(returning: nil); return
            }
            let code = Locale.LanguageCode(stringLiteral: hypothesis.rawValue)
            continuation.resume(returning: Locale.Language(languageCode: code))
        }
    }

    // MARK: - Messages

    static let languagePackMissingMessage = """
        本地语言包未安装。

        请打开 系统设置 → 通用 → 语言与地区，
        滚动到底部找到「翻译语言」，下载所需语言模型后重试。
        """

    /// Shown when the translation request itself times out (ANE model
    /// loading or Translation daemon hung).
    static let translateTimedOutMessage = """
        系统翻译引擎超时。

        这通常是因为神经引擎模型仍在加载中。
        请过几秒再试一次；如果持续出现，请检查「系统设置 → 通用 → 语言与地区 → 翻译语言」
        中语言包是否已完整下载，或在「活动监视器」中确认 `translationd` 进程是否正常运行。
        """
}

// MARK: - Resume Gate (Swift 6 Concurrency-Safe)

/// Lightweight actor that guarantees a continuation is resumed exactly once,
/// replacing the old `NSLock` + `Bool` pattern which is illegal in Swift 6.
private actor ResumeGate {
    private var fired = false

    func runOnce(_ block: @Sendable () -> Void) {
        guard !fired else { return }
        fired = true
        block()
    }
}
