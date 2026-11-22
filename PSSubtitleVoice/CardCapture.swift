import AVFoundation
import CoreImage
import CoreMedia
import CoreAudio

protocol SubtitleCapture: AnyObject {
    var audio: SpeakerAudioBuffer { get }
    func stop() async
}

struct CaptureDeviceChoice: Identifiable {
    let id: String
    let name: String
}

/// Only external devices are offered. No fallback to a computer/iPhone microphone.
enum CardDevices {
    static func devices(_ media: AVMediaType) -> [AVCaptureDevice] {
        // AVFoundation calls even a USB capture card's audio input "Microphone".
        // Filter by the physical USB transport rather than the video device type.
        AVCaptureDevice.devices(for: media).filter { $0.transportType == kAudioDeviceTransportTypeUSB }
    }
    static func choices(_ media: AVMediaType) -> [CaptureDeviceChoice] {
        devices(media).map { CaptureDeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
    }
    static func error(_ text: String) -> NSError {
        NSError(domain: "CardCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    static func authorize(_ media: AVMediaType) async throws {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: media)
        default: allowed = false
        }
        guard allowed else {
            throw error(media == .video ? "Разрешите доступ к камере для карты захвата в настройках macOS." : "Разрешите доступ к микрофону для звука карты в настройках macOS.")
        }
    }
}

final class CardCapture: NSObject, SubtitleCapture, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let audio = SpeakerAudioBuffer()
    private let session = AVCaptureSession()
    private let control = DispatchQueue(label: "PSSubtitleVoice.cardControl")
    private let videoQueue = DispatchQueue(label: "PSSubtitleVoice.cardVideo", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "PSSubtitleVoice.cardAudio", qos: .userInitiated)
    private let context = CIContext()
    private let recognizer = OCRProcess()
    private var frameWorker: CaptureFrameWorker!
    private let region: SubtitleRegion
    private let gate: SubtitleGate
    private let result: (CGImage, String, String?, Double, Bool, Double) -> Void
    private let failure: (String) -> Void
    private let id = UUID().uuidString
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?
    private let activityLock = NSLock()
    private var lastVideo = 0.0
    private var lastAudio = 0.0
    private var lastFrame = -Double.infinity
    private var lastHeartbeat = -Double.infinity
    private var received = 0

    init(region: SubtitleRegion, gate: SubtitleGate, result: @escaping (CGImage, String, String?, Double, Bool, Double) -> Void, failure: @escaping (String) -> Void) {
        self.region = region; self.gate = gate; self.result = result; self.failure = failure
        super.init()
        frameWorker = CaptureFrameWorker { [weak self] in
            guard let self else { return }
            DiagnosticLog.shared.record("ocr.timeout", ["captureID": self.id, "source": "card"])
            self.recognizer.reset()
        }
    }

    func start(videoID: String, audioID: String?) async throws {
        try await CardDevices.authorize(.video)
        if audioID != nil { try await CardDevices.authorize(.audio) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.async {
                do {
                    try self.configure(videoID: videoID, audioID: audioID)
                    self.session.startRunning()
                    guard self.session.isRunning else { throw CardDevices.error("Карта не запустилась. Закройте другие приложения, использующие её, и проверьте USB.") }
                    self.installWatchdog(hasAudio: audioID != nil)
                    DiagnosticLog.shared.record("card.started", ["captureID": self.id, "videoID": videoID, "audioID": audioID ?? "", "analyzeAudio": audioID != nil])
                    continuation.resume()
                } catch {
                    self.teardown()
                    DiagnosticLog.shared.record("card.start_failed", ["captureID": self.id, "error": error.localizedDescription])
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configure(videoID: String, audioID: String?) throws {
        guard let video = CardDevices.devices(.video).first(where: { $0.uniqueID == videoID }) else {
            throw CardDevices.error("Выбранная карта отключена. Подключите USB и обновите устройства.")
        }
        let sound: AVCaptureDevice?
        if let audioID {
            guard let found = CardDevices.devices(.audio).first(where: { $0.uniqueID == audioID }) else { throw CardDevices.error("Звуковой вход карты отключён. Обновите устройства.") }
            sound = found
        } else { sound = nil }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        else if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        let input = try AVCaptureDeviceInput(device: video)
        guard session.canAddInput(input) else { throw CardDevices.error("Не удалось подключить видеовход карты.") }
        session.addInput(input)
        let frames = AVCaptureVideoDataOutput()
        frames.alwaysDiscardsLateVideoFrames = true
        frames.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        frames.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(frames) else { throw CardDevices.error("Карта не поддерживает захват кадров в выбранном режиме.") }
        session.addOutput(frames)
        if let sound {
            // Some UVC devices expose both media types on the same input.
            if sound.uniqueID != video.uniqueID || !input.ports.contains(where: { $0.mediaType == .audio }) {
                let audioInput = try AVCaptureDeviceInput(device: sound)
                guard session.canAddInput(audioInput) else { throw CardDevices.error("Не удалось подключить звук карты. Закройте приложения, использующие её.") }
                session.addInput(audioInput)
            }
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: true]
            output.setSampleBufferDelegate(self, queue: audioQueue)
            guard session.canAddOutput(output) else { throw CardDevices.error("Не удалось получить звук карты.") }
            session.addOutput(output)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.failure(error?.localizedDescription ?? "Ошибка карты захвата.")
        })
        observers.append(center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: nil) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice, device.uniqueID == videoID || device.uniqueID == audioID else { return }
            self?.failure("Карта захвата отключена от USB.")
        })
    }

