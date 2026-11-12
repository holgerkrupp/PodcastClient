import XCTest
@testable import UpNext

final class EqualizerDSPTests: XCTestCase {
    func testFlatPresetIsExactBypass() {
        let dsp = EqualizerDSP(preset: .flat, sampleRate: 48_000, channelCount: 2)
        for index in 0..<1_000 {
            let sample = Float(sin(Double(index) * 0.071))
            XCTAssertEqual(dsp.process(sample, channel: index % 2), sample)
        }
    }

    func testTonePresetsChangeSignalAndKeepOutputBelowHeadroom() {
        for preset in [EqualizerPreset.speechClarity, .warm, .bassCut] {
            let dsp = EqualizerDSP(preset: preset, sampleRate: 44_100, channelCount: 1)
            var changedSamples = 0
            for index in 0..<20_000 {
                let input = Float(0.8 * sin(2 * Double.pi * 140 * Double(index) / 44_100))
                let output = dsp.process(input, channel: 0)
                if abs(output - input) > 0.000_1 { changedSamples += 1 }
                XCTAssertLessThanOrEqual(abs(output), 0.891_251)
            }
            XCTAssertGreaterThan(changedSamples, 1_000, "\(preset) should make an audible tonal change")
        }
    }
}
