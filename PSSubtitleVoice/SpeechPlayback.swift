import AVFoundation
import Foundation

@MainActor
final class SpeechPlayback: NSObject, AVAudioPlayerDelegate {
    private struct Job {
        let id = UUID()
        let text: String
        let translate: Bool
        var spokenText: String?
        let speaker: String
        let speed: Float
        let volume: Float
        let added = ProcessInfo.processInfo.systemUptime
        var audio: Data?
        var synthSeconds: Double?
    }
    private var waiting: [Job] = []
    private var current: Job?
    private var player: AVAudioPlayer?
    private var rendering: UUID?
    private var renderTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var generation = UUID()
    private var skipped = 0
    private var playbackBegan: TimeInterval = 0
    var translator: ((String) async throws -> String)?
    var onTranslation: ((String, String) -> Void)?
    var onError: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onPlaying: ((String) -> Void)?
    var onDiscard: ((String) -> Void)?

    func submit(_ text: String, speaker: String, speed: Float = 1, volume: Float = 1, replace: Bool = false, translate: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if replace { stop(reason: "manual_replacement") }
        expire()
        if waiting.count >= 2 {
            discard(waiting.removeFirst(), reason: "capacity")
        }
        let job = Job(text: text, translate: translate, speaker: speaker, speed: speed, volume: volume)
        waiting.append(job)
        log("speech.submitted", job: job, fields: ["replace": replace, "waiting": waiting.count])
        pump()
    }

    func stop(reason: String = "explicit_stop") {
        DiagnosticLog.shared.record("speech.stopped", ["reason": reason, "speechID": current?.id.uuidString ?? "",
            "position": player?.currentTime ?? 0, "duration": player?.duration ?? 0,
            "waitingIDs": waiting.map { $0.id.uuidString }])
        generation = UUID()
        renderTask?.cancel(); renderTask = nil; rendering = nil
        monitorTask?.cancel(); monitorTask = nil
        player?.stop(); player = nil
        if let current { onDiscard?(current.text) }
        waiting.forEach { onDiscard?($0.text) }
        current = nil; waiting.removeAll(); skipped = 0
        onPlaying?("")
        publish()
    }

    private func expire() {
        let now = ProcessInfo.processInfo.systemUptime
        let expired = waiting.filter { now - $0.added > 8 }
        waiting.removeAll { now - $0.added > 8 }
        expired.forEach { discard($0, reason: "expired") }
    }

    private func discard(_ job: Job, reason: String) {
        skipped += 1
        log("speech.queue_dropped", job: job, fields: ["reason": reason])
        onDiscard?(job.text)
    }