    private func installWatchdog(hasAudio: Bool) {
        let began = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        activityLock.lock(); lastVideo = began; lastAudio = began; activityLock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 6, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            self.activityLock.lock(); let videoAge = now - self.lastVideo; let audioAge = now - self.lastAudio; self.activityLock.unlock()
            DiagnosticLog.shared.record("card.signal", ["captureID": self.id, "videoAge": videoAge, "audioAge": audioAge, "hasAudio": hasAudio])
            if videoAge > 10 { self.failure("Карта не передаёт кадры. Проверьте USB, HDMI и настройки PS5 (HDCP выключен, 1080p60).") }
            else if hasAudio && audioAge > 10 { self.failure("Карта не передаёт звук. Проверьте HDMI-аудио PS5 и выбранный звуковой вход карты.") }
        }
        watchdog = timer; timer.resume()
    }

    func stop() async {
        recognizer.reset(close: true)
        frameWorker.stop()
        DiagnosticLog.shared.record("card.stop_requested", ["captureID": id])
        await withCheckedContinuation { continuation in
            control.async { self.teardown(); continuation.resume() }
        }
    }
    private func teardown() {
        watchdog?.cancel(); watchdog = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        recognizer.reset(close: true)
        frameWorker.stop()
        for output in session.outputs {
            (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
        }
        session.stopRunning()
        session.beginConfiguration()
        session.outputs.forEach { session.removeOutput($0) }
        session.inputs.forEach { session.removeInput($0) }
        session.commitConfiguration()
        // OCR completion is invalidated by frameWorker.stop(); never drain a Vision queue.
        DiagnosticLog.shared.record("card.stopped", ["captureID": id])
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        // Both outputs share the session clock. Convert it to the same host clock
        // used by subtitle timing and the bounded audio ring; never align by arrival.
        guard let clock = session.masterClock else { return }
        let timestamp = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock()).seconds
        guard timestamp.isFinite, abs(now - timestamp) < 1.5 else { return }
        activityLock.lock()
        if output is AVCaptureAudioDataOutput { lastAudio = now } else { lastVideo = now }
        activityLock.unlock()
        if output is AVCaptureAudioDataOutput { audio.consume(sampleBuffer, at: timestamp); return }
        received += 1
        guard now - lastFrame >= 0.18, let buffer = sampleBuffer.imageBuffer else { return }
        lastFrame = now
        let preparing = recognizer.requestTimeout > 3
        frameWorker.submit(timeout: recognizer.requestTimeout, work: { [self] () throws -> (CGImage, String, Double, Bool)? in
            try autoreleasepool {
                let input = CIImage(cvPixelBuffer: buffer)
                guard let image = context.createCGImage(input, from: input.extent) else { return nil }
                if preparing { result(image, "", nil, -1, CaptureHealth.isNearlyBlack(image), timestamp) }
                let text = try recognizer.recognize(image, region: region)
                let finished = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                return (image, text, finished, CaptureHealth.isNearlyBlack(image))
            }
        }, completion: { [self] outcome in
            switch outcome {
            case .success(let value):
                guard let (image, text, finished, black) = value, finished - timestamp < 1.5 else { return }
                let tracked = gate.process(text, at: timestamp)
                DiagnosticLog.shared.record("ocr.result", ["captureID": id, "source": "card", "text": text,
                    "decision": tracked.decision, "nearlyBlack": black, "recognitionMS": Int((finished - now) * 1000)])
                result(image, text, tracked.speech, finished - now, black, tracked.began)
            case .failure(let error):
                recognizer.reset()
                DiagnosticLog.shared.record("ocr.helper_error", ["captureID": id, "error": error.localizedDescription])
            }
        })
        if now - lastHeartbeat >= 5 {
            lastHeartbeat = now
            DiagnosticLog.shared.record("card.heartbeat", ["captureID": id, "received": received, "width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer), "frameAge": now - timestamp])
        }
    }
}
