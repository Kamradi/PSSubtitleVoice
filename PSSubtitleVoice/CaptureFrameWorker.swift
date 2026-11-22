import Foundation

/// Keeps OCR off device delivery queues. Stopping never waits for Vision.
/// Completion and stop are serialized so an abandoned frame cannot touch a new session's gate.
final class CaptureFrameWorker {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "PSSubtitleVoice.ocr", qos: .userInitiated)
    private var open = true
    private var job: UUID?
    private var expired = false
    private var deadline: DispatchWorkItem?
    private let timeout: TimeInterval
    private let onTimeout: () -> Void

    init(timeout: TimeInterval = 3, onTimeout: @escaping () -> Void) {
        self.timeout = timeout; self.onTimeout = onTimeout
    }

    @discardableResult
    func submit<Value>(timeout requestTimeout: TimeInterval? = nil, work: @escaping () throws -> Value, completion: @escaping (Result<Value, Error>) -> Void) -> Bool {
        lock.lock()
        guard open, job == nil else { lock.unlock(); return false }
        let id = UUID()
        job = id; expired = false
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.open, self.job == id, !self.expired else { self.lock.unlock(); return }
            self.expired = true; self.deadline = nil
            self.lock.unlock()
            self.onTimeout()
        }
        deadline = timer
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (requestTimeout ?? timeout), execute: timer)
        queue.async {
            let result = Result { try work() }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.open, self.job == id else { return }
            self.deadline?.cancel(); self.deadline = nil; self.job = nil
            guard !self.expired else { self.expired = false; return }
            completion(result)
        }
        return true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        open = false; job = nil
        deadline?.cancel(); deadline = nil
    }
}
