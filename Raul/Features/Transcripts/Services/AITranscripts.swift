//
//  AITranscripts.swift
//  Raul
//
//  Created by Holger Krupp on 03.07.25.
//

import Foundation
import AVFoundation
import Speech
import OSLog
import os

/// The supported languages only change with an OS or asset update. Short sampling
/// runs create one transcriber per seven seconds of audio, each of which used to
/// repeat this XPC query.
private actor SupportedSpeechLocales {
    static let shared = SupportedSpeechLocales()
    private var locales: [Locale]?

    func value() async -> [Locale] {
        if let locales { return locales }
        let fetched = await SpeechTranscriber.supportedLocales
        locales = fetched
        return fetched
    }
}

@Observable
class AITranscripts {
    private static let ioLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PodcastClient", category: "TranscriptionIO")
    /// Controls input throttling (duty-cycling) while feeding audio to the analyzer.
    /// Automatic/background runs pause between chunks so the Speech XPC's rolling CPU
    /// average stays under iOS's 50%/180s background CPU monitor. Manual runs use `.none`.
    ///
    /// The pause follows the analyzer's measured speed. A fixed pause has to assume a
    /// slow device, which left a fast one idle most of the time: an hour of audio took
    /// 72 minutes, longer than a background window, and the work was often cancelled
    /// before it finished. The total analyzer work is the same either way.
    struct Throttle: Sendable {
        /// Seconds of audio fed per chunk before pausing.
        var chunkSeconds: Double
        /// Slowest pace, from one chunk to the next. `0` means no throttling.
        var maximumCycleSeconds: Double
        /// Fastest pace. Five seconds per 15-second chunk fits an hour of audio
        /// into a 20-minute background pass.
        var minimumCycleSeconds: Double
        /// Share of each cycle the analyzer may be busy, well under the monitor's 50%.
        var targetDutyCycle: Double

        static let none = Throttle(
            chunkSeconds: 0,
            maximumCycleSeconds: 0,
            minimumCycleSeconds: 0,
            targetDutyCycle: 1
        )
        static let backgroundFriendly = Throttle(
            chunkSeconds: 15,
            maximumCycleSeconds: 18,
            minimumCycleSeconds: 5,
            targetDutyCycle: 0.25
        )

        var isEnabled: Bool { chunkSeconds > 0 && maximumCycleSeconds > 0 }

        /// How long to sleep after a chunk. `elapsed` has already passed since it was fed.
        func pauseSeconds(estimatedBusySeconds: Double, elapsed: Double) -> Double {
            let cycle = min(
                max(estimatedBusySeconds / targetDutyCycle, minimumCycleSeconds),
                maximumCycleSeconds
            )
            return max(cycle - elapsed, 1)
        }

        /// The analyzer's busy time for a whole chunk, scaled up from the part it has
        /// reported. Results end on sentence boundaries, so the last words of a chunk
        /// may only be reported once the next chunk arrives.
        func estimatedBusySeconds(elapsed: Double, coveredAudioSeconds: Double) -> Double {
            guard coveredAudioSeconds > 0 else { return elapsed }
            return elapsed * chunkSeconds / coveredAudioSeconds
        }
    }

    //MARK: INPUT
    let url: URL
    var language: Locale = Locale.current
    let maxSnippetDurationSeconds: Double
    let maxWordsPerSnippet: Int
    let analyzerPriority: TaskPriority
    let throttle: Throttle
    let allowModelDownload: Bool
    let modelRetention: SpeechAnalyzer.Options.ModelRetention
    /// Throttled runs save progress and resume from it; a finished run clears it.
    let usesCheckpoint: Bool
    /// Identifies the feature path in local diagnostics without recording media URLs or transcript text.
    let diagnosticPurpose: String
    let progressHandler: (@Sendable (_ progress: Double, _ status: String) async -> Void)?


    //MARK: OUTPUT
    var transcript: [SFTranscriptionSegment] = []

    // Cached async lookup — each Speech framework query is an XPC round-trip, and the
    // old code re-fetched installed locales several times per job.
    private var cachedInstalledLocaleIDs: Set<String>?
    private var didResolveLanguage = false

