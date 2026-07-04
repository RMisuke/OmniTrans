@preconcurrency import AVFAudio
import AppKit
import OSLog

// MARK: - TTS Protocol

protocol TTSEngine {
    func speak(text: String) async throws
    func stop() async
}

// MARK: - Native Offline TTS (Enhanced/Premium Voice Selection)

/// 基于 AVSpeechSynthesizer 的高质量原生 TTS 引擎。
///
/// ## 声音选择策略
///
/// 不满足于 `AVSpeechSynthesisVoice(language:)` 可能返回的低质量默认声音，
/// 本引擎通过 `selectBestNativeVoice(for:)` 实施三级过滤：
///
/// 1. **Premium** — macOS 26+ 特级人声（若已下载）
/// 2. **Enhanced** — macOS 14+ 增强高清人声
/// 3. **Default** — 标准回退
///
/// 选中结果缓存于 `voiceCache`，避免重复查询 `AVSpeechSynthesisVoice.speechVoices()`。
///
/// ## 声学参数调优
///
/// - `rate`: `DefaultSpeechRate * 0.92` — 略低于默认，消除机械急促感
/// - `pitchMultiplier`: `1.0` — 锁定自然声调基准
/// - `preUtteranceDelay`: `0.05s` — 为硬件音频流建立提供缓冲
///
/// ## 并发合规
///
/// 所有 `AVSpeechSynthesizerDelegate` 方法标记为 `nonisolated`，
/// 通过 `Task { @MainActor in ... }` 安全地恢复 continuation，
/// 满足 Swift 6 严格并发检查。
@MainActor
final class NativeTTSEngine: NSObject, TTSEngine, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let logger = Logger(subsystem: "com.omnitrans.app", category: "TTSEngine")
    private var continuation: CheckedContinuation<Void, Error>?

    // MARK: - Voice Cache

    /// 内存高效的高质量声音选择缓存。
    /// Key: 语言代码前缀（如 `"zh"`、`"en"`），Value: 已解析的 `AVSpeechSynthesisVoice`。
    private var voiceCache: [String: AVSpeechSynthesisVoice] = [:]

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - Public API

    /// 协议合规入口：使用默认语言朗读。
    func speak(text: String) async throws {
        try await speak(text: text, languageCode: "zh-CN")
    }

    /// 使用顶级原生声音朗读文本。
    /// - Parameters:
    ///   - text: 待朗读文本
    ///   - languageCode: 目标语言代码（如 `"zh-CN"`、`"en-US"`），
    ///     仅使用前缀匹配（`"zh"`），默认 `"zh-CN"`
    func speak(text: String, languageCode: String) async throws {
        // 非阻塞清除上一次语音残留
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont

            let utterance = AVSpeechUtterance(string: text)

            // ── 选择当前语言最顶级的原生声音资产 ──
            if let highQualityVoice = selectBestNativeVoice(for: languageCode) {
                utterance.voice = highQualityVoice
                logger.info("Using high-quality voice: \(highQualityVoice.name) [quality: \(highQualityVoice.quality.rawValue)]")
            }

            // ── 声学参数调优 ──
            utterance.rate             = AVSpeechUtteranceDefaultSpeechRate * 0.92
            utterance.pitchMultiplier   = 1.0
            utterance.volume            = 1.0
            utterance.preUtteranceDelay = 0.05

            synth.speak(utterance)
        }
    }

    // MARK: - Stop

    nonisolated func stop() {
        Task { @MainActor in
            synth.stopSpeaking(at: .immediate)
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }
    }

    // MARK: - Voice Selection

    /// 深度扫描 macOS 核心声音资产库，优先提取 Premium 与 Enhanced 超高清包。
    ///
    /// - Parameter languageCode: 目标语言代码，仅使用前缀匹配（如 `"zh"` 匹配 `"zh-CN"`、`"zh-HK"` 等）
    /// - Returns: 最优匹配的 `AVSpeechSynthesisVoice`，若无本地资产则返回 `nil`
    private func selectBestNativeVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        // 提取语言前缀（如 "zh-CN" → "zh"）用于宽松匹配
        let langPrefix = languageCode.lowercased().split(separator: "-").first.map(String.init) ?? languageCode.lowercased()

        if let cachedVoice = voiceCache[langPrefix] {
            return cachedVoice
        }

        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        let targetVoices = allVoices.filter {
            $0.language.lowercased().hasPrefix(langPrefix)
        }

        // 黄金梯队过滤：Premium → Enhanced → Default
        let selectedVoice = targetVoices.first { $0.quality == .premium }
                         ?? targetVoices.first { $0.quality == .enhanced }
                         ?? AVSpeechSynthesisVoice(language: languageCode)

        if let voice = selectedVoice {
            voiceCache[langPrefix] = voice
            logger.debug("Cached voice '\(voice.name)' for prefix '\(langPrefix)' (quality: \(voice.quality.rawValue))")
        }

        return selectedVoice
    }

    // MARK: - AVSpeechSynthesizerDelegate (Swift 6 Concurrency-Compliant)

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            continuation?.resume()
            continuation = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }
    }
}

// MARK: - OpenAI TTS (requires API key from provider config)

final class OpenAITTSEngine: NSObject, TTSEngine, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private let apiKey: String

    init(apiKey: String) { self.apiKey = apiKey }

    func speak(text: String) async throws {
        let url = URL(string: "https://api.openai.com/v1/audio/speech")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "tts-1",
            "input": text,
            "voice": "alloy"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        player = try AVAudioPlayer(data: data)
        player?.delegate = self
        player?.play()
    }

    func stop() async { player?.stop() }
}

// MARK: - TTS Manager

@MainActor
final class TTSManager {
    static let shared = TTSManager()

    private let native = NativeTTSEngine()
    private var openAI: OpenAITTSEngine?

    private init() {}

    /// 使用原生 macOS TTS 朗读（离线，始终可用）。
    /// - Parameters:
    ///   - text: 待朗读文本
    ///   - languageCode: 目标语言代码，默认 `"zh-CN"`
    func speakNative(text: String, languageCode: String = "zh-CN") {
        Task { try? await native.speak(text: text, languageCode: languageCode) }
    }

    /// 使用 OpenAI TTS 朗读 — 需要有效 API Key。
    func speakOpenAI(text: String, apiKey: String) async throws {
        let engine = OpenAITTSEngine(apiKey: apiKey)
        openAI = engine
        try await engine.speak(text: text)
    }

    func stop() async {
        native.stop()
        await openAI?.stop()
    }

    var isSpeaking: Bool { false }
}
