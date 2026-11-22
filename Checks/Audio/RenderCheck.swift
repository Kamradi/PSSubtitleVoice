import AVFoundation
import Foundation

@main
struct RenderCheck {
    @MainActor static func main() async throws {
        let voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.enhanced.ru-RU.Yuri")
            ?? AVSpeechSynthesisVoice(language: "ru-RU")!
        let synthesizer = AVSpeechSynthesizer()
        let text = "Нам нужно добраться до машины. Подожди меня возле старого моста, я вернусь через несколько минут. Не открывай дверь незнакомым людям и держи телефон рядом. Когда всё будет готово, мы вместе отправимся домой. Это последняя фраза, она должна прозвучать полностью."
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = false
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            let file = SpeechAudioFile { continuation.resume(with: $0) }
            synthesizer.write(utterance) { buffer in file.consume(buffer) }
        }
        let audio = try AVAudioFile(forReading: url)
        let seconds = Double(audio.length) / audio.processingFormat.sampleRate
        guard seconds > 10 else { fatalError("Unexpectedly short recording: \(seconds)") }
        let destination = URL(fileURLWithPath: "/tmp/pssubtitle-long-speech.caf")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        try FileManager.default.removeItem(at: url)
        print("PASS: completed full-buffer synthesis, \(text.count) characters, \(audio.length) samples, \(String(format: "%.1f", seconds)) seconds, \(voice.name). Audio: \(destination.path)")
    }
}
