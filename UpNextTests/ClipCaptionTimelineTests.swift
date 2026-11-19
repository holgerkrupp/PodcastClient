import XCTest
#if canImport(UIKit)
import UIKit
import CoreVideo
import AVFoundation
#endif
@testable import UpNext

final class ClipCaptionTimelineTests: XCTestCase {
#if canImport(UIKit)
    @MainActor
    func testArtworkFrameChangesOnlyWhenCaptionIsSupplied() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let caption = ClipCaptionTimeline.Caption(text: "Hello world", location: 6, length: 5,
                                                   start: 1, end: 2, cueLevel: false)
        let plain = try XCTUnwrap(AudioClipExporter.createPixelBuffer(from: image, size: CGSize(width: 240, height: 240), progress: 0, startTime: 0, endTime: 10))
        let captioned = try XCTUnwrap(AudioClipExporter.createPixelBuffer(from: image, size: CGSize(width: 240, height: 240), progress: 0, startTime: 0, endTime: 10, caption: caption))
        func bytes(_ buffer: CVPixelBuffer) -> Data {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            return Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: CVPixelBufferGetDataSize(buffer))
        }
        XCTAssertNotEqual(bytes(plain), bytes(captioned))
    }

    @MainActor
    func testCaptionedArtworkAndVideoExportProducePlayableFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("fixture.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { samples[index] = 0.1 * sin(Float(index) * 0.1) }
        do {
            let audio = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try audio.write(from: buffer)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let timeline = ClipCaptionTimeline(captions: [
            .init(text: "hello world", location: 6, length: 5, start: 0.5, end: 1.5, cueLevel: false)
        ])
        let artwork = try await AudioClipExporter.exportClipAsync(
            audioURL: audioURL, coverImage: image, startTime: 0, endTime: 2,
            playbackRate: 1, fps: 10, videoSize: CGSize(width: 240, height: 240), progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: artwork) }
        let captionedArtwork = try await AudioClipExporter.exportClipAsync(
            audioURL: audioURL, coverImage: image, startTime: 0, endTime: 2,
            playbackRate: 1, fps: 10, videoSize: CGSize(width: 240, height: 240),
            captionTimeline: timeline, progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: captionedArtwork) }
        let fastArtwork = try await AudioClipExporter.exportClipAsync(
            audioURL: audioURL, coverImage: image, startTime: 0, endTime: 2,
            playbackRate: 2, fps: 10, videoSize: CGSize(width: 240, height: 240),
            captionTimeline: timeline, progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: fastArtwork) }
        let window = try await LiveTranscriptController.extractVideoAudioWindow(mediaURL: artwork, start: 0.5, duration: 1)
        defer { try? FileManager.default.removeItem(at: window.url.deletingLastPathComponent()) }
        XCTAssertEqual(window.startTime, 0.5, accuracy: 0.001)
        let windowDuration = try TranscriptAudioSampler.duration(of: window.url)
        XCTAssertEqual(windowDuration, 1, accuracy: 0.15)
        let video = try await AudioClipExporter.exportVideoClipAsync(
            videoURL: artwork, startTime: 0, endTime: 2, playbackRate: 2,
            captionTimeline: timeline, progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: video) }
        let normalVideo = try await AudioClipExporter.exportVideoClipAsync(
            videoURL: artwork, startTime: 0, endTime: 2, playbackRate: 1,
            captionTimeline: timeline, progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: normalVideo) }
        let plainVideo = try await AudioClipExporter.exportVideoClipAsync(
            videoURL: artwork, startTime: 0, endTime: 2, playbackRate: 2,
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: plainVideo) }
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let normalDuration = try await AVURLAsset(url: normalVideo).load(.duration).seconds
        let fastArtworkDuration = try await AVURLAsset(url: fastArtwork).load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(duration, 1, accuracy: 0.05)
        XCTAssertEqual(normalDuration, 2, accuracy: 0.08)
        XCTAssertEqual(fastArtworkDuration, 1, accuracy: 0.15)
        XCTAssertFalse(videoTracks.isEmpty)
        XCTAssertFalse(audioTracks.isEmpty)
        func frame(_ url: URL, seconds: Double) async throws -> CGImage {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            return result.image
        }
        func pixels(_ image: CGImage) throws -> [UInt8] {
            let width = image.width, height = image.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            try data.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return data
        }
        let captionPixels = try pixels(try await frame(video, seconds: 0.5))
        let plainPixels = try pixels(try await frame(plainVideo, seconds: 0.5))
        XCTAssertEqual(captionPixels.count, plainPixels.count)
        let difference = zip(captionPixels, plainPixels).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
        XCTAssertGreaterThan(difference / Double(captionPixels.count), 0.5)
        let before = try pixels(try await frame(video, seconds: 0.1))
        let plainBefore = try pixels(try await frame(plainVideo, seconds: 0.1))
        let beforeDifference = zip(before, plainBefore).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
        XCTAssertLessThan(beforeDifference, difference)
        let artworkCaption = try pixels(try await frame(captionedArtwork, seconds: 1))
        let artworkPlain = try pixels(try await frame(artwork, seconds: 1))
        let artworkDifference = zip(artworkCaption, artworkPlain).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
        XCTAssertGreaterThan(artworkDifference / Double(artworkCaption.count), 0.5)
    }
