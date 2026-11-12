import AVFoundation
import AVFAudio
import CoreAudio
import Foundation
import MediaToolbox

#if !os(watchOS)
private struct EqualizerBiquad {
    let b0: Float
    let b1: Float
    let b2: Float
    let a1: Float
    let a2: Float

    static func shelf(frequency: Double, gainDecibels: Double, sampleRate: Double, high: Bool) -> Self {
        guard abs(gainDecibels) > 0.01 else { return .identity }
        let a = pow(10, gainDecibels / 40)
        let omega = 2 * Double.pi * frequency / max(sampleRate, 8_000)
        let cosine = cos(omega)
        let sine = sin(omega)
        let alpha = sine / 2 * sqrt(2)
        let beta = 2 * sqrt(a) * alpha
        let raw: (Double, Double, Double, Double, Double, Double)
        if high {
            raw = (
                a * ((a + 1) + (a - 1) * cosine + beta),
                -2 * a * ((a - 1) + (a + 1) * cosine),
                a * ((a + 1) + (a - 1) * cosine - beta),
                (a + 1) - (a - 1) * cosine + beta,
                2 * ((a - 1) - (a + 1) * cosine),
                (a + 1) - (a - 1) * cosine - beta
            )
        } else {
            raw = (
                a * ((a + 1) - (a - 1) * cosine + beta),
                2 * a * ((a - 1) - (a + 1) * cosine),
                a * ((a + 1) - (a - 1) * cosine - beta),
                (a + 1) + (a - 1) * cosine + beta,
                -2 * ((a - 1) + (a + 1) * cosine),
                (a + 1) + (a - 1) * cosine - beta
            )
        }
        guard raw.3.isFinite, abs(raw.3) > 0.000_001 else { return .identity }
        return Self(
            b0: Float(raw.0 / raw.3), b1: Float(raw.1 / raw.3), b2: Float(raw.2 / raw.3),
            a1: Float(raw.4 / raw.3), a2: Float(raw.5 / raw.3)
        )
    }

    static let identity = Self(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
}

private struct EqualizerFilterState {
    var x1: Float = 0
    var x2: Float = 0
    var y1: Float = 0
    var y2: Float = 0

    mutating func process(_ input: Float, coefficients: EqualizerBiquad) -> Float {
        let output = coefficients.b0 * input + coefficients.b1 * x1 + coefficients.b2 * x2
            - coefficients.a1 * y1 - coefficients.a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }
}

final class EqualizerDSP {
    private let preset: EqualizerPreset
    private var lowStates: [EqualizerFilterState]
    private var highStates: [EqualizerFilterState]
    private let low: EqualizerBiquad
    private let high: EqualizerBiquad

    init(preset: EqualizerPreset, sampleRate: Double, channelCount: Int) {
        self.preset = preset
        let channels = max(channelCount, 1)
        lowStates = Array(repeating: EqualizerFilterState(), count: channels)
        highStates = Array(repeating: EqualizerFilterState(), count: channels)
        let gains: (Double, Double)
        switch preset {
        case .flat: gains = (0, 0)
        case .speechClarity: gains = (-2.5, 2.5)
        case .warm: gains = (2, -1)
        case .bassCut: gains = (-6, 0)
        }
        low = .shelf(frequency: 140, gainDecibels: gains.0, sampleRate: sampleRate, high: false)
        high = .shelf(frequency: 3_000, gainDecibels: gains.1, sampleRate: sampleRate, high: true)
    }

    func process(_ sample: Float, channel: Int) -> Float {
        guard preset != .flat else { return sample }
        let index = min(max(channel, 0), lowStates.count - 1)
        let lowPassed = lowStates[index].process(sample, coefficients: low)
        let equalized = highStates[index].process(lowPassed, coefficients: high)
        let ceiling: Float = 0.891_250_9
        return min(ceiling, max(-ceiling, equalized))
    }
}

final class AudioPlaybackProcessor: @unchecked Sendable {
    var reduceSilenceGapsEnabled: Bool
    let silenceGapReductionLevel: SilenceGapReductionLevel
    var voiceEnhancementEnabled: Bool
    let equalizerPreset: EqualizerPreset
    var onSilenceReductionChanged: (@Sendable (Bool) -> Void)?

    private var detector: AudioSilenceGapDetector
    private let stateQueue = DispatchQueue(label: "de.holgerkrupp.upnext.audio-playback-processor")
    private var tap: MTAudioProcessingTap?
    private var processingFormat: AudioStreamBasicDescription?
    private var spokenWordEnhancer: SpokenWordEnhancer?
    private var equalizer: EqualizerDSP?

    init(
        reduceSilenceGapsEnabled: Bool,
        silenceGapReductionLevel: SilenceGapReductionLevel,
        voiceEnhancementEnabled: Bool,
        equalizerPreset: EqualizerPreset = .flat,
        onSilenceReductionChanged: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.reduceSilenceGapsEnabled = reduceSilenceGapsEnabled
        self.silenceGapReductionLevel = silenceGapReductionLevel
        self.voiceEnhancementEnabled = voiceEnhancementEnabled
        self.equalizerPreset = equalizerPreset
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
            equalizer = equalizerPreset == .flat ? nil : EqualizerDSP(
                preset: equalizerPreset,
                sampleRate: processingFormat.mSampleRate,
                channelCount: Int(processingFormat.mChannelsPerFrame)
            )
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
        let (format, enhancer, equalizer) = stateQueue.sync {
            (processingFormat, spokenWordEnhancer, equalizer)
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
                let count: Int = byteCount / MemoryLayout<Float>.size
                for index in 0..<count {
                    var sample: Float = samples[index]
                    rmsAccumulator += sample * sample
                    rmsSampleCount += 1
                    let channel = channelOffset + Int(index % channelsInBuffer)
                    if let equalizer { sample = equalizer.process(sample, channel: channel) }
                    if let enhancer { sample = enhancer.process(sample: sample, channel: channel) }
                    samples[index] = sample
                }
            } else if isSignedInteger, format.mBitsPerChannel == 16 {
                let samples = data.bindMemory(to: Int16.self, capacity: byteCount / MemoryLayout<Int16>.size)
                let count: Int = byteCount / MemoryLayout<Int16>.size
                for index in 0..<count {
                    let normalized: Float = Float(samples[index]) / Float(Int16.max)
                    rmsAccumulator += normalized * normalized
                    rmsSampleCount += 1
                    let channel = channelOffset + Int(index % channelsInBuffer)
                    var processed = normalized
                    if let equalizer { processed = equalizer.process(processed, channel: channel) }
                    if let enhancer { processed = enhancer.process(sample: processed, channel: channel) }
                    samples[index] = Int16(max(Float(Int16.min), min(Float(Int16.max), processed * Float(Int16.max))))
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
