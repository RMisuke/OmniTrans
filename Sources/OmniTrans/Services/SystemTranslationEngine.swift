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
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let lock = NSLock()
            var resumed = false

            let task = Task {
                do {
                    let session = TranslationSession(installedSource: source, target: target)
                    try await session.prepareTranslation()
                    let response = try await session.translate(text)
                    lock.lock()
                    if !resumed { resumed = true; lock.unlock(); cont.resume(returning: response.targetText) }
                    else { lock.unlock() }
                } catch {
                    lock.lock()
                    if !resumed { resumed = true; lock.unlock(); cont.resume(throwing: error) }
                    else { lock.unlock() }
                }
            }

            DispatchQueue.global().asyncAfter(
                deadline: .now() + .seconds(Int(timeoutSeconds))
            ) {
                task.cancel()
                lock.lock()
                if !resumed {
                    resumed = true; lock.unlock()
                    cont.resume(throwing: TranslationService.TranslationError.apiError(
                        Self.languagePackMissingMessage
                    ))
                } else { lock.unlock() }
            }
        }
    }

    // MARK: - Language availability

    private func checkAvailability(
        source: Locale.Language,
        target: Locale.Language
    ) async throws {
        let avail = self.availability

        let status: LanguageAvailability.Status = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<LanguageAvailability.Status, Error>) in
            let lock = NSLock()
            var resumed = false

            let task = Task {
                let s = await avail.status(from: source, to: target)
                lock.lock()
                if !resumed { resumed = true; lock.unlock(); cont.resume(returning: s) }
                else { lock.unlock() }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) {
                task.cancel()
                lock.lock()
                if !resumed {
                    resumed = true; lock.unlock()
                    cont.resume(throwing: TranslationService.TranslationError.apiError(
                        Self.languagePackMissingMessage
                    ))
                } else { lock.unlock() }
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
