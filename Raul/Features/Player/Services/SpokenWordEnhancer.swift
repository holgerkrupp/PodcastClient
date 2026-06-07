import Foundation

final class SpokenWordEnhancer: @unchecked Sendable {
    private struct ChannelState {
        var highPassInput: Float = 0
        var highPassOutput: Float = 0
        var compressorEnvelope: Float = 0
        var limiterGain: Float = 1
    }

    private let sampleRate: Float
    private let channelCount: Int
    private let highPassCoefficient: Float
    private let loudnessCoefficient: Float
    private let compressorAttackCoefficient: Float
    private let compressorReleaseCoefficient: Float
    private let limiterReleaseCoefficient: Float
    private let gainIncreaseCoefficient: Float
    private let gainReductionCoefficient: Float
    private var channelStates: [ChannelState]

    private var measuredPower: Float
    private(set) var currentGain: Float = 1

    private static let targetLevelDecibels: Float = -18
    private static let silenceGateDecibels: Float = -55
    private static let maximumGainDecibels: Float = 12
    private static let minimumGainDecibels: Float = -6
    private static let compressorThresholdDecibels: Float = -12
    private static let compressorRatio: Float = 2.25
    private static let limiterCeilingDecibels: Float = -1

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = Float(max(sampleRate, 8_000))
        self.channelCount = max(channelCount, 1)
        channelStates = Array(repeating: ChannelState(), count: self.channelCount)

        let targetAmplitude = Self.amplitude(forDecibels: Self.targetLevelDecibels)
        measuredPower = targetAmplitude * targetAmplitude

        highPassCoefficient = Self.highPassCoefficient(
            cutoff: 80,
            sampleRate: self.sampleRate
        )
        loudnessCoefficient = Self.smoothingCoefficient(
            duration: 0.4,
            sampleRate: self.sampleRate,
            channelCount: self.channelCount
        )
        compressorAttackCoefficient = Self.smoothingCoefficient(
            duration: 0.025,
            sampleRate: self.sampleRate,
            channelCount: 1
        )
        compressorReleaseCoefficient = Self.smoothingCoefficient(
            duration: 0.3,
            sampleRate: self.sampleRate,
            channelCount: 1
        )
        limiterReleaseCoefficient = Self.smoothingCoefficient(
            duration: 0.1,
            sampleRate: self.sampleRate,
            channelCount: 1
        )
        gainIncreaseCoefficient = Self.smoothingCoefficient(
            duration: 2.5,
            sampleRate: self.sampleRate,
            channelCount: self.channelCount
        )
        gainReductionCoefficient = Self.smoothingCoefficient(
            duration: 0.35,
            sampleRate: self.sampleRate,
            channelCount: self.channelCount
        )
    }

    func reset() {
        channelStates = Array(repeating: ChannelState(), count: channelCount)
        let targetAmplitude = Self.amplitude(forDecibels: Self.targetLevelDecibels)
        measuredPower = targetAmplitude * targetAmplitude
        currentGain = 1
    }

    func process(sample: Float, channel: Int) -> Float {
        let channelIndex = min(max(channel, 0), channelStates.count - 1)
        var state = channelStates[channelIndex]

        let highPassed = highPassCoefficient * (
            state.highPassOutput + sample - state.highPassInput
        )
        state.highPassInput = sample
        state.highPassOutput = highPassed

        let samplePower = highPassed * highPassed
        measuredPower += loudnessCoefficient * (samplePower - measuredPower)

        let measuredAmplitude = sqrt(max(measuredPower, 0.000_000_001))
        if measuredAmplitude >= Self.amplitude(forDecibels: Self.silenceGateDecibels) {
            let desiredGain = min(
                Self.amplitude(forDecibels: Self.maximumGainDecibels),
                max(
                    Self.amplitude(forDecibels: Self.minimumGainDecibels),
                    Self.amplitude(forDecibels: Self.targetLevelDecibels) / measuredAmplitude
                )
            )
            let coefficient = desiredGain < currentGain
                ? gainReductionCoefficient
                : gainIncreaseCoefficient
            currentGain += coefficient * (desiredGain - currentGain)
        }

        var output = highPassed * currentGain
        let absoluteOutput = abs(output)
        let envelopeCoefficient = absoluteOutput > state.compressorEnvelope
            ? compressorAttackCoefficient
            : compressorReleaseCoefficient
        state.compressorEnvelope += envelopeCoefficient * (
            absoluteOutput - state.compressorEnvelope
        )

        let compressorThreshold = Self.amplitude(
            forDecibels: Self.compressorThresholdDecibels
        )
        if state.compressorEnvelope > compressorThreshold {
            let envelopeDecibels = Self.decibels(forAmplitude: state.compressorEnvelope)
            let compressedDecibels = Self.compressorThresholdDecibels
                + (envelopeDecibels - Self.compressorThresholdDecibels)
                / Self.compressorRatio
            let gainReduction = Self.amplitude(
                forDecibels: compressedDecibels - envelopeDecibels
            )
            output *= gainReduction
        }

        let limiterCeiling = Self.amplitude(forDecibels: Self.limiterCeilingDecibels)
        let requiredLimiterGain = abs(output) > limiterCeiling
            ? limiterCeiling / max(abs(output), 0.000_001)
            : 1
        if requiredLimiterGain < state.limiterGain {
            state.limiterGain = requiredLimiterGain
        } else {
            state.limiterGain += limiterReleaseCoefficient * (1 - state.limiterGain)
        }
        output *= state.limiterGain

        channelStates[channelIndex] = state
        return min(limiterCeiling, max(-limiterCeiling, output))
    }

    private static func amplitude(forDecibels decibels: Float) -> Float {
        pow(10, decibels / 20)
    }

    private static func decibels(forAmplitude amplitude: Float) -> Float {
        20 * log10(max(amplitude, 0.000_001))
    }

    private static func smoothingCoefficient(
        duration: Float,
        sampleRate: Float,
        channelCount: Int
    ) -> Float {
        1 - exp(-1 / max(duration * sampleRate * Float(channelCount), 1))
    }

    private static func highPassCoefficient(cutoff: Float, sampleRate: Float) -> Float {
        let timeConstant = 1 / (2 * Float.pi * cutoff)
        let sampleDuration = 1 / sampleRate
        return timeConstant / (timeConstant + sampleDuration)
    }
}
