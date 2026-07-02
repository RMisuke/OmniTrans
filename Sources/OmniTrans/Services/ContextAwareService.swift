import AppKit

/// Detects the frontmost app and injects context-specific hints into LLM prompts.
enum ContextAwareService {

    private static let contextMap: [String: String] = [
        "com.apple.dt.Xcode":        "用户当前在代码编辑器中，请将文本翻译为专业、简明的代码注释，不要包含额外的闲聊。",
        "com.tencent.xinWeChat":     "用户当前在即时通讯软件中，请使用口语化、自然的日常交流语气进行翻译。",
        "com.apple.mail":            "用户当前正在编写邮件，请使用正式、得体的商务沟通语气，注意信件格式。",
        "com.microsoft.Word":        "用户当前在文字处理软件中，请使用严谨的书面语进行翻译。",
        "com.apple.Safari":          "用户当前在浏览器中，请根据网页内容的语境给出自然贴合场景的翻译。",
        "com.google.Chrome":         "用户当前在浏览器中，请根据网页内容的语境给出自然贴合场景的翻译。",
        "com.apple.Notes":           "用户当前在记事本中，请使用清晰、自然的表达进行翻译。",
        "com.apple.Terminal":        "用户当前在终端中，请翻译为简洁的技术文档风格。",
    ]

    /// Returns a context hint for the current frontmost app, or nil.
    static func currentContextPrompt() -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier else { return nil }
        return contextMap[bundleID]
    }

    /// Builds the final prompt by injecting context if available.
    static func buildFinalPrompt(basePrompt: String) -> String {
        guard let ctx = currentContextPrompt() else { return basePrompt }
        return basePrompt + "\n\n[系统上下文指令: \(ctx)]"
    }
}
