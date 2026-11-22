import AVFoundation
import Foundation

@main
struct PlaybackCheck {
    @MainActor static func main() async throws {
        let playback = SpeechPlayback()
        let voice = AVSpeechSynthesisVoice(identifier: CommandLine.arguments.dropFirst().first ?? "com.apple.voice.enhanced.ru-RU.Yuri") ?? AVSpeechSynthesisVoice(language: "ru-RU")!
        let first = "Нам нужно добраться до машины. Подожди меня возле старого моста, я вернусь через несколько минут. Не открывай дверь незнакомым людям и держи телефон рядом. Когда всё будет готово, мы вместе отправимся домой. Это последняя фраза, она должна прозвучать полностью."
        let second = "Следующая реплика началась только после завершения первой."
        var played: [String] = []
        var started: Date?
        var firstDuration: TimeInterval = 0
        var done = false
        playback.onPlaying = { text in
            if !text.isEmpty {
                played.append(text)
                if text == first { started = Date() }
            } else if played == [first], let started {
                firstDuration = Date().timeIntervalSince(started)
            }
        }
        playback.onError = { message in fatalError(message) }
        playback.onState = { state in
            if state.contains("Ошибка") { fatalError(state) }
            if played.count == 2 && state == "Голос ожидает реплику" { done = true }
        }
        playback.submit(first, voice: voice, rate: AVSpeechUtteranceDefaultSpeechRate)
        playback.submit(second, voice: voice, rate: AVSpeechUtteranceDefaultSpeechRate)
        let deadline = Date().addingTimeInterval(60)
        while !done && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        guard done, played == [first, second], firstDuration > 12 else { fatalError("Playback order/duration failed: \(played.count), \(firstDuration)") }
        // Cancel a pending render then immediately submit another; old callbacks must not replace it.
        played = []
        playback.submit(first, voice: voice, rate: AVSpeechUtteranceDefaultSpeechRate)
        playback.stop()
        playback.submit(second, voice: voice, rate: AVSpeechUtteranceDefaultSpeechRate)
        let cancelDeadline = Date().addingTimeInterval(20)
        while played.isEmpty && Date() < cancelDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
        guard played == [second] else { fatalError("Canceled render resumed unexpectedly") }
        playback.stop()
        print("PASS: full long playback before next line, no truncation by new submission, cancellation isolated; first line played for \(String(format: "%.1f", firstDuration)) seconds")
    }
}
