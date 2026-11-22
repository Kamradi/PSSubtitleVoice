import Foundation
let buffer = SpeakerAudioBuffer()
precondition(buffer.extract(from: 10, through: 11) == nil)
buffer.append(Array(repeating: 0.25, count: 16000), at: 10)
buffer.append(Array(repeating: 0.75, count: 16000), at: 11)
let clip = buffer.extract(from: 10.5, through: 11.5)!
let values = clip.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
precondition(values.count == 16000)
precondition(values.prefix(8000).allSatisfy { $0 == 0.25 })
precondition(values.suffix(8000).allSatisfy { $0 == 0.75 })
precondition(buffer.extract(from: 8, through: 10) == nil)
precondition(buffer.extract(from: 10, through: 15) == nil)
buffer.append(Array(repeating: 0.1, count: 16000), at: 30)
precondition(buffer.extract(from: 10, through: 11) == nil)
print("PASS: timestamp-aligned audio slicing, correct samples, missing audio fallback, duration bound, old packet eviction")
import AVFoundation
import CoreMedia
let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 24000)!
pcm.frameLength = 24000
for index in 0..<24000 {
    pcm.floatChannelData![0][index] = 0.2
    pcm.floatChannelData![1][index] = 0.6
}
var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(seconds: 100, preferredTimescale: 48000), decodeTimeStamp: .invalid)
var sample: CMSampleBuffer?
precondition(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
    formatDescription: inputFormat.formatDescription, sampleCount: 24000, sampleTimingEntryCount: 1,
    sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
precondition(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
    flags: 0, bufferList: pcm.mutableAudioBufferList) == noErr)
precondition(CMSampleBufferSetDataReady(sample!) == noErr)
let converted = SpeakerAudioBuffer()
converted.consume(sample!)
let convertedClip = converted.extract(from: 100.02, through: 100.42)!
let mono = convertedClip.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
let average = mono.reduce(0, +) / Float(mono.count)
fputs("converted average: \(average)\n", stderr)
precondition(abs(average - 0.4) < 0.02, "48k stereo must downmix to 16k mono")
print("PASS: actual CMSampleBuffer PCM copying, stereo downmix, resampling, and audio timestamps")
let retimed = SpeakerAudioBuffer()
retimed.consume(sample!, at: 200)
precondition(retimed.extract(from: 100.02, through: 100.42) == nil, "Device timestamps must not leak into host-clock slicing")
let hostClip = retimed.extract(from: 200.02, through: 200.42)!
let hostSamples = hostClip.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
precondition(abs(hostSamples.reduce(0, +) / Float(hostSamples.count) - 0.4) < 0.02)
print("PASS: capture-card audio uses the explicitly converted host-clock timestamp")
