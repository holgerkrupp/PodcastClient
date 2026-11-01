import AVFoundation
import Foundation
import Testing
@testable import UpNext

@Suite("AI generation workload")
struct AIGenerationWorkloadTests {
    private func cue(_ text: String, at start: TimeInterval, speaker: String? = nil) -> TranscriptLineSnapshot {
        TranscriptLineSnapshot(speaker: speaker, text: text, startTime: start, endTime: start + 1.2)
    }

    @Test func coalescingKeepsAllTextAndFirstTimestamps() {
        let lines = (0..<100).map { cue("word\($0) word word", at: Double($0) * 1.2) }
        let blocks = TranscriptPromptCoalescer.coalesce(lines)

        #expect(blocks.count < lines.count / 5)
        #expect(blocks.first?.startTime == 0)
        #expect(blocks.last?.endTime == lines.last?.endTime)
        #expect(blocks.map(\.text).joined(separator: " ") == lines.map(\.text).joined(separator: " "))
        for (block, next) in zip(blocks, blocks.dropFirst()) {
            #expect(next.startTime - block.startTime <= TranscriptPromptCoalescer.maximumBlockDuration + 1.2)
        }
    }

    @Test func coalescingSplitsOnSpeakerAndSentence() {
        let speakers = TranscriptPromptCoalescer.coalesce([
            cue("hello", at: 0, speaker: "A"),
            cue("there", at: 1, speaker: "B")
        ])
        #expect(speakers.map(\.speaker) == ["A", "B"])

        let sentences = TranscriptPromptCoalescer.coalesce([
            cue("One sentence.", at: 0),
            cue("Too soon.", at: 3),
            cue("New block", at: 7)
        ])
        #expect(sentences.map(\.text) == ["One sentence. Too soon.", "New block"])
    }

    @Test func shownotesWithoutTimestampsSkipTheModel() {
        #expect(ChapterSourcePolicy.mayContainChapterTimecodes("Our guest talks about books.") == false)
        #expect(ChapterSourcePolicy.mayContainChapterTimecodes("Recorded at 10:30 in Berlin.") == false)
        #expect(ChapterSourcePolicy.mayContainChapterTimecodes("00:00 Intro\n12:45 Main topic"))
        #expect(ChapterSourcePolicy.mayContainChapterTimecodes("01:02:03 Intro 01:20:00 Outro"))
    }

    @Test func secondChapterPassWaitsForTheRunningOne() async {
        let registry = GeneratedChapterWorkRegistry()
        let url = URL(string: "https://example.com/episode.mp3")!

        #expect(await registry.claim(url) == .owner)
        let waiter = Task { await registry.claim(url) }
        try? await Task.sleep(for: .milliseconds(50))
        await registry.finish(url, result: true)
        #expect(await waiter.value == .completed(true))
        #expect(await registry.claim(url) == .owner)
        await registry.finish(url, result: false)
    }

    @Test func cancelledChapterPassHandsWorkToTheWaiter() async {
        let registry = GeneratedChapterWorkRegistry()
        let url = URL(string: "https://example.com/episode.mp3")!

        #expect(await registry.claim(url) == .owner)
        let waiter = Task { await registry.claim(url) }
        try? await Task.sleep(for: .milliseconds(50))
        await registry.finish(url, result: nil)
        #expect(await waiter.value == .owner)
        await registry.finish(url, result: true)
    }

    @Test func checkpointResumesAcrossAppendsAndSurvivesTornLine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let media = directory.appendingPathComponent("episode.mp3")
        try Data([1, 2, 3]).write(to: media)