    init(
        url: URL,
        language: String? = nil,
        maxSnippetDurationSeconds: Double = 1.2,
        maxWordsPerSnippet: Int = 3,
        analyzerPriority: TaskPriority = .userInitiated,
        throttle: Throttle = .none,
        allowModelDownload: Bool = true,
        modelRetention: SpeechAnalyzer.Options.ModelRetention = .whileInUse,
        diagnosticPurpose: String = "unspecified",
        usesCheckpoint: Bool = false,
        progressHandler: (@Sendable (_ progress: Double, _ status: String) async -> Void)? = nil
    ) async {
        self.url = url
        self.maxSnippetDurationSeconds = min(max(maxSnippetDurationSeconds, 0.4), 8.0)
        self.maxWordsPerSnippet = max(maxWordsPerSnippet, 1)
        self.analyzerPriority = analyzerPriority
        self.throttle = throttle
        self.allowModelDownload = allowModelDownload
        self.modelRetention = modelRetention
        self.usesCheckpoint = usesCheckpoint
        self.diagnosticPurpose = diagnosticPurpose
        self.progressHandler = progressHandler
        self.language = language.map { Locale(identifier: $0) } ?? Locale.current
        await resolveLanguageIfNeeded()
    }

    /// Resolves `language` to a supported locale exactly once for the lifetime of the job.
    private func resolveLanguageIfNeeded() async {
        guard didResolveLanguage == false else { return }
        language = await bestMatchingSupportedLocale(for: language.identifier(.bcp47)) ?? Locale.current
        didResolveLanguage = true
    }

    private func supportedLocales() async -> [Locale] {
        await SupportedSpeechLocales.shared.value()
    }
    
    func requestAuthorization() async {
        SFSpeechRecognizer.requestAuthorization { authStatus in



           OperationQueue.main.addOperation {
              switch authStatus {
                 case .authorized:
                     print("authorized")


                 case .denied:
                   print("denied")


                 case .restricted:
                   print("restricted")


                 case .notDetermined:
                   print("notDetermined")
              @unknown default:
                   print("default")
              }
           }
        }
    }
    
    func logEpisodeTitle(for url: URL) async {
        guard let container = await MainActor.run(body: {
            ModelContainerManager.shared.preparedContainer
        }) else {
            return
        }
        _ = await EpisodeActor(modelContainer: container).getEpisodeTitlefrom(url: url)
    }
    
    /// Maps language codes to preferred region-specific locales if present in supportedLocales.
    static func regionPreferredLocale(for language: String, supportedLocales: [String]) -> String {
        let preferred: [String: String] = [
            "de": "de-DE",
            "en": "en-US", // 'en-EN' does not exist; 'en-US' or 'en-GB' are standard
            "fr": "fr-FR",
            "it": "it-IT",
            "es": "es-ES"
        ]
        if let mapped = preferred[language.lowercased()], supportedLocales.contains(mapped) {
            return mapped
        }
        // If language-only is in supportedLocales, return that
        if supportedLocales.contains(language.lowercased()) {
            return language.lowercased()
        }
        // Otherwise, try to find any supported locale starting with the language code
        if let found = supportedLocales.first(where: { $0.lowercased().hasPrefix(language.lowercased() + "-") }) {
            return found
        }
        // Fallback to input
        return language
    }
    
    
    func transcribeTovTT() async throws -> String? {
        await resolveLanguageIfNeeded()
        await reportProgress(0.02, status: "Preparing audio…")
        // print("language finished")
        
        guard let segments = try await transcribe() else { return nil }
         print("transcript finished with \(segments.count) segments")
        
        
        let formatted = segments.map { segment in
            let start = formatCMTime(segment.range.start)
            let end = formatCMTime(segment.range.end)
            let text = segment.text.hasSuffix("{\n}") ? String(segment.text.dropLast(3)) : segment.text
            
            return "\(start) --> \(end)\n\(text)"
        }.joined(separator: "\n\n")
        
        let result = "WEBVTT\n\n" + formatted

        
        return result
    }
    
    
    
