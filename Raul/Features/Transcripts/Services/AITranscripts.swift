//
//  AITranscripts.swift
//  Raul
//
//  Created by Holger Krupp on 03.07.25.
//

import Foundation
import AVFoundation
import Speech
import BasicLogger

@Observable
class AITranscripts {
    /// Controls input throttling (duty-cycling) while feeding audio to the analyzer.
    /// Automatic/background runs use a non-zero pause so the Speech XPC's rolling CPU
    /// average stays under iOS's 50%/180s background CPU monitor. Manual runs use `.none`.
    struct Throttle: Sendable {
        /// Seconds of audio fed per chunk before pausing.
        var chunkSeconds: Double
        /// Seconds to sleep between chunks. `0` means continuous (no throttling).
        var pauseSeconds: Double

        static let none = Throttle(chunkSeconds: 0, pauseSeconds: 0)
        /// ~45% duty cycle, assuming on-device transcription runs near 1× realtime.
        static let backgroundFriendly = Throttle(chunkSeconds: 15, pauseSeconds: 18)

        var isEnabled: Bool { chunkSeconds > 0 && pauseSeconds > 0 }
    }

    //MARK: INPUT
    let url: URL
    var language: Locale = Locale.current
    let maxSnippetDurationSeconds: Double
    let maxWordsPerSnippet: Int
    let analyzerPriority: TaskPriority
    let throttle: Throttle
    let progressHandler: (@Sendable (_ progress: Double, _ status: String) async -> Void)?


    //MARK: OUTPUT
    var transcript: [SFTranscriptionSegment] = []

    // Cached async lookups — each Speech framework query is an XPC round-trip, and the
    // old code re-fetched supported/installed locales several times per job.
    private var cachedSupportedLocales: [Locale]?
    private var cachedInstalledLocaleIDs: Set<String>?
    private var didResolveLanguage = false

    init(
        url: URL,
        language: String? = nil,
        maxSnippetDurationSeconds: Double = 1.2,
        maxWordsPerSnippet: Int = 3,
        analyzerPriority: TaskPriority = .userInitiated,
        throttle: Throttle = .none,
        progressHandler: (@Sendable (_ progress: Double, _ status: String) async -> Void)? = nil
    ) async {
        self.url = url
        self.maxSnippetDurationSeconds = min(max(maxSnippetDurationSeconds, 0.4), 8.0)
        self.maxWordsPerSnippet = max(maxWordsPerSnippet, 1)
        self.analyzerPriority = analyzerPriority
        self.throttle = throttle
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

    /// `SpeechTranscriber.supportedLocales` is an expensive async (XPC) property; cache it.
    private func supportedLocales() async -> [Locale] {
        if let cachedSupportedLocales { return cachedSupportedLocales }
        let locales = await SpeechTranscriber.supportedLocales
        cachedSupportedLocales = locales
        return locales
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
        
            _ = await EpisodeActor(modelContainer: ModelContainerManager.shared.container).getEpisodeTitlefrom(url: url)
           //  await BasicLogger.shared.log("Episode title: \(title ?? "unknown")")
        
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
        do {
            try await ensureModel(transcriber: transcriber, locale: locale)
        } catch {
             print(error)
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
        
        let progressReporter = self.progressHandler
        let configuredMaxSnippetDurationSeconds = self.maxSnippetDurationSeconds
        let configuredMaxWordsPerSnippet = self.maxWordsPerSnippet
        async let transcriptionFuture = Self.collectTranscriptionResults(
            from: transcriber,
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
            options: SpeechAnalyzer.Options(priority: analyzerPriority, modelRetention: .whileInUse)
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
                    throttle: throttle
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

        return transcription
    }

    /// Feeds the audio file to the analyzer in bounded chunks, pausing between them.
    /// The pause lets the Speech XPC go idle, dropping its rolling CPU average below
    /// iOS's background CPU monitor threshold at the cost of longer wall-clock time.
    private func analyzeThrottled(
        analyzer: SpeechAnalyzer,
        audioFile: AVAudioFile,
        analyzerFormat: AVAudioFormat,
        throttle: Throttle
    ) async throws {
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputSequence)

        let readingFormat = audioFile.processingFormat
        let sampleRate = readingFormat.sampleRate
        let framesPerChunk = AVAudioFrameCount(max(sampleRate * throttle.chunkSeconds, 1))
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

                let bufferStartTime = CMTime(value: startFrame, timescale: CMTimeScale(sampleRate))
                let outputBuffer = try Self.convert(inputBuffer, using: converter, to: analyzerFormat)
                continuation.yield(AnalyzerInput(buffer: outputBuffer, bufferStartTime: bufferStartTime))

                if audioFile.framePosition >= audioFile.length { break }
                try await Task.sleep(for: .seconds(throttle.pauseSeconds))
            }
        } catch {
            continuation.finish()
            throw error
        }

        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
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
        audioDuration: Double,
        maxSnippetDurationSeconds: Double,
        maxWordsPerSnippet: Int,
        progressHandler: (@Sendable (_ progress: Double, _ status: String) async -> Void)?
    ) async throws -> [(range: CMTimeRange, text: String)] {
        var results: [(range: CMTimeRange, text: String)] = []
        for try await result in transcriber.results {
            try Task.checkCancellation()
            let splitSegments = Self.splitResult(
                range: result.range,
                rawText: result.text.description,
                maxSnippetDurationSeconds: maxSnippetDurationSeconds,
                maxWordsPerSnippet: maxWordsPerSnippet
            )
            results.append(contentsOf: splitSegments)
            let update = Self.progressUpdate(resultEnd: result.range.end, audioDuration: audioDuration)
            await progressHandler?(update.progress, update.status)
        }
        return results
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
