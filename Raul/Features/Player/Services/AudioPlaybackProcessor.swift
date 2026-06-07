import AVFoundation
import Foundation
import MediaToolbox

#if !os(watchOS)
final class AudioPlaybackProcessor: @unchecked Sendable {
    var reduceSilenceGapsEnabled: Bool
    let silenceGapReductionLevel: SilenceGapReductionLevel
    var voiceEnhancementEnabled: Bool
    var onSilenceReductionChanged: (@Sendable (Bool) -> Void)?

    private var detector: AudioSilenceGapDetector
    private let stateQueue = DispatchQueue(label: "de.holgerkrupp.upnext.audio-playback-processor")
    private var tap: MTAudioProcessingTap?
    private var processingFormat: AudioStreamBasicDescription?
    private var spokenWordEnhancer: SpokenWordEnhancer?

    init(
        reduceSilenceGapsEnabled: Bool,
        silenceGapReductionLevel: SilenceGapReductionLevel,
        voiceEnhancementEnabled: Bool,
        onSilenceReductionChanged: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.reduceSilenceGapsEnabled = reduceSilenceGapsEnabled
        self.silenceGapReductionLevel = silenceGapReductionLevel
        self.voiceEnhancementEnabled = voiceEnhancementEnabled
        self.onSilenceReductionChanged = onSilenceReductionChanged
        detector = AudioSilenceGapDetector(level: silenceGapReductionLevel)
    }

    func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: audioPlaybackProcessorInit,
            finalize: audioPlaybackProcessorFinalize,
            prepare: audioPlaybackProcessorPrepare,
            unprepare: audioPlaybackProcessorUnprepare,
            process: audioPlaybackProcessorProcess
        )

        var newTap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &newTap
        )

        guard status == noErr else {
            if let clientInfo = callbacks.clientInfo {
                Unmanaged<AudioPlaybackProcessor>.fromOpaque(clientInfo).release()
            }
            return nil
        }

        tap = newTap
        return newTap
    }

    fileprivate func prepare(processingFormat: AudioStreamBasicDescription) {
        stateQueue.sync {
            self.processingFormat = processingFormat
            spokenWordEnhancer = voiceEnhancementEnabled
                ? SpokenWordEnhancer(
                    sampleRate: processingFormat.mSampleRate,
                    channelCount: Int(processingFormat.mChannelsPerFrame)
                )
                : nil
            _ = detector.reset()
        }
    }

    fileprivate func unprepare() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            spokenWordEnhancer?.reset()
            if let changed = detector.reset() {
                notifySilenceReductionChanged(changed)
            }
        }
    }

    fileprivate func process(
        numberFrames: CMItemCount,
        bufferList: UnsafeMutablePointer<AudioBufferList>
    ) {
        let sampleCount = Int(numberFrames)
        let (format, enhancer) = stateQueue.sync {
            (processingFormat, spokenWordEnhancer)
        }
        guard sampleCount > 0,
              let format else { return }

        var rmsAccumulator: Float = 0
        var rmsSampleCount = 0

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channelOffset = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            guard byteCount > 0 else { continue }
            let channelsInBuffer = max(Int(buffer.mNumberChannels), 1)

            let formatFlags = format.mFormatFlags
            let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
            let isSignedInteger = (formatFlags & kAudioFormatFlagIsSignedInteger) != 0

            if isFloat, format.mBitsPerChannel == 32 {
                let samples = data.bindMemory(to: Float.self, capacity: byteCount / MemoryLayout<Float>.size)
                let count = byteCount / MemoryLayout<Float>.size
                for index in 0..<count {
                    var sample = samples[index]
                    rmsAccumulator += sample * sample
                    rmsSampleCount += 1
                    if let enhancer {
                        let channel = channelOffset + (index % channelsInBuffer)
                        sample = enhancer.process(sample: sample, channel: channel)
                        samples[index] = sample
                    }
                }
            } else if isSignedInteger, format.mBitsPerChannel == 16 {
                let samples = data.bindMemory(to: Int16.self, capacity: byteCount / MemoryLayout<Int16>.size)
                let count = byteCount / MemoryLayout<Int16>.size
                for index in 0..<count {
                    let normalized = Float(samples[index]) / Float(Int16.max)
                    rmsAccumulator += normalized * normalized
                    rmsSampleCount += 1
                    if let enhancer {
                        let channel = channelOffset + (index % channelsInBuffer)
                        let enhanced = enhancer.process(sample: normalized, channel: channel)
                        samples[index] = Int16(max(Float(Int16.min), min(Float(Int16.max), enhanced * Float(Int16.max))))
                    }
                }
            }
            channelOffset += channelsInBuffer
        }

        guard reduceSilenceGapsEnabled, rmsSampleCount > 0 else { return }

        let rms = sqrt(rmsAccumulator / Float(rmsSampleCount))
        let decibels = rms > 0 ? (20 * log10(rms)) : -120
        let duration = Double(numberFrames) / max(Double(format.mSampleRate), 1)

        stateQueue.async { [weak self] in
            guard let self,
                  let changed = detector.observe(decibels: decibels, duration: duration) else {
                return
            }
            notifySilenceReductionChanged(changed)
        }
    }

    private func notifySilenceReductionChanged(_ isReducing: Bool) {
        DispatchQueue.main.async { [onSilenceReductionChanged] in
            onSilenceReductionChanged?(isReducing)
        }
    }
}

private func processor(from tap: MTAudioProcessingTap) -> AudioPlaybackProcessor? {
    let storage = MTAudioProcessingTapGetStorage(tap)
    return Unmanaged<AudioPlaybackProcessor>.fromOpaque(storage).takeUnretainedValue()
}

private let audioPlaybackProcessorInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let audioPlaybackProcessorFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioPlaybackProcessor>.fromOpaque(storage).release()
}

private let audioPlaybackProcessorPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
    processor(from: tap)?.prepare(processingFormat: processingFormat.pointee)
}

private let audioPlaybackProcessorUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    processor(from: tap)?.unprepare()
}

private let audioPlaybackProcessorProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
    var itemCount = numberFrames
    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        flagsOut,
        nil,
        &itemCount
    )

    guard status == noErr else {
        numberFramesOut.pointee = 0
        flagsOut.pointee = flags
        return
    }

    numberFramesOut.pointee = itemCount
    processor(from: tap)?.process(numberFrames: itemCount, bufferList: bufferListInOut)
}
#endif