    func transcribe() async throws -> [(range: CMTimeRange, text: String)]?{
        try Task.checkCancellation()
       
        guard let audioFile = try? AVAudioFile(forReading: url) else {
             print("could not load audio file")
            return nil }

        let audioDuration = transcriptionDuration(for: audioFile)
        let sourceBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let startedAt = ContinuousClock.now
        Self.ioLogger.info("transcription_started purpose=\(self.diagnosticPurpose, privacy: .public) bytes=\(sourceBytes) audio_seconds=\(audioDuration, format: .fixed(precision: 2)) throttled=\(self.throttle.isEnabled, privacy: .public)")

        await resolveLanguageIfNeeded()
        print("transcribe to lang: \(language.identifier(.bcp47))")

        let locale = self.language
        // Request only what the VTT output consumes: final results with audio time ranges
        // and punctuation. Skipping volatile results, alternatives, and confidence avoids
        // extra per-result compute in the Speech XPC (the `.transcription` preset bundles
        // more than this pipeline reads — it only uses `result.range` and `result.text`).
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        
        print("normalized:", locale.identifier(.bcp47))
        
        await reportProgress(0.05, status: "Checking speech model…")
        if allowModelDownload {
            do {
                try await ensureModel(transcriber: transcriber, locale: locale)
            } catch {
                print(error)
                return nil
            }
        } else if await installed(locale: locale) == false {
            return nil
        }
        try Task.checkCancellation()
        print("model ensured")
        await reportProgress(0.1, status: "Starting transcription…")

         let isInstalled = await installed(locale: locale)
        guard isInstalled else {
            return nil
        }
        try Task.checkCancellation()
        assert(isInstalled, "Locale should be installed after ensureModel")
        
        
    print("1")
        
        let checkpoint = usesCheckpoint
            ? TranscriptionCheckpoint(
                mediaURL: url,
                localeIdentifier: locale.identifier(.bcp47),
                maxSnippetDurationSeconds: maxSnippetDurationSeconds,
                maxWordsPerSnippet: maxWordsPerSnippet
            )
            : nil
        if checkpoint != nil {
            TranscriptionCheckpoint.removeStale()
        }
        // Only the chunked path can start partway through the file.
        let savingCheckpoint = throttle.isEnabled ? checkpoint : nil
        var savedSegments = savingCheckpoint?.load() ?? []
        if let lastEnd = savedSegments.last?.end, lastEnd >= audioDuration - 1 {
            savedSegments = []
            checkpoint?.remove()
        }
        let resumedSegments = savedSegments
        let resumeSeconds = resumedSegments.last?.end ?? 0
        if resumeSeconds > 0 {
            Self.ioLogger.info("transcription_resumed purpose=\(self.diagnosticPurpose, privacy: .public) audio_seconds=\(resumeSeconds, format: .fixed(precision: 2))")
        }

        let progressReporter = self.progressHandler
        let configuredMaxSnippetDurationSeconds = self.maxSnippetDurationSeconds
        let configuredMaxWordsPerSnippet = self.maxWordsPerSnippet
        let reportedAudioEnd = OSAllocatedUnfairLock(initialState: resumeSeconds)
        async let transcriptionFuture = Self.collectTranscriptionResults(
            from: transcriber,
            resumedSegments: resumedSegments,
            checkpoint: savingCheckpoint,
            reportedAudioEnd: reportedAudioEnd,
            audioDuration: audioDuration,
            maxSnippetDurationSeconds: configuredMaxSnippetDurationSeconds,
            maxWordsPerSnippet: configuredMaxWordsPerSnippet,
            progressHandler: progressReporter
        )
        print("2")
        
        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            print("Warning: could not reserve locale \(locale). \(error)")
            // Optionally proceed if errors are non-fatal
        }
        try Task.checkCancellation()

