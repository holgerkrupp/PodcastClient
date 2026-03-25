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
    //MARK: INPUT
    let url: URL
    var language: Locale = Locale.current
    let progressHandler: (@Sendable (_ progress: Double, _ status: String) async -> Void)?
    
    
    //MARK: OUTPUT
    var transcript: [SFTranscriptionSegment] = []
    
    init(
        url: URL,
        language: String? = nil,
        progressHandler: (@Sendable (_ progress: Double, _ status: String) async -> Void)? = nil
    ) async {
        self.url = url
        self.progressHandler = progressHandler
        print("language set to: \(language ?? "nil") ")
        if let language{
            self.language = await bestMatchingSupportedLocale(for: language) ?? Locale.current
        }else{
            self.language = Locale.current
        }
        

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
        self.language = await bestMatchingSupportedLocale(for: language.identifier) ?? Locale.current
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
       
        guard let audioFile = try? AVAudioFile(forReading: url) else {
             print("could not load audio file")
            return nil }

        let audioDuration = transcriptionDuration(for: audioFile)
        
        print("transcribe to lang: \(language.identifier(.bcp47))")
        self.language = await bestMatchingSupportedLocale(for: language.identifier(.bcp47)) ?? Locale.current
        
        let locale = self.language
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        
        print("normalized:", locale.identifier(.bcp47))
        
        await reportProgress(0.05, status: "Checking speech model…")
        do {
            try await ensureModel(transcriber: transcriber, locale: locale)
        } catch {
             print(error)
            return nil
        }
        print("model ensured")
        await reportProgress(0.1, status: "Starting transcription…")

         let isInstalled = await installed(locale: locale)
        guard isInstalled else {
            return nil
        }
        assert(isInstalled, "Locale should be installed after ensureModel")
        
        
    print("1")
        
        let progressReporter = self.progressHandler
        async let transcriptionFuture = Self.collectTranscriptionResults(
            from: transcriber,
            audioDuration: audioDuration,
            progressHandler: progressReporter
        )
        print("2")
        
        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            print("Warning: could not reserve locale \(locale). \(error)")
            // Optionally proceed if errors are non-fatal
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        
        

        
        print(transcriber.selectedLocales)
    
     
        print("3")
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            do{
                try await analyzer.finalizeAndFinish(through: lastSample)
                print("ok")
            }catch{
                print("analyzer failed")
                print(error)
            }
            } else {
                print("analyzer failed 2")
            await analyzer.cancelAndFinishNow()
        }
        print("4")
        await reportProgress(0.92, status: "Finalizing transcript…")
        let transcription = try await transcriptionFuture
        
        return transcription
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
            let supported = await SpeechTranscriber.supportedLocales
            let target = locale.identifier(.bcp47).lowercased()
            return supported.map { $0.identifier(.bcp47).lowercased() }.contains(target)
        }

        func installed(locale: Locale) async -> Bool {
            let installed = await Set(SpeechTranscriber.installedLocales)
            return installed.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
        }
    
    func downloadIfNeeded(for module: SpeechTranscriber) async throws {
            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                 print(downloader.progress)
                try await downloader.downloadAndInstall()
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
        let percent = Int(fraction * 100)
        return (normalized, "Transcribing audio… \(percent)%")
    }

    private static func collectTranscriptionResults(
        from transcriber: SpeechTranscriber,
        audioDuration: Double,
        progressHandler: (@Sendable (_ progress: Double, _ status: String) async -> Void)?
    ) async throws -> [(range: CMTimeRange, text: String)] {
        var results: [(range: CMTimeRange, text: String)] = []
        for try await result in transcriber.results {
            print(result.range.start.value.formatted(), result.range.end.value.formatted(), result.text)
            results.append((range: result.range, text: result.text.description))
            let update = Self.progressUpdate(resultEnd: result.range.end, audioDuration: audioDuration)
            await progressHandler?(update.progress, update.status)
        }
        return results
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
        
        let supported = await SpeechTranscriber.supportedLocales
        
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
