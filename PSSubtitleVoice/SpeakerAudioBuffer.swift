import AVFoundation
import CoreMedia
import Foundation

/// Eight seconds of browser audio, in memory only. Sample timestamps share the screen clock.
final class SpeakerAudioBuffer {
    private struct Packet { let start: Double; let samples: [Float] }
    private let lock = NSLock()
    private var packets: [Packet] = []
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    private var lastHeartbeat = -Double.infinity

    func consume(_ sample: CMSampleBuffer, at hostTimestamp: Double? = nil) {
        guard sample.isValid, let description = sample.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let inputFormat = AVAudioFormat(streamDescription: streamDescription) else { return }
        let count = sample.numSamples
        guard count > 0, count < 48000,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { return }
        input.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: input.mutableAudioBufferList) == noErr else { return }
        // The default AVAudioConverter channel map selects the left channel. Average both
        // channels explicitly so dialogue panned to the right is not lost.
        guard inputFormat.commonFormat == .pcmFormatFloat32, let channels = input.floatChannelData,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(count)) else {
            DiagnosticLog.shared.record("speaker.audio_format_error", ["format": inputFormat.description])
            return
        }
        mono.frameLength = AVAudioFrameCount(count)
        let channelCount = Int(inputFormat.channelCount)
        for index in 0..<count {
            var value: Float = 0
            for channel in 0..<channelCount {
                value += inputFormat.isInterleaved ? channels[0][index * channelCount + channel] : channels[channel][index]
            }
            mono.floatChannelData![0][index] = value / Float(channelCount)
        }
        if format.map({ monoFormat.isEqual($0) }) != true {
            format = monoFormat
            converter = AVAudioConverter(from: monoFormat, to: target)
        }
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(count) * 16000 / inputFormat.sampleRate) + 128) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return mono
        }
        guard error == nil, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        let timestamp = hostTimestamp ?? sample.presentationTimeStamp.seconds
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        append(samples, at: timestamp.isFinite && timestamp > 0 ? timestamp : now - Double(samples.count) / 16000)
        if now - lastHeartbeat >= 5 {
            lastHeartbeat = now
            let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
            DiagnosticLog.shared.record("speaker.audio_heartbeat", ["inputRate": inputFormat.sampleRate,
                "inputChannels": inputFormat.channelCount, "rms": rms, "audioAge": now - timestamp])
        }
    }

    func append(_ samples: [Float], at start: Double) {
        lock.lock(); defer { lock.unlock() }
        packets.append(Packet(start: start, samples: samples))
        packets.removeAll { $0.start + Double($0.samples.count) / 16000 < start - 8 }
    }

    func extract(from start: Double, through end: Double) -> Data? {
        guard end > start, end - start <= 4 else { return nil }
        lock.lock(); defer { lock.unlock() }
        let total = Int((end - start) * 16000)
        var samples = [Float](repeating: 0, count: total)
        var present = [Bool](repeating: false, count: total)
        for packet in packets {
            let offset = Int(((packet.start - start) * 16000).rounded())
            let first = max(0, offset), last = min(total, offset + packet.samples.count)
            guard last > first else { continue }
            for index in first..<last {
                samples[index] = packet.samples[index - offset]
                present[index] = true
            }
        }
        guard present.filter({ $0 }).count >= total * 3 / 4 else { return nil }
        return samples.withUnsafeBytes { Data($0) }
    }
}
