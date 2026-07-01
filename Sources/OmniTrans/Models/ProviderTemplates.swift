import Foundation

/// Quick-start templates for popular LLM providers
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
    static let all: [ProviderTemplate] = [
        .init(id: "deepseek",   name: "DeepSeek",      kind: .openAICompat, baseURL: "https://api.deepseek.com/v1",           model: "deepseek-chat",             desc: "DeepSeek V3，高性价比",         icon: "brain.head.profile"),
        .init(id: "openai",     name: "OpenAI",         kind: .openAI,       baseURL: "https://api.openai.com/v1",             model: "gpt-4o-mini",               desc: "GPT-4o 系列",                 icon: "apple.logo"),
        .init(id: "ollama",     name: "Ollama (本地)",   kind: .openAICompat, baseURL: "http://localhost:11434/v1",             model: "qwen2.5:7b",                desc: "本地运行的开源模型",               icon: "desktopcomputer"),
        .init(id: "siliconflow",name: "硅基流动",         kind: .openAICompat, baseURL: "https://api.siliconflow.cn/v1",          model: "Qwen/Qwen2.5-7B-Instruct",  desc: "国产模型聚合平台",                icon: "flame"),
        .init(id: "groq",       name: "Groq",           kind: .openAICompat, baseURL: "https://api.groq.com/openai/v1",          model: "llama-3.1-8b-instant",      desc: "超快推理速度",                  icon: "bolt"),
        .init(id: "together",   name: "Together AI",    kind: .openAICompat, baseURL: "https://api.together.xyz/v1",             model: "meta-llama/Llama-3.1-8B-Instruct", desc: "开源模型托管",             icon: "link"),
        .init(id: "zhipu-plus", name: "智谱 GLM-4-Plus", kind: .openAICompat, baseURL: "https://open.bigmodel.cn/api/paas/v4",    model: "glm-4-plus",                desc: "智谱 AI GLM-4 Plus",           icon: "building.2"),
        .init(id: "zhipu-flash",name: "智谱 GLM-4-Flash",kind: .openAICompat, baseURL: "https://open.bigmodel.cn/api/paas/v4",    model: "glm-4-flash",               desc: "智谱 AI GLM-4 Flash (免费)",    icon: "bolt.badge.clock"),
        .init(id: "moonshot",   name: "Kimi (月之暗面)",  kind: .openAICompat, baseURL: "https://api.moonshot.cn/v1",             model: "moonshot-v1-8k",             desc: "月之暗面 Kimi 模型",            icon: "moon"),
        .init(id: "qwen",       name: "通义千问",         kind: .openAICompat, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-turbo",       desc: "阿里通义千问系列",               icon: "sparkles"),
        .init(id: "anthropic",  name: "Anthropic",      kind: .anthropic,    baseURL: "https://api.anthropic.com",               model: "claude-3-haiku-20240307",   desc: "Claude 3 系列",               icon: "ant"),
        .init(id: "gemini",     name: "Google Gemini",  kind: .gemini,       baseURL: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.0-flash", desc: "Google Gemini 系列",          icon: "g.circle"),
    ]
}
