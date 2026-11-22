import AVFoundation
import Foundation

@main
struct SileroPlaybackCheck {
    @MainActor static func main() async throws {
        let health = try await SileroClient.shared.health()
        precondition(health.ready && health.speakers.contains("aidar") && health.speakers.contains("kseniya"))
        let playback = SpeechPlayback()
        let first = "Нам нужно добраться до машины. Подожди меня возле старого моста, я вернусь через несколько минут. Не открывай дверь незнакомым людям и держи телефон рядом."
        let second = "Хорошо, я буду ждать тебя здесь."
        var played: [String] = []
        var done = false
        var errorMessage: String?
        playback.onPlaying = { if !$0.isEmpty { played.append($0) } }
        playback.onError = { errorMessage = $0 }
        playback.onState = { state in if played.count == 2 && state.hasPrefix("Голос ожидает") { done = true } }
        playback.submit(first, speaker: "aidar")
        let firstDeadline = Date().addingTimeInterval(60)
        while played.isEmpty && errorMessage == nil && Date() < firstDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        playback.submit(second, speaker: "kseniya")
        let deadline = Date().addingTimeInterval(90)
        while !done && errorMessage == nil && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(errorMessage == nil, errorMessage ?? "")
        precondition(done && played == [first, second], "Speech order or completion failure")
        played = []
        playback.submit(first, speaker: "aidar")
        playback.stop(reason: "test_cancel")
        playback.submit(second, speaker: "kseniya")
        let cancellationDeadline = Date().addingTimeInterval(30)
        while played.isEmpty && errorMessage == nil && Date() < cancellationDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(played == [second], "Canceled synthesis must not resume")
        playback.stop(reason: "test_finished")
        DiagnosticLog.shared.flush()
        print("PASS: local Silero readiness, two different voices in order, prefetch, completion, stale synthesis cancellation")
    }
}
