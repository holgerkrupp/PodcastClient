//
//  AITranscripts.swift
//  Raul
//
//  Created by Holger Krupp on 03.07.25.
//

import Foundation
import Speech

@Observable
class AITranscripts {
    //MARK: INPUT
    let url: URL
    var language: Locale = Locale.current
    
    
    //MARK: OUTPUT
    var transcript: [SFTranscriptionSegment] = []
    
    init(url: URL, language: String? = nil) {
        
        self.url = url
        self.language = Locale(identifier: language ?? "en-US")
        
        print("language was \(language ?? "nil") ")
        print("locate is \(self.language.identifier)")
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
    
    
    func transcribeTovTT() async throws -> String? {
        self.language = await bestMatchingSupportedLocale(for: language.identifier) ?? Locale.current
        print("language finished")
        
        guard let segments = try await transcribe() else { return nil }
        print("transcript finished")
        dump(segments)
        
        
        let formatted = segments.map { segment in
            let start = formatCMTime(segment.range.start)
            let end = formatCMTime(segment.range.end)
            let text = segment.text.hasSuffix("{\n}") ? String(segment.text.dropLast(3)) : segment.text
            
            return "\(start) --> \(end)\n\(text)"
        }.joined(separator: "\n\n")
        
        let result = "WEBVTT\n\n" + formatted

        
        print("formated:  \(result)")
        print("formating finished")
        return result
    }
    
    
    
    func transcribe() async throws -> [(range: CMTimeRange, text: String)]?{
        print("transcribing")
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            print("could not load audio file")
            return nil }
        
       
        
        let transcriber = SpeechTranscriber(locale: language, preset: .offlineTranscription)
        
        do {
            try await ensureModel(transcriber: transcriber, locale: language)
        } catch {
            print(error)
            return nil
        }
        print("language ensured")
        
        async let transcriptionFuture = try await transcriber.results.reduce(into: [(range: CMTimeRange, text: String)]()) { arr, result in
            arr.append((range: result.range, text: result.text.description))
        }
        
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        
        return try await transcriptionFuture
    }
    
    
    public func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
            guard await supported(locale: locale) else {
                print("localeNotSupported")
              //  throw TranscriptionError.localeNotSupported
                return
            }
            
            if await installed(locale: locale) {
                return
            } else {
                try await downloadIfNeeded(for: transcriber)
            }
        }
        
        func supported(locale: Locale) async -> Bool {
            let supported = await SpeechTranscriber.supportedLocales
         

            
            return supported.map { $0.identifier(.bcp47) }.contains(language.identifier(.bcp47))
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
    
    private func formatCMTime(_ time: CMTime) -> String {
        guard time.isNumeric else { return "00:00:00.000" }
        let totalSeconds = Double(time.value) / Double(time.timescale)
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%06.3f", hours, minutes, seconds)
    }
    func bestMatchingLocale(for input: String?) -> Locale {
      
        guard let input, Locale.LanguageCode(input).isISOLanguage else {
            print("bestMatchingLocale: Invalid input")
            let standardIdentifier = Locale.current.identifier
            let canonicalIdentifier = Locale.canonicalIdentifier(from: standardIdentifier)
            return Locale(identifier: canonicalIdentifier)
        }
        print("bestMatchingLocale: \(Locale.LanguageCode(input).identifier)")
        return Locale(languageCode: Locale.LanguageCode(input))
    }
    
    func bestMatchingSupportedLocale(for input: String) async -> Locale? {
        
        let supported = await SpeechTranscriber.supportedLocales
     
        print("Supported:", supported.map { $0.identifier(.bcp47) })
        print("Mine:", language.identifier(.bcp47))
        
        
      
        
        // First, try for exact language-region match
        if let fullMatch = supported.first(where: { $0.identifier(.bcp47).lowercased() == input.lowercased() }) {
            return fullMatch
        }
        // Then, try for a language-only match (e.g., "de" matches "de-DE")
        if let prefixMatch = supported.first(where: { $0.identifier(.bcp47).lowercased().hasPrefix(input.lowercased() + "-") }) {
            print("Best Match:", prefixMatch.identifier(.bcp47))
            return prefixMatch
        }
        return nil // No match
    }
    
}
