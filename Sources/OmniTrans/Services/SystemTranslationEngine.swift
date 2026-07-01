import Foundation
import Translation

// MARK: - Private: bridge to hidden TranslationSession init

/// Calls `TranslationSession.init(configuration:)` which exists at runtime
/// on macOS 15+ but is hidden from the macOS 26 SDK swiftinterface.
/// The symbol is present in Translation.tbd, so the linker resolves it.
@available(macOS 15.0, *)
@_silgen_name("$s11Translation0A7SessionC13configurationA2C13ConfigurationV_tcfC")
private func __TranslationSessionMake(configuration: TranslationSession.Configuration) -> TranslationSession

// MARK: - SystemTranslationEngine

/// Isolated actor that drives macOS 15+ on-device Neural Engine translation.
/// Zero network, zero token cost — pure ANE-powered offline translation.
@available(macOS 15.0, *)
actor SystemTranslationEngine {
    static let shared = SystemTranslationEngine()
    private init() {}

    // MARK: - Streaming (AsyncSequence → AsyncThrowingStream bridge)

    /// Translates `text` using the on-device model and yields incremental
    /// results through an `AsyncThrowingStream<String, Error>`.
    ///
    /// Each yielded value is the **full accumulated** translation so far,
    /// matching the system framework's batch-response semantics.
    func translateStream(
        _ text: String,
        source: Locale.Language? = nil,
        target: Locale.Language = Locale.Language(identifier: "zh-Hans")
    ) -> AsyncThrowingStream<String, Error> {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let config = TranslationSession.Configuration(
                        source: source, target: target
                    )
                    let session = __TranslationSessionMake(configuration: config)

                    // Triggers language-pack download if needed (system dialog)
                    try await session.prepareTranslation()

                    let request = TranslationSession.Request(sourceText: cleaned)
                    let batch: TranslationSession.BatchResponse = session.translate(batch: [request])

                    for try await response in batch {
                        guard !Task.isCancelled else { break }
                        continuation.yield(response.targetText)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Single-shot (no streaming)

    func translateSingle(
        _ text: String,
        source: Locale.Language? = nil,
        target: Locale.Language = Locale.Language(identifier: "zh-Hans")
    ) async throws -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        let config = TranslationSession.Configuration(
            source: source, target: target
        )
        let session = __TranslationSessionMake(configuration: config)
        try await session.prepareTranslation()
        let response = try await session.translate(cleaned)
        return response.targetText
    }

    // MARK: - Language availability

    func isLanguagePairAvailable(
        source: Locale.Language? = nil,
        target: Locale.Language = Locale.Language(identifier: "zh-Hans")
    ) async -> Bool {
        let availability = LanguageAvailability()
        let status = await availability.status(from: source ?? Locale.Language(identifier: "en"), to: target)
        return status == .installed
    }
}