        let checkpoint = try #require(TranscriptionCheckpoint(
            mediaURL: media,
            localeIdentifier: "de-DE",
            maxSnippetDurationSeconds: 1.2,
            maxWordsPerSnippet: 3,
            directory: directory
        ))
        let first = TranscriptionCheckpoint.Segment(start: 0, end: 1.5, text: "Hallo Welt")
        let second = TranscriptionCheckpoint.Segment(start: 1.5, end: 2.5, text: "zweite\nZeile")
        checkpoint.append([first])
        checkpoint.append([second])
        #expect(checkpoint.load() == [first, second])

        let handle = try FileHandle(forWritingTo: checkpoint.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"start\":2.5,\"en".utf8))
        try handle.close()
        #expect(checkpoint.load() == [first, second])

        checkpoint.remove()
        #expect(checkpoint.load().isEmpty)
    }

    @Test func checkpointIdentityFollowsTheFileAndSettings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let media = directory.appendingPathComponent("episode.mp3")
        try Data([1, 2, 3]).write(to: media)

        func make(_ locale: String) -> URL? {
            // A fresh URL, because URL caches the resource values it has read.
            TranscriptionCheckpoint(
                mediaURL: URL(fileURLWithPath: media.path),
                localeIdentifier: locale,
                maxSnippetDurationSeconds: 1.2,
                maxWordsPerSnippet: 3,
                directory: directory
            )?.fileURL
        }
        let original = make("de-DE")
        #expect(original == make("de-DE"))
        #expect(original != make("en-US"))
        try Data([1, 2, 3, 4]).write(to: media)
        #expect(original != make("de-DE"))
    }

    @Test func staleCheckpointsAreRemoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("old.jsonl")
        try Data().write(to: file)

        TranscriptionCheckpoint.removeStale(in: directory)
        #expect(FileManager.default.fileExists(atPath: file.path))
        TranscriptionCheckpoint.removeStale(
            in: directory,
            now: Date().addingTimeInterval(TranscriptionCheckpoint.maximumAge + 60)
        )
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    /// Ramp samples make each frame identifiable, so a wrong carry-over shows up.
    private func makeRampFile(seconds: Int, sampleRate: Double = 8_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ramp-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let frames = AVAudioFrameCount(Double(seconds) * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(index) / Float(frames)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @Test(arguments: [(10.0, 5.0), (10.0, 10.0), (10.0, 3.0)])
    func slidingWindowsMatchIndependentReads(window: TimeInterval, hop: TimeInterval) async throws {
        let url = try makeRampFile(seconds: 32)
        defer { try? FileManager.default.removeItem(at: url) }

        var chunks: [PCMAnalysisChunk] = []
        try await AVAudioFileAnalysisSource(url: url).forEachChunk(
            in: AdTimeRange(start: 2, end: 30),
            windowDuration: window,
            hopDuration: hop
        ) { chunks.append($0) }

        let file = try AVAudioFile(forReading: url)
        var offset = 2.0
        var expectedCount = 0
        while offset < 30 {
            let length = min(window, 30 - offset)
            try #require(chunks.count > expectedCount)
            let chunk = chunks[expectedCount]
            #expect(chunk.start == offset)
            #expect(abs(chunk.duration - length) < 0.01)
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(length * 8_000)
            ))
            file.framePosition = AVAudioFramePosition(offset * 8_000)
            var expected: [Float] = []
            while expected.count < Int(length * 8_000) {
                try file.read(
                    into: buffer,
                    frameCount: AVAudioFrameCount(length * 8_000) - AVAudioFrameCount(expected.count)
                )
                guard buffer.frameLength > 0 else { break }
                expected.append(contentsOf: UnsafeBufferPointer(
                    start: buffer.floatChannelData![0],
                    count: Int(buffer.frameLength)
                ))
            }
            #expect(chunk.samples == expected)
            expectedCount += 1
            offset += hop
        }
        #expect(chunks.count == expectedCount)
    }

    @Test func throttlePausesFollowMeasuredSpeed() {
        let throttle = AITranscripts.Throttle.backgroundFriendly

        // Fast device: the pace is capped at the minimum cycle.
        #expect(throttle.pauseSeconds(estimatedBusySeconds: 0.3, elapsed: 0.3) == 4.7)
        // In between: the analyzer gets its target share of the cycle.
        #expect(throttle.pauseSeconds(estimatedBusySeconds: 3, elapsed: 1.5) == 10.5)
        // Near realtime: never slower than the old fixed 18 seconds.
        #expect(throttle.pauseSeconds(estimatedBusySeconds: 15, elapsed: 7.5) == 10.5)
        // Nothing reported, such as music or silence: only a short rest is left.
        #expect(throttle.pauseSeconds(estimatedBusySeconds: 18, elapsed: 18) == 1)
    }

    @Test func throttleScalesBusyTimeToTheWholeChunk() {
        let throttle = AITranscripts.Throttle.backgroundFriendly
        #expect(throttle.estimatedBusySeconds(elapsed: 1, coveredAudioSeconds: 7.5) == 2)
        #expect(throttle.estimatedBusySeconds(elapsed: 18, coveredAudioSeconds: 0) == 18)
    }

    private func makeRetryQueue() -> GeneratedChapterRetryQueue {
        GeneratedChapterRetryQueue(defaults: UserDefaults(suiteName: "chapter-retry-\(UUID().uuidString)")!)
    }

    @Test func chapterRetryBacksOffThenGivesUp() async {
        let queue = makeRetryQueue()
        let url = URL(string: "https://example.com/episode.mp3")!
        var now = Date(timeIntervalSince1970: 1_000)

        for attempt in 1..<GeneratedChapterRetryQueue.maximumAttempts {
            await queue.enqueue(url, reason: .transient, now: now)
            #expect(await queue.nextDue(now: now) == nil)
            now += GeneratedChapterRetryQueue.baseBackoff * pow(2, Double(attempt - 1))
            #expect(await queue.nextDue(now: now) == url)
        }
        await queue.enqueue(url, reason: .transient, now: now)
        #expect(await queue.nextDue(now: now.addingTimeInterval(86_400 * 30)) == nil)
    }

    @Test func cancelledChapterPassDoesNotUseUpAttempts() async {
        let queue = makeRetryQueue()
        let url = URL(string: "https://example.com/episode.mp3")!
        let now = Date(timeIntervalSince1970: 1_000)

        for _ in 0..<(GeneratedChapterRetryQueue.maximumAttempts * 2) {
            await queue.enqueue(url, reason: .cancelled, now: now)
        }
        let due = now.addingTimeInterval(GeneratedChapterRetryQueue.cancelledBackoff)
        #expect(await queue.nextDue(now: due) == url)
    }

    @Test func userCancelledChapterPassIsNotRetried() async {
        let queue = makeRetryQueue()
        let url = URL(string: "https://example.com/episode.mp3")!
        let now = Date(timeIntervalSince1970: 1_000)

        await queue.dismiss(url)
        await queue.enqueue(url, reason: .cancelled, now: now)
        #expect(await queue.nextDue(now: now.addingTimeInterval(86_400)) == nil)
    }

    @Test func chapterRetrySurvivesRelaunch() async {
        let suite = "chapter-retry-\(UUID().uuidString)"
        let url = URL(string: "https://example.com/episode.mp3")!
        let now = Date(timeIntervalSince1970: 1_000)

        await GeneratedChapterRetryQueue(defaults: UserDefaults(suiteName: suite)!).enqueue(url, reason: .cancelled, now: now)
        let due = now.addingTimeInterval(GeneratedChapterRetryQueue.cancelledBackoff)
        #expect(await GeneratedChapterRetryQueue(defaults: UserDefaults(suiteName: suite)!).nextDue(now: due) == url)
    }
}