        // Setting the analyzer's priority propagates QoS into the Speech XPC process,
        // steering it onto performance vs efficiency cores. Release the model when the
        // job ends to keep the resident footprint small.
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: analyzerPriority, modelRetention: modelRetention)
        )

        print(transcriber.selectedLocales)
        print("3")

        do {
            if throttle.isEnabled,
               let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
                // Duty-cycled path: feed the file in bounded chunks with pauses so the
                // Speech XPC's rolling CPU average stays under the background monitor.
                try await analyzeThrottled(
                    analyzer: analyzer,
                    audioFile: audioFile,
                    analyzerFormat: analyzerFormat,
                    throttle: throttle,
                    resumeSeconds: resumeSeconds,
                    reportedAudioEnd: reportedAudioEnd
                )
            } else if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                // Continuous path: fastest wall-clock, used for user-initiated runs.
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
        print("4")
        try Task.checkCancellation()
        await reportProgress(0.92, status: "Finalizing transcript…")
        let transcription = try await transcriptionFuture
        checkpoint?.remove()

        let elapsed = startedAt.duration(to: .now).components
        let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        Self.ioLogger.info("transcription_finished purpose=\(self.diagnosticPurpose, privacy: .public) bytes=\(sourceBytes) audio_seconds=\(audioDuration, format: .fixed(precision: 2)) elapsed_seconds=\(elapsedSeconds, format: .fixed(precision: 2)) result_count=\(transcription.count ?? 0)")

        return transcription
    }

    /// Feeds the audio file to the analyzer in bounded chunks, pausing between them.
    /// The pause lets the Speech XPC go idle, dropping its rolling CPU average below
    /// iOS's background CPU monitor threshold at the cost of longer wall-clock time.
    private func analyzeThrottled(
        analyzer: SpeechAnalyzer,
        audioFile: AVAudioFile,
        analyzerFormat: AVAudioFormat,
        throttle: Throttle,
        resumeSeconds: Double,
        reportedAudioEnd: OSAllocatedUnfairLock<Double>
    ) async throws {
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputSequence)

        let readingFormat = audioFile.processingFormat
        let sampleRate = readingFormat.sampleRate
        // Result times stay absolute because each buffer carries its file position.
        audioFile.framePosition = AVAudioFramePosition(resumeSeconds * sampleRate)
        let framesPerChunk = AVAudioFrameCount(max(sampleRate * throttle.chunkSeconds, 1))
        var fedFrames: Int64 = 0
        let analyzerTimescale = CMTimeScale(analyzerFormat.sampleRate)
        var analyzerFramePosition = Int64(resumeSeconds * analyzerFormat.sampleRate)
        var cycleCount = 0
        let feedStartedAt = ContinuousClock.now
        // One converter instance reused across chunks so sample-rate conversion state
        // carries over and there are no artifacts at chunk boundaries.
        let converter = readingFormat == analyzerFormat
            ? nil
            : AVAudioConverter(from: readingFormat, to: analyzerFormat)

        do {
            while true {
                try Task.checkCancellation()
                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: readingFormat, frameCapacity: framesPerChunk) else { break }
                let startFrame = audioFile.framePosition
                try audioFile.read(into: inputBuffer, frameCount: framesPerChunk)
                guard inputBuffer.frameLength > 0 else { break }

                let outputBuffer = try Self.convert(inputBuffer, using: converter, to: analyzerFormat)
                // Count what the analyzer has received, not the position in the source
                // file. A resampler's output length varies by a few frames per call, so
                // a file-based time can overlap the previous buffer, which the analyzer
                // rejects with "timestamp overlaps or precedes prior audio input".
                let bufferStartTime = CMTime(value: analyzerFramePosition, timescale: analyzerTimescale)
                analyzerFramePosition += Int64(outputBuffer.frameLength)
                continuation.yield(AnalyzerInput(buffer: outputBuffer, bufferStartTime: bufferStartTime))
                fedFrames += Int64(inputBuffer.frameLength)

                if audioFile.framePosition >= audioFile.length { break }
                let chunkStart = Double(startFrame) / sampleRate
                let chunkDuration = Double(inputBuffer.frameLength) / sampleRate
                let chunkFedAt = ContinuousClock.now
                var elapsed = 0.0
                var covered = 0.0
                // Half a chunk of results is enough to measure, and waiting for all
                // of it would stall on a sentence that needs the next chunk to end.
                while elapsed < throttle.maximumCycleSeconds, covered < chunkDuration / 2 {
                    try await Task.sleep(for: .milliseconds(250))
                    elapsed = Self.seconds(chunkFedAt.duration(to: .now))
                    covered = reportedAudioEnd.withLock { $0 } - chunkStart
                }
                let busy = throttle.estimatedBusySeconds(elapsed: elapsed, coveredAudioSeconds: covered)
                try await Task.sleep(for: .seconds(throttle.pauseSeconds(
                    estimatedBusySeconds: busy,
                    elapsed: elapsed
                )))
                cycleCount += 1
                // Hold further audio while the device is hot or short on memory.
                await SystemPressureGate.shared.waitUntilIdle()
            }
        } catch {
            continuation.finish()
            throw error
        }

        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let fedBytes = fedFrames * Int64(readingFormat.channelCount) * Int64(MemoryLayout<Float>.size)
        Self.ioLogger.info("transcription_audio_fed purpose=\(self.diagnosticPurpose, privacy: .public) frames=\(fedFrames) estimated_pcm_bytes=\(fedBytes) chunk_seconds=\(throttle.chunkSeconds, format: .fixed(precision: 1)) average_cycle_seconds=\(Self.seconds(feedStartedAt.duration(to: .now)) / Double(max(cycleCount, 1)), format: .fixed(precision: 1))")
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Converts one PCM buffer to the analyzer's preferred format, reusing `converter`
    /// (and its internal resampling state) across calls.
    private static func convert(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        to analyzerFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let converter else { return inputBuffer }

        let ratio = analyzerFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            throw NSError(
                domain: "AITranscripts",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate audio conversion buffer."]
            )
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        if let conversionError { throw conversionError }
        if status == .error {
            throw NSError(
                domain: "AITranscripts",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Audio format conversion failed."]
            )
        }
        return outputBuffer
    }


    public func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
            guard await supported(locale: locale) else {
                 print("locate \(locale.identifier) not supported")
                return
            }
            
            if await installed(locale: locale) {
                print(" \(locale.identifier) available")
                return
            } else {
                print("need to download \(locale.identifier) support")
                await reportProgress(0.08, status: "Downloading language model…")
                try await downloadIfNeeded(for: transcriber)
            }
        }
        
        func supported(locale: Locale) async -> Bool {
            let supported = await supportedLocales()
            let target = locale.identifier(.bcp47).lowercased()
            return supported.map { $0.identifier(.bcp47).lowercased() }.contains(target)
        }

        func installed(locale: Locale) async -> Bool {
            let installedIDs: Set<String>
            if let cachedInstalledLocaleIDs {
                installedIDs = cachedInstalledLocaleIDs
            } else {
                installedIDs = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
                cachedInstalledLocaleIDs = installedIDs
            }
            return installedIDs.contains(locale.identifier(.bcp47))
        }

    func downloadIfNeeded(for module: SpeechTranscriber) async throws {
            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                 print(downloader.progress)
                try await downloader.downloadAndInstall()
                // Installation state changed; force a refresh on the next `installed` check.
                cachedInstalledLocaleIDs = nil
            }
        }

    private func transcriptionDuration(for audioFile: AVAudioFile) -> Double {
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(audioFile.length) / sampleRate
    }

    /// Returns a locally installed speech locale matching the requested language.
    /// Synchronization uses this check to avoid downloading a model as a side effect.
    static func installedLocale(matching languageIdentifier: String?) async -> String? {
        let requested = Locale(identifier: languageIdentifier ?? Locale.current.identifier)
        let requestedLanguage = requested.language.languageCode?.identifier.lowercased()
        let supportedLocales = await SupportedSpeechLocales.shared.value()
        let supported = supportedLocales.first { locale in
            locale.identifier(.bcp47).lowercased() == requested.identifier(.bcp47).lowercased()
        } ?? supportedLocales.first { locale in
            guard let requestedLanguage else { return false }
            return locale.language.languageCode?.identifier.lowercased() == requestedLanguage
        }
        guard let supported else { return nil }
        let identifier = supported.identifier(.bcp47)
        let installedIDs = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        return installedIDs.contains(identifier) ? identifier : nil
    }

    private static func progressUpdate(resultEnd: CMTime, audioDuration: Double) -> (progress: Double, status: String) {
        guard audioDuration > 0 else {
            return (0.55, "Transcribing audio…")
        }

        let endSeconds = CMTimeGetSeconds(resultEnd)
        guard endSeconds.isFinite else {
            return (0.55, "Transcribing audio…")
        }

        let fraction = min(max(endSeconds / audioDuration, 0), 1)
        let normalized = 0.1 + (fraction * 0.8)
        let formattedPercent = fraction.formatted(.percent.precision(.fractionLength(0)))
        return (normalized, String(localized: "Transcribing audio… \(formattedPercent)"))
    }

    private static func collectTranscriptionResults(
        from transcriber: SpeechTranscriber,
        resumedSegments: [TranscriptionCheckpoint.Segment],
        checkpoint: TranscriptionCheckpoint?,
        reportedAudioEnd: OSAllocatedUnfairLock<Double>,
        audioDuration: Double,
        maxSnippetDurationSeconds: Double,
        maxWordsPerSnippet: Int,
        progressHandler: (@Sendable (_ progress: Double, _ status: String) async -> Void)?
    ) async throws -> [(range: CMTimeRange, text: String)] {
        var results: [(range: CMTimeRange, text: String)] = resumedSegments.map { segment in
            let start = CMTime(seconds: segment.start, preferredTimescale: 600)
            let end = CMTime(seconds: segment.end, preferredTimescale: 600)
            return (range: CMTimeRange(start: start, end: end), text: segment.text)
        }
        // Saved on a timer rather than per result, and once more on the way out,
        // including when cancellation ends the loop.
        var unsavedSegments: [TranscriptionCheckpoint.Segment] = []
        var lastCheckpointSave = ContinuousClock.now
        defer { checkpoint?.append(unsavedSegments) }
        var lastReportedProgress = 0.0
        var lastProgressReport = ContinuousClock.now
        for try await result in transcriber.results {
            try Task.checkCancellation()
            let resultEnd = CMTimeGetSeconds(result.range.end)
            if resultEnd.isFinite {
                reportedAudioEnd.withLock { $0 = max($0, resultEnd) }
            }
            let splitSegments = Self.splitResult(
                range: result.range,
                rawText: Self.plainTranscriptText(result.text),
                maxSnippetDurationSeconds: maxSnippetDurationSeconds,
                maxWordsPerSnippet: maxWordsPerSnippet
            )
            results.append(contentsOf: splitSegments)
            if let checkpoint {
                unsavedSegments.append(contentsOf: splitSegments.map {
                    TranscriptionCheckpoint.Segment(
                        start: CMTimeGetSeconds($0.range.start),
                        end: CMTimeGetSeconds($0.range.end),
                        text: $0.text
                    )
                })
                if ContinuousClock.now - lastCheckpointSave >= .seconds(60) {
                    checkpoint.append(unsavedSegments)
                    unsavedSegments.removeAll(keepingCapacity: true)
                    lastCheckpointSave = .now
                }
            }
            let update = Self.progressUpdate(resultEnd: result.range.end, audioDuration: audioDuration)
            // Speech can emit results much faster than SwiftUI can render them. Crossing
            // the main actor for every result caused a large observation backlog while
            // long transcripts were being saved. A one-percent/half-second cadence is
            // still responsive without making progress reporting part of the hot path.
            let now = ContinuousClock.now
            if update.progress - lastReportedProgress >= 0.01
                || now - lastProgressReport >= .milliseconds(500) {
                await progressHandler?(update.progress, update.status)
                lastReportedProgress = update.progress
                lastProgressReport = now
            }
        }
        return results
    }

    /// Speech returns attributed text whose attributes contain timing metadata.
    /// `description` serializes those runs (including CMTimeRange values), so only
    /// copy the visible characters into the persisted transcript.
    static func plainTranscriptText(_ text: AttributedString) -> String {
        String(text.characters)
    }

    private static func splitResult(
        range: CMTimeRange,
        rawText: String,
        maxSnippetDurationSeconds: Double,
        maxWordsPerSnippet: Int
    ) -> [(range: CMTimeRange, text: String)] {
        let cleanedText = normalizeTranscriptText(rawText)
        guard cleanedText.isEmpty == false else { return [] }

        let words = cleanedText.split(whereSeparator: \.isWhitespace)
        guard words.isEmpty == false else { return [] }

        let startSeconds = CMTimeGetSeconds(range.start)
        let endSeconds = CMTimeGetSeconds(range.end)
        let durationSeconds = endSeconds - startSeconds

        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return [(range: range, text: cleanedText)]
        }

        let durationChunkCount = Int(ceil(durationSeconds / max(maxSnippetDurationSeconds, 0.4)))
        let wordChunkCount = Int(ceil(Double(words.count) / Double(max(maxWordsPerSnippet, 1))))
        let targetChunkCount = max(1, min(words.count, max(durationChunkCount, wordChunkCount)))

        guard targetChunkCount > 1 else {
            return [(range: range, text: cleanedText)]
        }

        let baseSize = words.count / targetChunkCount
        let remainder = words.count % targetChunkCount
        let chunkWordCounts = (0..<targetChunkCount).map { index in
            baseSize + (index < remainder ? 1 : 0)
        }

        var splitSegments: [(range: CMTimeRange, text: String)] = []
        splitSegments.reserveCapacity(targetChunkCount)

        let timescale: CMTimeScale = 600
        var currentStartSeconds = startSeconds
        var remainingDurationSeconds = durationSeconds
        var remainingWords = words.count
        var wordOffset = 0

        for (index, chunkWordCount) in chunkWordCounts.enumerated() {
            guard chunkWordCount > 0 else { continue }
            let isLastChunk = index == chunkWordCounts.count - 1

            let chunkDurationSeconds: Double
            if isLastChunk || remainingWords <= chunkWordCount {
                chunkDurationSeconds = max(remainingDurationSeconds, 0)
            } else {
                let ratio = Double(chunkWordCount) / Double(remainingWords)
                chunkDurationSeconds = max(remainingDurationSeconds * ratio, 0)
            }

            let chunkEndSeconds = isLastChunk
                ? endSeconds
                : min(endSeconds, currentStartSeconds + chunkDurationSeconds)
            let safeDuration = max(chunkEndSeconds - currentStartSeconds, 0)

            let chunkStart = CMTime(seconds: currentStartSeconds, preferredTimescale: timescale)
            let chunkDuration = CMTime(seconds: safeDuration, preferredTimescale: timescale)
            let chunkRange = CMTimeRange(start: chunkStart, duration: chunkDuration)

            let chunkWords = words[wordOffset..<(wordOffset + chunkWordCount)]
            splitSegments.append((range: chunkRange, text: chunkWords.joined(separator: " ")))

            currentStartSeconds = chunkEndSeconds
            remainingDurationSeconds = max(endSeconds - currentStartSeconds, 0)
            remainingWords -= chunkWordCount
            wordOffset += chunkWordCount
        }

        return splitSegments
    }

    private static func normalizeTranscriptText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reportProgress(_ progress: Double, status: String) async {
        await progressHandler?(min(max(progress, 0), 1), status)
    }
    
    private func formatCMTime(_ time: CMTime) -> String {
        guard time.isNumeric else { return "00:00:00.000" }
        let totalSeconds = Double(time.value) / Double(time.timescale)
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%06.3f", hours, minutes, seconds)
    }

    
    func bestMatchingSupportedLocale(for input: String) async -> Locale? {

        let supported = await supportedLocales()

        let preferred: [String: String] = [
            "de": "de-DE",
            "en": "en-US", // 'en-EN' does not exist; 'en-US' or 'en-GB' are standard
            "fr": "fr-FR",
            "it": "it-IT",
            "es": "es-ES"
        ]
#if targetEnvironment(simulator)
            // print("---- TRANSCRIPT NOT SUPPORT IN SIMULATOR ----")
#endif
    //    // print("Supported:", supported.map { $0.identifier(.bcp47) })
       
        

        
        // First, try for exact language-region match
        if let fullMatch = supported.first(where: { $0.identifier(.bcp47).lowercased() == input.lowercased() }) {
            return fullMatch
        }
        
        if let mapped = preferred[input.lowercased()],
           supported.contains(where: { $0.identifier(.bcp47).lowercased() == mapped.lowercased() }) {
            return Locale(identifier: mapped)
        }
        
        
        // Then, try for a language-only match (e.g., "de" matches "de-DE")
        if let prefixMatch = supported.first(where: { $0.identifier(.bcp47).lowercased().hasPrefix(input.lowercased() + "-") }) {
             print("Best Match:", prefixMatch.identifier(.bcp47))
            return prefixMatch
        }
        return nil // No match
    }
    
}
