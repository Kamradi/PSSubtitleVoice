import AVFoundation
import Foundation

// Buffer callbacks can run off the main thread. The file is closed before playback starts.
final class SpeechAudioFile {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var finished = false
    private var lastBufferAt = ProcessInfo.processInfo.systemUptime

    var secondsWithoutBuffers: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastBufferAt
    }
    private let completion: (Result<URL, Error>) -> Void

    init(completion: @escaping (Result<URL, Error>) -> Void) { self.completion = completion }

    func consume(_ audio: AVAudioBuffer) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        lastBufferAt = ProcessInfo.processInfo.systemUptime
        var result: Result<URL, Error>?
        do {
            guard let pcm = audio as? AVAudioPCMBuffer else {
                throw NSError(domain: "SpeechAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Синтезатор вернул неподдерживаемый аудиоформат."])
            }
            if pcm.frameLength == 0 {
                guard let file, file.length > 0 else {
                    throw NSError(domain: "SpeechAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Голос не создал аудиозапись. Выберите другой улучшенный голос."])
                }
                self.file = nil
                finished = true
                result = .success(url)
            } else {
                if file == nil {
                    file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                           commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                }
                try file?.write(from: pcm)
            }
        } catch {
            file = nil; finished = true
            try? FileManager.default.removeItem(at: url)
            result = .failure(error)
        }
        lock.unlock()
        if let result { completion(result) }
    }

    func cancel() {
        lock.lock()
        finished = true
        file = nil
        try? FileManager.default.removeItem(at: url)
        lock.unlock()
    }
}
