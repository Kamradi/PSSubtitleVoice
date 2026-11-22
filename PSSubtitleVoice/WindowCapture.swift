import ScreenCaptureKit
import CoreImage
import CoreMedia
import Foundation

final class WindowCapture: NSObject, SubtitleCapture, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "PSSubtitleVoice.frames", qos: .userInitiated)
    private let context = CIContext()
    private let recognizer = OCRProcess()
    private var frameWorker: CaptureFrameWorker!
    private let region: SubtitleRegion
    let audio = SpeakerAudioBuffer()
    private let captureAudio: Bool
    private let audioQueue = DispatchQueue(label: "PSSubtitleVoice.browserAudio", qos: .userInitiated)
    private let result: (CGImage, String, String?, Double, Bool, Double) -> Void
    private let failure: (String) -> Void
    private let gate: SubtitleGate
    private let captureID = UUID().uuidString
    private var lastHeartbeat = -Double.infinity
    private var received = 0
    private var stale = 0
    private var lastFrame = -Double.infinity

    init(region: SubtitleRegion, gate: SubtitleGate = SubtitleGate(), captureAudio: Bool = false, result: @escaping (CGImage, String, String?, Double, Bool, Double) -> Void,
         failure: @escaping (String) -> Void) {
        self.region = region; self.gate = gate; self.captureAudio = captureAudio; self.result = result; self.failure = failure
        super.init()
        frameWorker = CaptureFrameWorker { [weak self] in
            guard let self else { return }
            DiagnosticLog.shared.record("ocr.timeout", ["captureID": self.captureID, "source": "window"])
            self.recognizer.reset()
        }
    }

    func start(window: SCWindow) async throws {
        DiagnosticLog.shared.record("capture.start_requested", ["captureID": captureID, "windowID": window.windowID,
            "analyzeAudio": captureAudio, "app": window.owningApplication?.applicationName ?? "", "regionHeight": region.height,
            "regionBottom": region.bottom, "regionWidth": region.width])
        let config = SCStreamConfiguration()
        let scale = min(2.0, 1920.0 / max(window.frame.width, 1))
        config.width = max(2, Int(window.frame.width * scale))
        config.height = max(2, Int(window.frame.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = captureAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let capture = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if captureAudio { try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        stream = capture
        do {
            try await capture.startCapture()
            DiagnosticLog.shared.record("capture.started", ["captureID": captureID, "width": config.width, "height": config.height])
        } catch {
            DiagnosticLog.shared.record("capture.start_failed", ["captureID": captureID, "error": error.localizedDescription])
            stream = nil; throw error
        }
    }

    func stop() async {
        recognizer.reset(close: true)
        frameWorker.stop()
        DiagnosticLog.shared.record("capture.stop_requested", ["captureID": captureID])
        let capture = stream
        stream = nil
        do { try await capture?.stopCapture() }
        catch { DiagnosticLog.shared.record("capture.stop_failed", ["captureID": captureID, "error": error.localizedDescription]) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DiagnosticLog.shared.record("capture.stream_error", ["captureID": captureID, "error": error.localizedDescription])
        failure(error.localizedDescription)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { audio.consume(sampleBuffer); return }
        guard type == .screen else { return }
        received += 1
        let receivedAt = ProcessInfo.processInfo.systemUptime
        if receivedAt - lastHeartbeat >= 5 {
            DiagnosticLog.shared.record("capture.heartbeat", ["captureID": captureID, "received": received, "stale": stale])
            lastHeartbeat = receivedAt
        }
        guard sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let timestamp = sampleBuffer.presentationTimeStamp.seconds
        guard now - timestamp < 0.8 else { stale += 1; return }
        guard now - lastFrame >= 0.16 else { return }
        lastFrame = now
        let preparing = recognizer.requestTimeout > 3
        frameWorker.submit(timeout: recognizer.requestTimeout, work: { [self] () throws -> (CGImage, String, Double, Bool)? in
            try autoreleasepool {
                let input = CIImage(cvPixelBuffer: buffer)
                guard let image = context.createCGImage(input, from: input.extent) else { return nil }
                if preparing { result(image, "", nil, -1, CaptureHealth.isNearlyBlack(image), timestamp) }
                let text = try recognizer.recognize(image, region: region)
                return (image, text, CMClockGetTime(CMClockGetHostTimeClock()).seconds, CaptureHealth.isNearlyBlack(image))
            }
        }, completion: { [self] outcome in
            switch outcome {
            case .success(let value):
                guard let (image, text, finished, black) = value else { return }
                guard finished - timestamp < 1.5 else {
                    DiagnosticLog.shared.record("ocr.discarded", ["captureID": captureID, "reason": "stale_after_recognition", "age": finished - timestamp, "text": text])
                    return
                }
                let tracked = gate.process(text, at: timestamp)
                DiagnosticLog.shared.record("ocr.result", ["captureID": captureID, "text": text, "normalized": SubtitleTracker.normalize(text),
                    "decision": tracked.decision, "nearlyBlack": black, "recognitionMS": Int((finished - now) * 1000)])
                result(image, text, tracked.speech, finished - now, black, tracked.began)
            case .failure(let error):
                DiagnosticLog.shared.record("ocr.error", ["captureID": captureID, "error": error.localizedDescription])
                recognizer.reset()
            }
        })
    }
}
