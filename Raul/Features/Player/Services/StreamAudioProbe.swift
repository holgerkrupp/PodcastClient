#if DEBUG && !os(watchOS)
import AVFoundation
import CoreAudio
import os

/// Debug-only bounded handoff for evaluating streamed playback audio. The tap
/// never waits for the consumer and never allocates while copying samples.
final class StreamAudioProbe: @unchecked Sendable {
    struct Snapshot: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let startTime: TimeInterval?
        let discontinuities: Int
        let truncatedFrames: Int
    }
    private struct State {
        var samples = [Float](repeating: 0, count: 480_000)
        var count = 0
        var sampleRate: Double = 0
        var startTime: TimeInterval?
        var expectedTime: TimeInterval?
        var discontinuities = 0
        var truncatedFrames = 0
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    func capture(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int,
                 format: AudioStreamBasicDescription, timeRange: CMTimeRange) {
        guard frames > 0, format.mSampleRate > 0,
              let buffer = UnsafeMutableAudioBufferListPointer(list).first,
              let data = buffer.mData else { return }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let floatSamples = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        let intSamples = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && format.mBitsPerChannel == 16
        guard floatSamples || intSamples else { return }
        let bytesPerSample = floatSamples ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
        let available = min(frames, Int(buffer.mDataByteSize) / (bytesPerSample * channels))
        let seconds = timeRange.start.seconds
        lock.withLockIfAvailableUnchecked { state in
            if state.sampleRate != 0 && state.sampleRate != format.mSampleRate {
                state.count = 0
                state.expectedTime = nil
                state.discontinuities += 1
            }
            if seconds.isFinite, let expected = state.expectedTime, abs(seconds - expected) > 0.25 {
                state.count = 0
                state.discontinuities += 1
            }
            state.sampleRate = format.mSampleRate
            if state.count == 0 { state.startTime = seconds.isFinite ? seconds : nil }
            let count = min(available, state.samples.count - state.count)
            if floatSamples {
                let source = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count { state.samples[state.count + index] = source[index * channels] }
            } else {
                let source = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count { state.samples[state.count + index] = Float(source[index * channels]) / Float(Int16.max) }
            }
            state.count += count
            state.truncatedFrames += available - count
            state.expectedTime = seconds.isFinite ? seconds + Double(available) / format.mSampleRate : nil
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock { state in
            Snapshot(samples: Array(state.samples.prefix(state.count)), sampleRate: state.sampleRate,
                     startTime: state.startTime, discontinuities: state.discontinuities,
                     truncatedFrames: state.truncatedFrames)
        }
    }
}
#endif
