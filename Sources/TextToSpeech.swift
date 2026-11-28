import AVFoundation
import Foundation

@MainActor final class SpeechPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechPlayer()
    @Published private(set) var activeID: String?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(id: String, text: String, language: TranslationLanguage?) {
        if activeID == id {
            stop()
            return
        }
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let resolvedLanguage = language ?? TranslationLanguageDetector.detect(trimmed).language
        let utterance = AVSpeechUtterance(string: trimmed)
        if let code = resolvedLanguage?.speechLanguageCode {
            utterance.voice = AVSpeechSynthesisVoice(language: code)
        }
        activeID = id
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        activeID = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.activeID = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.activeID = nil }
    }
}
