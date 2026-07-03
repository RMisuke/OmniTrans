@preconcurrency import AVFAudio
import AppKit

// MARK: - TTS Protocol

protocol TTSEngine {
    func speak(text: String) async throws
    func stop()
}

// MARK: - Native offline TTS

/// Modern offline TTS using AVSpeechSynthesizer (macOS 14+).
/// Replaces the deprecated NSSpeechSynthesizer with AVFoundation's
/// fully asynchronous audio pipeline.
@MainActor
final class NativeTTSEngine: NSObject, TTSEngine, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(text: String) async throws {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let utterance = AVSpeechUtterance(string: text)
            // Prefer system enhanced voice for the current locale
            if let voice = AVSpeechSynthesisVoice(language: "zh-CN") {
                utterance.voice = voice
            }
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            synth.speak(utterance)
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        continuation?.resume()
        continuation = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
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

    func stop() { player?.stop() }
}

// MARK: - TTS Manager

@MainActor
final class TTSManager {
    static let shared = TTSManager()

    private let native = NativeTTSEngine()
    private var openAI: OpenAITTSEngine?

    private init() {}

    /// Speak using native macOS TTS (always available, offline).
    func speakNative(text: String) {
        Task { try? await native.speak(text: text) }
    }

    /// Speak using OpenAI TTS — requires a valid API key.
    func speakOpenAI(text: String, apiKey: String) async throws {
        let engine = OpenAITTSEngine(apiKey: apiKey)
        openAI = engine
        try await engine.speak(text: text)
    }

    func stop() {
        native.stop()
        openAI?.stop()
    }

    var isSpeaking: Bool { false }
}