#endif
    func testTrimAndRateUseSourceMediaTime() throws {
        let segment = TranscriptSegmentBuilder.makeSegments(from: [
            TranscriptSegmentSource(text: "Hello world", startTime: 150, endTime: 160,
                timedSpans: [TranscriptTimedSpan(location: 6, length: 5, startTime: 157, endTime: 159)])
        ], options: .compact)
        let source = try XCTUnwrap(ClipCaptionTimeline.resolve(segments: segment, publisherAlignmentRequired: false, alignment: nil))
        let clipped = source.clipped(start: 150, end: 158, playbackRate: 2)
        let caption = try XCTUnwrap(clipped.captions.first)
        XCTAssertEqual(caption.start, 3.5, accuracy: 0.001)
        XCTAssertEqual(caption.end, 4, accuracy: 0.001)
        XCTAssertEqual(caption.location, 6)
        XCTAssertEqual(caption.length, 5)
        let midCue = source.clipped(start: 158, end: 160, playbackRate: 2)
        XCTAssertEqual(midCue.captions.first?.start, 0)
        XCTAssertEqual(midCue.captions.first?.end, 0.5)
    }

    func testGeneratedCaptionRequiresSameMediaFingerprint() throws {
        let snapshot = ClipTranscriptSnapshot(
            episodeID: "episode", origin: .generated(mediaFingerprint: "original"),
            lines: [TranscriptSegmentSource(text: "Hello", startTime: 1, endTime: 2)]
        )
        XCTAssertNil(ClipCaptionTimeline.resolve(snapshot: snapshot, mediaFingerprint: "replacement", publisherAlignment: nil))
        let matching = try XCTUnwrap(ClipCaptionTimeline.resolve(snapshot: snapshot, mediaFingerprint: "original", publisherAlignment: nil))
        XCTAssertEqual(matching.captions.count, 1)
        XCTAssertTrue(matching.captions[0].cueLevel)
    }

    func testPartialCoverageIsCarriedIntoClipTime() throws {
        let snapshot = ClipTranscriptSnapshot(
            episodeID: "episode", origin: .generated(mediaFingerprint: "media"),
            lines: [TranscriptSegmentSource(text: "Hello", startTime: 10, endTime: 12)],
            coverage: [.init(start: 8, end: 14)]
        )
        let source = try XCTUnwrap(ClipCaptionTimeline.resolve(snapshot: snapshot, mediaFingerprint: "media", publisherAlignment: nil))
        let clipped = source.clipped(start: 9, end: 15, playbackRate: 2)
        XCTAssertEqual(clipped.coverage, [.init(start: 0, end: 2.5)])
    }

    func testPublisherRequiresAlignmentAndDoesNotCaptionSponsorGap() throws {
        let segment = TranscriptSegmentBuilder.makeSegments(from: [
            TranscriptSegmentSource(text: "hello 👋", startTime: 25, endTime: 35)
        ], options: .compact)
        XCTAssertNil(ClipCaptionTimeline.resolve(segments: segment, publisherAlignmentRequired: true, alignment: nil))
        let alignment = try XCTUnwrap(TranscriptSynchronizationTimeline(
            anchors: [.init(transcriptTime: 0, audioTime: 0, confidence: 1),
                      .init(transcriptTime: 60, audioTime: 360, confidence: 1)],
            gaps: [.init(audioStart: 30, audioEnd: 330, transcriptTime: 30)]
        ))
        let timeline = try XCTUnwrap(ClipCaptionTimeline.resolve(segments: segment, publisherAlignmentRequired: true, alignment: alignment))
        XCTAssertEqual(timeline.captions.count, 2)
        XCTAssertNotNil(timeline.caption(atMediaTime: 29))
        XCTAssertNil(timeline.caption(atMediaTime: 30))
        XCTAssertNil(timeline.caption(atMediaTime: 200))
        XCTAssertNotNil(timeline.caption(atMediaTime: 330))
        let clipped = timeline.clipped(start: 28, end: 332, playbackRate: 2)
        XCTAssertEqual(clipped.captions[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(clipped.captions[0].end, 1, accuracy: 0.001)
        XCTAssertEqual(clipped.captions[1].start, 151, accuracy: 0.001)
        XCTAssertEqual(clipped.captions[1].end, 152, accuracy: 0.001)
    }

    func testUnmatchedPublisherSpeechIsNotExported() throws {
        let segments = TranscriptSegmentBuilder.makeSegments(from: [
            TranscriptSegmentSource(text: "unverified words", startTime: 25, endTime: 35)
        ], options: .compact)
        let alignment = try XCTUnwrap(TranscriptSynchronizationTimeline(
            anchors: [.init(transcriptTime: 0, audioTime: 0, confidence: 1),
                      .init(transcriptTime: 20, audioTime: 20, confidence: 1),
                      .init(transcriptTime: 40, audioTime: 50, confidence: 1),
                      .init(transcriptTime: 60, audioTime: 70, confidence: 1)],
            gaps: [.init(audioStart: 20, audioEnd: 50, transcriptTime: 20, transcriptEnd: 40)]
        ))
        let timeline = try XCTUnwrap(ClipCaptionTimeline.resolve(segments: segments, publisherAlignmentRequired: true, alignment: alignment))
        XCTAssertTrue(timeline.captions.isEmpty)
    }

    func testPublisherCaptionOutsideMatchedAnchorsIsOmitted() throws {
        let segments = TranscriptSegmentBuilder.makeSegments(from: [
            TranscriptSegmentSource(text: "outside coverage", startTime: 70, endTime: 80)
        ], options: .compact)
        let alignment = try XCTUnwrap(TranscriptSynchronizationTimeline(anchors: [
            .init(transcriptTime: 0, audioTime: 0, confidence: 1),
            .init(transcriptTime: 60, audioTime: 60, confidence: 1)
        ]))
        let timeline = try XCTUnwrap(ClipCaptionTimeline.resolve(segments: segments, publisherAlignmentRequired: true, alignment: alignment))
        XCTAssertTrue(timeline.captions.isEmpty)
    }
}