    private func pump() {
        expire()
        if current == nil, let first = waiting.first, let audio = first.audio {
            waiting.removeFirst()
            do {
                let sound = try AVAudioPlayer(data: audio)
                sound.delegate = self
                sound.enableRate = true
                sound.rate = first.speed
                sound.volume = first.volume
                current = first; player = sound
                guard sound.prepareToPlay(), sound.play() else { throw NSError(domain: "SileroPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: "Аудиовыход не начал воспроизведение."]) }
                onPlaying?(first.spokenText ?? first.text)
                playbackBegan = ProcessInfo.processInfo.systemUptime
                log("speech.play_begin", job: first, fields: ["duration": sound.duration, "acceptedToAudioMS": Int((ProcessInfo.processInfo.systemUptime - first.added) * 1000)])
                monitor(sound, id: first.id, lastPosition: -1, unchanged: 0)
            } catch {
                player = nil; current = nil
                discard(first, reason: "audio_error")
                onError?(error.localizedDescription)
            }
        }
        if rendering == nil, let job = waiting.first(where: { $0.audio == nil }) {
            let token = generation
            rendering = job.id
            log("speech.render_begin", job: job, fields: ["prefetch": current != nil])
            renderTask = Task { [weak self] in
                do {
                    var spoken = job.text
                    if job.translate, LocalTranslation.needsTranslation(job.text) {
                        guard let translator = self?.translator else { throw NSError(domain: "LocalTranslation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Переводчик недоступен."]) }
                        spoken = try await translator(job.text)
                        try Task.checkCancellation()
                    }
                    guard let self, self.generation == token, self.waiting.contains(where: { $0.id == job.id }), ProcessInfo.processInfo.systemUptime - job.added <= 8 else {
                        if let self, self.generation == token, self.rendering == job.id {
                            self.rendering = nil; self.renderTask = nil; self.pump()
                        }
                        return
                    }
                    if spoken != job.text { self.onTranslation?(job.text, spoken) }
                    let result = try await SileroClient.shared.synthesize(spoken, speaker: job.speaker)
                    guard self.generation == token, self.rendering == job.id else { return }
                    self.rendering = nil; self.renderTask = nil
                    guard let index = self.waiting.firstIndex(where: { $0.id == job.id }) else { self.pump(); return }
                    self.waiting[index].spokenText = spoken
                    self.waiting[index].audio = result.data
                    self.waiting[index].synthSeconds = result.seconds
                    self.log("speech.render_ready", job: job, fields: ["synthesisMS": Int(result.seconds * 1000), "duration": result.duration])
                    self.pump()
                } catch {
                    guard let self, self.generation == token, self.rendering == job.id else { return }
                    self.rendering = nil; self.renderTask = nil
                    self.log("speech.render_error", job: job, fields: ["error": error.localizedDescription])
                    if let index = self.waiting.firstIndex(where: { $0.id == job.id }) {
                        self.discard(self.waiting.remove(at: index), reason: "synthesis_error")
                    }
                    self.onError?(error.localizedDescription)
                    self.pump()
                }
            }
        }
        publish()
    }

    private func complete(_ sound: AVAudioPlayer, success: Bool) {
        guard player === sound, let job = current else { return }
        log("speech.play_finished", job: job, fields: ["success": success, "position": sound.currentTime, "duration": sound.duration])
        monitorTask?.cancel(); monitorTask = nil
        if !success { onDiscard?(job.text); onError?("Запись завершилась с ошибкой. Автоповтор отключён, чтобы не повторять уже услышанную фразу.") }
        player = nil; current = nil
        onPlaying?("")
        pump()
    }

    private func monitor(_ sound: AVAudioPlayer, id: UUID, lastPosition: Double, unchanged: Int) {
        monitorTask = Task { [weak self, weak sound] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, let sound, self.current?.id == id else { return }
            let stalled = abs(sound.currentTime - lastPosition) < 0.05 ? unchanged + 1 : 0
            if let job = self.current { self.log("speech.play_progress", job: job, fields: ["position": sound.currentTime, "duration": sound.duration, "isPlaying": sound.isPlaying]) }
            // At the end AVAudioPlayer can reset currentTime before delivering
            // its delegate callback. Give that callback a grace period.
            let elapsed = ProcessInfo.processInfo.systemUptime - self.playbackBegan
            let expected = sound.duration / Double(max(sound.rate, 0.1))
            if (!sound.isPlaying && elapsed > expected + 1) || stalled >= 3 {
                let completed = sound.currentTime >= sound.duration - 0.15
                    || (sound.currentTime == 0 && elapsed >= expected)
                sound.stop()
                self.complete(sound, success: completed)
            } else { self.monitor(sound, id: id, lastPosition: sound.currentTime, unchanged: stalled) }
        }
    }

    private func publish() {
        let phase = current != nil ? "Читаю" : rendering != nil ? "Готовлю реплику" : "Голос ожидает реплику"
        onState?(phase + " · в очереди: \(waiting.count)" + (skipped > 0 ? " · пропущено: \(skipped)" : ""))
    }
    private func log(_ event: String, job: Job, fields: [String: Any] = [:]) {
        var fields = fields
        fields["speechID"] = job.id.uuidString; fields["text"] = job.text
        fields["speaker"] = job.speaker; fields["speed"] = job.speed
        DiagnosticLog.shared.record(event, fields)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.complete(player, success: flag) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.complete(player, success: false) }
    }
}
