import AppKit

// MARK: - Captured Context

/// Bidirectional sliding-window context captured at the moment of text selection.
///
/// Contains the selected text along with up to 150 characters of surrounding
/// content (leading and trailing).  This context is injected into LLM prompts
/// to improve translation quality for pronoun resolution, domain terminology,
/// and tonal consistency.
///
/// Traditional MT engines (Google, Bing, Alibaba, Volcengine) ignore this context
/// entirely — it only flows into AI/LLM-based translation paths.
struct CapturedContext: Sendable, Equatable {
    /// The text the user explicitly selected for translation.
    let selectedText: String

    /// Up to 150 characters preceding the selection in the original document.
    let leadingContext: String

    /// Up to 150 characters following the selection in the original document.
    let trailingContext: String

    /// Whether either surrounding context is non-empty.
    var hasContext: Bool { !leadingContext.isEmpty || !trailingContext.isEmpty }
}

// MARK: - Context-Aware Service

/// Builds LLM prompts with bidirectional sliding-window context injection.
///
/// Replaces the old static `contextMap` (bundle-ID → canned hint) with
/// real-time surrounding-text capture performed at hotkey-press time by
/// `TextCaptureStrategies.captureSlidingWindowContext(selectedText:)`.
enum ContextAwareService {

    // MARK: - Prompt Builder

    /// Assembles the final system prompt by injecting surrounding context
    /// (if available) into the base translation prompt.
    ///
    /// - Parameters:
    ///   - basePrompt: The existing system prompt (language hints, custom prompt, etc.)
    ///   - context: Optional bidirectional context captured at selection time.
    /// - Returns: The augmented prompt if context is available and the feature
    ///   is enabled; otherwise the original `basePrompt` unchanged.
    ///
    /// This method is **pure** — no side effects, no I/O.
    /// Returns the current character limit for surrounding context based on
    /// the `context_intensity` UserDefaults key.
    /// 0 → 100, 1 → 200, 2 → 300 (default), 3 → 400, 4 → 500.
    static var contextCharLimit: Int {
        let intensity = UserDefaults.standard.integer(forKey: "context_intensity")
        switch intensity {
        case 0: return 100
        case 1: return 200
        case 3: return 400
        case 4: return 500
        default: return 300
        }
    }

    static func buildFinalPrompt(basePrompt: String, context: CapturedContext?) -> String {
        // ── Gate: feature toggle ──
        let enabled: Bool = {
            if UserDefaults.standard.object(forKey: "is_context_aware") == nil { return true }
            return UserDefaults.standard.bool(forKey: "is_context_aware")
        }()
        guard enabled else { return basePrompt }

        // ── Gate: context must exist and have surrounding text ──
        guard let ctx = context, ctx.hasContext else { return basePrompt }

        // ── Dynamic truncation based on intensity ──
        let limit = contextCharLimit
        let leading = String(ctx.leadingContext.prefix(limit))
        let trailing = String(ctx.trailingContext.prefix(limit))

        let contextBlock = """
        ---
        【重要语境参考说明】：
        用户当前正在翻译双横线内部的文本。为了提供更精准、符合语境（如代词指代、专业术语、语气连贯性）的翻译，请参考以下该文本在原文中的上下文（上下文字符已被截断，仅供参考）：
        【上文】：\(leading)
        【被翻译目标文本】：\(ctx.selectedText)
        【下文】：\(trailing)
        请直接输出被翻译目标文本的流式译文，不要对上下文内容进行翻译或解释。
        """

        return basePrompt + "\n\n" + contextBlock
    }
}
