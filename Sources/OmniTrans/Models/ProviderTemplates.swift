import Foundation

/// Quick-start templates for API providers.
/// Split into AI (LLM) and MT (traditional machine translation) groups.
///
/// 2026-08 数据刷新（依据各官方 API 文档核实）：
/// - DeepSeek：`deepseek-chat`/`deepseek-reasoner` 已于 2026-07-24 停用，
///   全面切换 V4 系列（deepseek-v4-flash / deepseek-v4-pro）
/// - OpenAI：GPT-5 系列（gpt-5 / gpt-5-mini）
/// - Anthropic：Claude 5 系列（Opus 5 / Sonnet 5）
/// - Gemini：Gemini 3 系列（3 Flash / 3.1 Pro）
/// - 智谱：GLM-5（2026-02 发布，开源 SOTA）
/// - Kimi：moonshot-v1 已停止维护 → Kimi K3
/// - Qwen：Qwen3.5 系（qwen-plus 别名持续指向最新）
/// - Groq：mixtral 已下线，Llama 3.3 / Kimi K2 在线
struct ProviderTemplate: Identifiable {
    let id: String
    let name: String
    let kind: ProviderKind
    let baseURL: String
    let model: String
    let desc: String
    let icon: String
}

extension ProviderTemplate {
    /// AI / LLM providers (OpenAI-compatible, Anthropic, Gemini).
        static let ai: [ProviderTemplate] = [
        .init(id: "sensenova",  name: "SenseNova",     kind: .openAICompat, baseURL: "https://token.sensenova.cn/v1",          model: "SenseNova-5.0",             desc: "商汤日日新 5.0，OpenAI 兼容",        icon: "sparkle.magnifyingglass"),
        .init(id: "deepseek",   name: "DeepSeek",      kind: .openAICompat, baseURL: "https://api.deepseek.com/v1",           model: "deepseek-v4-flash",         desc: "DeepSeek V4 闪电版，高性价比国产旗舰", icon: "brain.head.profile"),
        .init(id: "openai",     name: "OpenAI",         kind: .openAI,       baseURL: "https://api.openai.com/v1",             model: "gpt-5-mini",                desc: "GPT-5 系列，快速且高性价比",        icon: "apple.logo"),
        .init(id: "ollama",     name: "Ollama (本地)",   kind: .ollama,       baseURL: "http://127.0.0.1:11434/v1",             model: "qwen3",                     desc: "本地运行开源模型，完全离线，无需 API Key", icon: "desktopcomputer"),
        .init(id: "siliconflow",name: "硅基流动",         kind: .openAICompat, baseURL: "https://api.siliconflow.cn/v1",          model: "deepseek-ai/DeepSeek-V4-Flash", desc: "国产模型聚合平台，已上线 DeepSeek V4 全系", icon: "flame"),
        .init(id: "groq",       name: "Groq",           kind: .openAICompat, baseURL: "https://api.groq.com/openai/v1",          model: "llama-3.3-70b-versatile",   desc: "超快推理速度，LPU 加速",              icon: "bolt"),
        .init(id: "together",   name: "Together AI",    kind: .openAICompat, baseURL: "https://api.together.xyz/v1",             model: "meta-llama/Llama-3.3-70B-Instruct-Turbo", desc: "开源模型托管平台",          icon: "link"),
        .init(id: "zhipu-plus", name: "智谱 GLM-5",      kind: .openAICompat, baseURL: "https://open.bigmodel.cn/api/paas/v4",    model: "glm-5",                     desc: "智谱 GLM-5，开源 SOTA 旗舰",        icon: "building.2"),
        .init(id: "zhipu-flash",name: "智谱 GLM-4-Flash",kind: .openAICompat, baseURL: "https://open.bigmodel.cn/api/paas/v4",    model: "glm-4-flash",               desc: "智谱 AI GLM-4 Flash，长期免费高速",  icon: "bolt.badge.clock"),
        .init(id: "moonshot",   name: "Kimi (月之暗面)",  kind: .openAICompat, baseURL: "https://api.moonshot.cn/v1",             model: "kimi-k3",                   desc: "月之暗面 Kimi K3 最新旗舰，超长上下文", icon: "moon"),
        .init(id: "qwen",       name: "通义千问",         kind: .openAICompat, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus",       desc: "阿里通义千问 Qwen3 系列",              icon: "sparkles"),
        .init(id: "anthropic",  name: "Anthropic",      kind: .anthropic,    baseURL: "https://api.anthropic.com",               model: "claude-sonnet-5",           desc: "Claude Sonnet 5，最新旗舰",         icon: "ant"),
        .init(id: "gemini",     name: "Google Gemini",  kind: .gemini,       baseURL: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-3-flash-preview", desc: "Gemini 3 Flash，Google 最新",  icon: "g.circle"),
    ]

    /// Traditional Machine Translation providers (non-streaming, single-shot).
        static let mt: [ProviderTemplate] = [
        .init(id: "google-mt",  name: "Google 翻译",    kind: .googleMT,  baseURL: "https://translation.googleapis.com/language/translate/v2", model: "nmt",     desc: "Google Cloud Translation v2，需 API Key",                    icon: "g.circle"),
        .init(id: "bing-mt",    name: "Bing 翻译",      kind: .bingMT,    baseURL: "https://api.cognitive.microsofttranslator.com",              model: "general", desc: "Microsoft Translator v3，需 Key + Region",                  icon: "b.square"),
        .init(id: "alibaba-mt", name: "阿里云翻译",       kind: .alibabaMT, baseURL: "https://mt.cn-hangzhou.aliyuncs.com",                       model: "general", desc: "阿里云机器翻译，需 AccessKey ID + Secret",               icon: "a.square"),
        .init(id: "volcengine-mt", name: "火山翻译",      kind: .volcengineMT, baseURL: "https://translate.volcengineapi.com",                     model: "general", desc: "字节跳动火山翻译，需 Access Key + Secret Key",          icon: "v.square"),
    ]

    /// Legacy flat list (for backward compatibility, excludes macOSNative).
    static var all: [ProviderTemplate] { ai + mt }
}
