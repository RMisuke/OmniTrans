import Foundation
import Translation
import NaturalLanguage

// MARK: - SystemTranslationEngine

/// Isolated actor that drives macOS on-device Neural Engine translation.
///
/// Language-pack detection is cached: once a language pair is confirmed
/// installed, the expensive `LanguageAvailability.status()` check is skipped
/// on all future calls.  If the check fails (or was never run), the engine
/// immediately throws with Chinese download guidance — no request is ever
/// sent to the Translation daemon without a confirmed language pack.
@available(macOS 26.0, *)
actor SystemTranslationEngine {

    private static let timeoutSeconds: UInt64 = 3
    private let availability = LanguageAvailability()

    // MARK: - Language pack cache

    /// In-memory mirror of `UserDefaults` bool per language-pair key.
    private static var installedCache: [String: Bool] = [:]

    private static func isPackKnownInstalled(source: Locale.Language, target: Locale.Language) -> Bool {
        let key = "nlp_\(source.languageCode?.identifier ?? "?")_\(target.languageCode?.identifier ?? "?")"
        if let v = installedCache[key] { return v }
        let v = UserDefaults.standard.bool(forKey: key)
        installedCache[key] = v
        return v
    }

    private static func markPackInstalled(source: Locale.Language, target: Locale.Language) {
        let key = "nlp_\(source.languageCode?.identifier ?? "?")_\(target.languageCode?.identifier ?? "?")"
        installedCache[key] = true
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: - Public API

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
            return try await Self.translateWithTimeout(
                text: cleaned, source: resolvedSource, target: targetLocale
            )
        }

        // 2. First-time / unknown: check availability (with timeout)
        try await checkAvailability(source: resolvedSource, target: targetLocale)

        // 3. Available → cache & translate
        Self.markPackInstalled(source: resolvedSource, target: targetLocale)
        return try await Self.translateWithTimeout(
            text: cleaned, source: resolvedSource, target: targetLocale
        )
    }

    // MARK: - Timeout-wrapped translation

    private static func translateWithTimeout(
        text: String,
        source: Locale.Language,
        target: Locale.Language
    ) async throws -> String {
        let gate = ResumeGate()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let task = Task {
                do {
                    let response = try await translateText(text, source: source, target: target)
                    await gate.runOnce { cont.resume(returning: response) }
                } catch {
                    await gate.runOnce { cont.resume(throwing: error) }
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .seconds(Int(timeoutSeconds))
            ) {
                task.cancel()
                Task { await gate.runOnce {
                    cont.resume(throwing: TranslationService.TranslationError.apiError(
                        Self.languagePackMissingMessage
                    ))
                }}
            }
        }
    }

    /// Uses `TranslationSession(installedSource:target:)` (macOS 26.0+) for
    /// on-device Neural Engine translation.  The session is created per‑request
    /// and the framework handles model caching internally.
    @available(macOS 26.0, *)
    private static func translateText(
        _ text: String,
        source: Locale.Language,
        target: Locale.Language
    ) async throws -> String {
        let session = TranslationSession(installedSource: source, target: target)
        let response = try await session.translate(text)
        return response.targetText
    }

    // MARK: - Language availability

    private func checkAvailability(
        source: Locale.Language,
        target: Locale.Language
    ) async throws {
        let avail = self.availability
        let gate = ResumeGate()

        let status: LanguageAvailability.Status = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<LanguageAvailability.Status, Error>) in
            let task = Task {
                let s = await avail.status(from: source, to: target)
                await gate.runOnce { cont.resume(returning: s) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) {
                task.cancel()
                Task { await gate.runOnce {
                    cont.resume(throwing: TranslationService.TranslationError.apiError(
                        Self.languagePackMissingMessage
                    ))
                }}
            }
        }

        switch status {
        case .installed:
            return
        case .supported:
            throw TranslationService.TranslationError.apiError(Self.languagePackMissingMessage)
        case .unsupported:
            throw TranslationService.TranslationError.apiError(
                "\"\(source.languageCode?.identifier ?? "?")\" → \"\(target.languageCode?.identifier ?? "?")\" 语言对暂不被系统原生翻译支持，请切换至云端 API。"
            )
        @unknown default:
            break
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
