#if DEBUG && canImport(UIKit)
import XCTest
import AVFoundation
import CoreAudio
@testable import UpNext

final class StreamAudioProbeTests: XCTestCase {
    @MainActor
    func testProgressiveHTTPPrototype() async throws {
        try await runStreamPrototype(path: "fixture.mp3", mixedOutput: false)
    }

    @MainActor
    func testProgressiveHTTPStallPrototype() async throws {
        try await runStreamPrototype(path: "slow/fixture.mp3", mixedOutput: false)
    }

    @MainActor
    func testHLSMixedOutputPrototype() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("Mixed-output HLS tap requires iOS 27.") }
        try await runStreamPrototype(path: "fixture.m3u8", mixedOutput: true)
    }

    @MainActor
    func testHLSPlaylistInsertionPrototype() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("Mixed-output HLS tap requires iOS 27.") }
        try await runStreamPrototype(path: "live/fixture.m3u8", mixedOutput: true)
    }

    @MainActor
    private func runStreamPrototype(path: String, mixedOutput: Bool) async throws {
        let url = URL(string: "http://127.0.0.1:18765/\(path)")!
        guard (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18765/stats")!)) != nil else {
            throw XCTSkip("Start the local synthetic stream fixture server to run this prototype.")
        }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let processor = AudioPlaybackProcessor(reduceSilenceGapsEnabled: false,
            silenceGapReductionLevel: .low, voiceEnhancementEnabled: false)
        let probe = StreamAudioProbe()
        processor.streamAudioProbe = probe
        let tap = try XCTUnwrap(processor.makeTap(useMixedOutput: mixedOutput))
        let parameters: AVMutableAudioMixInputParameters
        if mixedOutput {
            parameters = AVMutableAudioMixInputParameters()
        } else {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            parameters = AVMutableAudioMixInputParameters(track: try XCTUnwrap(tracks.first))
        }
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        let player = AVPlayer(playerItem: item)
        player.play()
        var waitingSamples = 0
        for _ in 0..<(path.hasPrefix("slow/") ? 8 : 5) {
            try await Task.sleep(for: .seconds(1))
            if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { waitingSamples += 1 }
        }
        let beforeSeek = probe.snapshot()
        let beforeTime = player.currentTime().seconds
        let itemStatus = item.status.rawValue
        let playerStatus = player.timeControlStatus.rawValue
        await player.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
        try await Task.sleep(for: .seconds(2))
        player.pause()
        let result = probe.snapshot()
        let scenario = path.hasPrefix("slow/") ? "http_stall" : (path.hasPrefix("live/") ? "hls_insertion" : (mixedOutput ? "hls" : "http"))
        print("stream_probe kind=\(scenario) samples_before_seek=\(beforeSeek.samples.count) samples_after_seek=\(result.samples.count) timestamp_available=\(result.startTime != nil) discontinuities=\(result.discontinuities) truncated=\(result.truncatedFrames) rate=\(result.sampleRate) player_time=\(beforeTime) waiting_samples=\(waitingSamples) item_status=\(itemStatus) player_status=\(playerStatus) item_error=\(item.error != nil)")
        if path.hasPrefix("live/"), let (data, _) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18765/stats")!) {
            print("stream_probe_live_fixture \(String(decoding: data, as: UTF8.self))")
        }
        XCTAssertLessThanOrEqual(result.samples.count, 480_000)
        if !result.samples.isEmpty, result.sampleRate > 0,
           let locale = await AITranscripts.installedLocale(matching: "en-US"),
           let format = AVAudioFormat(standardFormatWithSampleRate: result.sampleRate, channels: 1),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(result.samples.count)),
           let target = buffer.floatChannelData?[0] {
            buffer.frameLength = AVAudioFrameCount(result.samples.count)
            for index in result.samples.indices { target[index] = result.samples[index] }
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            defer { try? FileManager.default.removeItem(at: fileURL) }
            do {
                let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
                try file.write(from: buffer)
            }
            let started = ContinuousClock.now
            let transcriber = await AITranscripts(url: fileURL, language: locale, allowModelDownload: false, diagnosticPurpose: "stream_prototype")
            let recognized = try? await transcriber.transcribe()
            let elapsed = started.duration(to: .now).components
            print("stream_probe_recognition kind=\(mixedOutput ? "hls" : "http") audio_seconds=\(Double(result.samples.count) / result.sampleRate) elapsed_seconds=\(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) produced_text=\(recognized?.isEmpty == false)")
        } else {
            print("stream_probe_recognition kind=\(mixedOutput ? "hls" : "http") unavailable=true")
        }
        withExtendedLifetime(processor) {}
    }

    func testProbeCapturesTimedPCMAndResetsOnSeek() {
        let probe = StreamAudioProbe()
        let format = AudioStreamBasicDescription(mSampleRate: 10, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        func capture(_ values: [Float], at time: Double) {
            var mutable = values
            mutable.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
                    mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                withUnsafeMutablePointer(to: &list) {
                    probe.capture($0, frames: values.count, format: format,
                        timeRange: CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 600),
                                               duration: CMTime(seconds: Double(values.count) / 10, preferredTimescale: 600)))
                }
            }
        }
        capture([0.1, 0.2], at: 4)
        capture([0.3, 0.4], at: 4.2)
        let first = probe.snapshot()
        XCTAssertEqual(first.samples, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(first.startTime, 4)
        capture([0.7], at: 20)
        let afterSeek = probe.snapshot()
        XCTAssertEqual(afterSeek.samples, [0.7])
        XCTAssertEqual(afterSeek.startTime, 20)
        XCTAssertEqual(afterSeek.discontinuities, 1)
    }
}
#endif
