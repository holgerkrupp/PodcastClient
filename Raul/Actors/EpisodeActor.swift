//
//  EpisodeTranscriptActor.swift
//  Raul
//
//  Created by Holger Krupp on 08.04.25.
//
import SwiftData
import Foundation
import mp3ChapterReader
import AVFoundation
import BasicLogger
import SwiftUI
import UIKit


@ModelActor
actor EpisodeActor {
    
    func fetchEpisode(byID episodeID: UUID) async -> Episode? {
        let predicate = #Predicate<Episode> { episode in
            episode.id == episodeID
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate))
            return results.first
        } catch {
            print("❌ Error fetching episode for episode ID: \(episodeID), Error: \(error)")
            return nil
        }
    }
    
    func fetchMarker(byID markerID: UUID) async -> Bookmark? {
        let predicate = #Predicate<Bookmark> { marker in
            marker.uuid == markerID
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<Bookmark>(predicate: predicate))
            return results.first
        } catch {
            print("❌ Error fetching episode for Marker ID: \(markerID), Error: \(error)")
            return nil
        }
    }

    
    
    func fetchEpisode(byURL fileURL: URL) async -> Episode? {
        let predicate = #Predicate<Episode> { episode in
            episode.url == fileURL
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate))
            return results.first
        } catch {
            // print("❌ Error fetching episode for file URL: \(fileURL.absoluteString), Error: \(error)")
            return nil
        }
    }
    
    func getLastPlayedEpisode() async -> Episode? {
        guard let episodeID = await getLastPlayedEpisodeID() else { return nil }
        return await fetchEpisode(byID: episodeID)
    }

    
    func updateDuration(fileURL: URL) async{
      
        guard let episode = await fetchEpisode(byURL: fileURL) else { return }
        // print("updateDuration of \(episode.title)")
       
            if let localFile = episode.localFile, ((episode.metaData?.calculatedIsAvailableLocally) == true){
                do{
                    let duration = try await AVURLAsset(url: localFile).load(.duration)
                    let seconds = CMTimeGetSeconds(duration)
                    if !seconds.isNaN{
                        episode.duration = seconds
                    }
                    // print("new duration: \(seconds)")
                    modelContext.saveIfNeeded()
                }catch{
                    // print(error)
                }
            }else{
                // print("no local file")
            }
        
    }
    
    func updateChapterDurations(fileURL: URL) async{
        guard let episode = await fetchEpisode(byURL: fileURL) else { return }
        guard !(episode.chapters?.isEmpty ?? true) else { return }
        guard let totalDuration = episode.duration else { return }
        
        // print("updateChapterDurations")
        
        if let  chapters = episode.chapters{
            var lastEnd = totalDuration
            for chapter in chapters.sorted(by: {$0.start ?? 0.0 > $1.start ?? lastEnd}){
                if chapter.duration == nil{
                    chapter.duration = lastEnd - (chapter.start ?? 0.0)
                    lastEnd = chapter.start ?? 0.0
                }
            }
        }
    }
    
    //MARK: Meta Data for Statistics
    
    func addplaybackStartTimes(episodeURL: URL, date: Date = Date()) async{
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        if episode.metaData?.playbackStartTimes == nil  {
            episode.metaData?.playbackStartTimes = .init([])
        }
        episode.metaData?.playbackStartTimes?.elements.append(date)
    }
    
    func addPlaybackDuration(episodeURL: URL, duration: TimeInterval) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        if episode.metaData?.playbackDurations == nil {
            episode.metaData?.playbackDurations = .init([])
        }
        episode.metaData?.playbackDurations?.elements.append(duration)
        episode.metaData?.totalListenTime += duration
    }

    func addPlaybackSpeed(episodeURL: URL, speed: Double) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        if episode.metaData?.playbackSpeeds == nil {
            episode.metaData?.playbackSpeeds = .init([])
        }
        episode.metaData?.playbackSpeeds?.elements.append(speed)
    }

    func setCompletionDate(episodeURL: URL, date: Date? = nil) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        episode.metaData?.completionDate = date ?? Date()
    }

    func setFirstListenDateIfNeeded(episodeURL: URL, date: Date? = nil) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        if episode.metaData?.firstListenDate == nil {
            episode.metaData?.firstListenDate = date ?? Date()
        }
    }

    func markEpisodeAsSkipped(episodeURL: URL) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        episode.metaData?.wasSkipped = true
    }
    
    func getLastPlayedEpisodeID() async -> UUID? {
        let predicate = #Predicate<Episode> { episode in
            episode.metaData?.isHistory == false
        }
        let sortDescriptors: [SortDescriptor<Episode>] = [
            SortDescriptor(\Episode.metaData?.lastPlayed, order: .reverse)
        ]
        do {
            let results = try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate, sortBy: sortDescriptors))

            return results.first?.id
        } catch {
            // print("❌ Error fetching or saving metadata: \(error)")
        }
        return nil

    }
    
    func setLastPlayed(_ episodeID: UUID, to date: Date = Date()) async {
        guard let episode = await fetchEpisode(byID: episodeID) else {
            
            // print("could not find episode with ID \(episodeID) to set last played date")
            return }
        // print("setting last played date for \(episode.title) to \(date.formatted())")
        episode.metaData?.lastPlayed = date
        modelContext.saveIfNeeded()
    }
    
    func setPlayPosition(episodeID: UUID, position: TimeInterval) async {
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        let previousPosition = episode.metaData?.playPosition ?? 0.0
        if abs(previousPosition - position) > 10 {
        if position > episode.metaData?.maxPlayposition ?? 0.0 {
            episode.metaData?.maxPlayposition = position
            
        }
            episode.metaData?.playPosition = position
            modelContext.saveIfNeeded()
        }

    }
    
    func markasPlayed(_ episodeID: UUID) async {
        // print("marking episode \(episodeID) as played")
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        episode.metaData?.completionDate = Date()
        episode.metaData?.isHistory = true
        episode.metaData?.status = .history

        modelContext.saveIfNeeded()
    }
    
    func removeFromPlaylist(_ episodeID: UUID) async {
        if let PlaylistmodelActor = try? PlaylistModelActor(modelContainer: modelContainer){
            try? await PlaylistmodelActor.remove(episodeID: episodeID)
        }
    }
    
    func archiveEpisode(episodeID: UUID) async {
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        
        await removeFromPlaylist(episodeID)

        if episode.metaData == nil {
            episode.metaData = EpisodeMetaData()
        }
        episode.metaData?.isArchived = true
        episode.metaData?.isInbox = false
        episode.metaData?.status = .archived

        await deleteFile(episodeID: episodeID)
         modelContext.saveIfNeeded()
        await MainActor.run {
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
        }
    }
    
    func moveToHistory(episodeID: UUID) async {
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        await removeFromPlaylist(episodeID)

        if episode.metaData == nil {
            episode.metaData = EpisodeMetaData()
        }
        if episode.metaData?.lastPlayed == nil {
            episode.metaData?.lastPlayed = Date()
        }
        
        episode.metaData?.isHistory = true
        episode.metaData?.isInbox = false
        episode.metaData?.status = .history
        
        modelContext.saveIfNeeded()
        NotificationCenter.default.post(name: .inboxDidChange, object: nil)
    }
    
    
    func download(episodeID: UUID) async {
        guard let episode = await fetchEpisode(byID: episodeID) else {
            return }

        if let localFile = episode.localFile {
            if let url = episode.url, await DownloadManager.shared.download(from: url, saveTo: localFile, episodeID: episode.id) != nil {
            }
            try? await downloadTranscript(episode.persistentModelID)

        }
        
    }
    
    func processAfterCreation(episodeID: UUID) async {
        guard let episode = await fetchEpisode(byID: episodeID) else {
            return }
        
     /*   if episode.publishDate ?? Date() < episode.podcast?.metaData?.subscriptionDate ?? Date() {
            episode.metaData?.status = .archived
            episode.metaData?.isArchived = true
            modelContext.saveIfNeeded()
            return
        }
     */
        
        let playnext = await PodcastSettingsModelActor(modelContainer: modelContainer).getPlaynextposition(for: episode.podcast?.id)
        if playnext != .none {
            try? await PlaylistModelActor(modelContainer: modelContainer).add(episodeID: episodeID, to: playnext)
        }
        await NotificationManager().sendNotification(title: episode.podcast?.title ?? "New Episode", body: episode.title)
        await getRemoteChapters(episodeID: episodeID)
    }
    
    func getRemoteChapters(episodeID: UUID) async {
        guard let episode = await fetchEpisode(byID: episodeID) else {
            return }
        if let url = episode.url, let pubDate = episode.publishDate,
               let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()),
               pubDate > oneWeekAgo{
                await extractRemoteMP3Chapters(url)
                await applyAutoSkipWords(episodeID: episodeID)
        }
    }
    
    func createBookMarkfor(episodeID: UUID, at playPosition: Double) async{
        guard let episode = await fetchEpisode(byID: episodeID) else { return }

        let bookmarkTitle = episode.transcriptLines?.sorted(by: { $0.startTime < $1.startTime }).last(where: { $0.startTime < playPosition })?.text ?? episode.title
        let bookmark = Bookmark(start: playPosition, title: bookmarkTitle, type: .bookmark)
        episode.bookmarks?.append(bookmark)
        modelContext.saveIfNeeded()
    }
    
    func unarchiveEpisode(episodeID: UUID) async  {
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        episode.metaData?.isArchived = false
        episode.metaData?.isInbox = true
        episode.metaData?.status = .inbox
        modelContext.saveIfNeeded()
    }
    
    func deleteFile(episodeID: UUID) async{
        guard let episode = await fetchEpisode(byID: episodeID) else { return }

        if let file = episode.localFile{
            try? FileManager.default.removeItem(at: file)
        }
        episode.metaData?.isAvailableLocally = false
        modelContext.saveIfNeeded()
    }

    func markEpisodeAvailable(fileURL: URL) async {
        guard let episode = await fetchEpisode(byURL: fileURL) else {
            return }

        guard let url = episode.url else {
            return
        }
        episode.metaData?.isAvailableLocally = true
        await updateDuration(fileURL: fileURL)

        await createChapters(url)
        try? await transcribe(url) // delegates now
        modelContext.saveIfNeeded()
    }
    
    // NEW: Delegate to TranscriptionManager
    func transcribe(_ fileURL: URL) async throws {
        print("transcribe")
        guard let episode = await fetchEpisode(byURL: fileURL) else { return }
        
        if episode.externalFiles.contains(where: { $0.category == .transcript}) {
            do {
                try await downloadTranscript(episode.persistentModelID)
            }catch{
                print(error)
                await TranscriptionManager.shared.enqueueTranscription(episodeID: episode.id)
            }
        }else{
            await TranscriptionManager.shared.enqueueTranscription(episodeID: episode.id)
        }
    }
    
    func decodeTranscription(_ transcription: String) -> [TranscriptLineAndTime] {
        print("decodeTranscription")
        let decoder = TranscriptDecoder(transcription)
        let lines = decoder.transcriptLines
        var transcript = [TranscriptLineAndTime]()
        for line in lines {
            let text = line.text
            let start = line.startTime
            let end = line.endTime
            let speaker = line.speaker
            transcript.append(TranscriptLineAndTime(speaker: speaker, text: text, startTime: start, endTime: end))
        }
        print("created \(lines.count) lines")
        return transcript
    }
    
    func deleteMarker(markerID: UUID) async{
        guard let marker = await fetchMarker(byID: markerID) else { return}
        marker.episode = nil
        marker.bookmarkEpisode = nil
        modelContext.delete(marker)
        modelContext.saveIfNeeded()
    }

    func createChapters(_ fileURL: URL) async  {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return  }
        if let chapters = episode.chapters, chapters.isEmpty {
            if let chapterFile = episode.externalFiles.first(where: { $0.category == .chapter }) {
                if let url = URL(string: chapterFile.url) {
                    let isJSON = (url.pathExtension.lowercased() == "json") || (chapterFile.fileType?.lowercased().contains("json") == true)
                    if isJSON {
                        if let jsonString = await downloadAndParseStringFile(url: url),
                           let jsonData = jsonString.data(using: .utf8),
                           let chapters = await parseJSONChapters(jsonData: jsonData) {
                            episode.chapters?.removeAll(where: { $0.type == .extracted })
                            episode.chapters?.append(contentsOf: chapters)
                            modelContext.saveIfNeeded()
                        }
                    }
                }
            }
        }
        
        if episode.chapters == nil {
            episode.chapters = []
        }
        if let chapters = episode.chapters, chapters.isEmpty || !(chapters.contains(where: { $0.type == .mp3 }) || chapters.contains(where: { $0.type == .mp4 })) {
            guard let url = episode.localFile else {
                return
            }
            do {
                if let formatInfo = try await MetadataLoader.getAudioFormat(from: url) {
                    if formatInfo.formatID == kAudioFormatMPEGLayer3 {
                        await extractMP3Chapters(episode.persistentModelID)
                    } else if formatInfo.formatID == kAudioFormatMPEG4AAC {
                        await extractM4AChapters(episode.persistentModelID)
                    }
                }
            } catch { }
        }
        if let chapers = episode.chapters, chapers.isEmpty, let url = episode.url{
            await extractShownotesChapters(fileURL: url)
        }
        if let url = episode.url{
            await updateChapterDurations(episodeURL: url)
        }
        await applyAutoSkipWords(episodeID: episode.id)
    }
    
    private func applyAutoSkipWords(episodeID: UUID) async{
        guard let episode = await fetchEpisode(byID: episodeID) else {
            return
        }
        let actor = PodcastSettingsModelActor(modelContainer: modelContainer)
        guard let skipWord = await actor.getChapterSkipKeywords(for: episode.podcast?.id) else {
            return
        }
        for skipWord in skipWord {
            guard let keyword = skipWord.keyWord?.lowercased(), !keyword.isEmpty else { continue }
            let matches: (String) -> Bool
            switch skipWord.keyOperator {
            case .Contains:
                matches = { $0.contains(keyword) }
            case .Is:
                matches = { $0 == keyword }
            case .StartsWith:
                matches = { $0.hasPrefix(keyword) }
            case .EndsWith:
                matches = { $0.hasSuffix(keyword) }
            }
            if let chapters = episode.chapters{
                for chapter in chapters {
                    if matches(chapter.title.lowercased()) {
                        chapter.shouldPlay = false
                    }
                }
            }
        }
        modelContext.saveIfNeeded()
    }
    
    private func extractMP3Chapters(_ episodeID: PersistentIdentifier) async {
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return  }
        guard let url = episode.localFile else {
            return
        }
        guard url.lastPathComponent.hasSuffix(".mp3") else {
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            guard data.count >= 3, let id3Identifier = String(data: data[0..<3], encoding: .utf8), id3Identifier == "ID3" else {
                return
            }
            if let mp3Reader = mp3ChapterReader(with: url){
                let dict = mp3Reader.getID3Dict()
                if let chapters = parse(chapters: dict){
                    episode.chapters?.removeAll(where: { $0.type == .mp3 })
                    episode.chapters?.append(contentsOf: chapters)
                     modelContext.saveIfNeeded()
                }
            }
            return
        } catch {
            return
        }
    }
    
    func extractRemoteMP3Chapters(_ fileURL: URL) async {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return  }
        if let remoteURL = episode.url, let mp3Reader = await mp3ChapterReader.fromRemoteURL(remoteURL) {
            let dict = mp3Reader.getID3Dict()
            if let chapters = parse(chapters: dict) {
                episode.chapters?.removeAll(where: { $0.type == .mp3 })
                episode.chapters?.append(contentsOf: chapters)
                modelContext.saveIfNeeded()
            }
        }
    }
    
    private func parse(chapters: [String: Any]) -> [Marker]?{
        if let chaptersDict = chapters["Chapters"] as? [String:[String:Any]]{
            var chapters: [Marker] = []
            for chapter in chaptersDict {
                let newChaper = Marker()
                newChaper.title = chapter.value["TIT2"] as? String ?? ""
                newChaper.start = chapter.value["startTime"] as? Double ?? 0
                newChaper.duration = (chapter.value["endTime"] as? Double ?? 0) - (newChaper.start ?? 0)
                newChaper.type = .mp3
                if let imagedata = (chapter.value["APIC"] as? [String:Any])?["Data"] as? Data{
                    newChaper.imageData = imagedata
                } else { }
                chapters.append(newChaper)
            }
            return chapters
        }
        return nil
    }
    
    func parseJSONChapters(jsonData: Data) async -> [Marker]? {
        do {
            let decoder = JSONDecoder()
            let chapterList = try decoder.decode(JSONChapterList.self, from: jsonData)
            var chapters: [Marker] = []
            for ch in chapterList.chapters {
                let chapter = Marker()
                chapter.title = ch.title
                chapter.start = ch.startTime
                chapter.type = .extracted
                if let imgUrlStr = ch.img, let imgUrl = URL(string: imgUrlStr) {
                    chapter.imageData = try? Data(contentsOf: imgUrl)
                }
                chapters.append(chapter)
            }
            return chapters
        } catch {
            return nil
        }
    }
    
    nonisolated func loadMetadata(from asset: AVURLAsset) async throws -> [AVMetadataItem] {
        return try await asset.load(.metadata)
    }
    
    nonisolated func loadChapterGroups(from asset: AVURLAsset, languages: [String]) async throws -> [AVTimedMetadataGroup] {
        return try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages)
    }
    
    nonisolated func loadMetadataValue(from item: AVMetadataItem) async throws -> Any? {
        return try await item.load(.value)
    }

    func getEpisodeTitlefrom(url: URL) async -> String? {
        guard let episode = await fetchEpisode(byURL: url) else { return nil }
        return episode.title
    }
    
    private func extractM4AChapters(_ episodeID: PersistentIdentifier) async {
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return }
        guard let url = episode.localFile else {
            return
        }
        
        do {
            let chapterData = try await MetadataLoader.loadChapters(from: url)
            let chapters = chapterData.map { data in
                let chapter = Marker()
                chapter.title = data.title
                chapter.start = data.start
                chapter.duration = data.duration
                chapter.type = .mp4
                chapter.imageData = data.imageData
                return chapter
            }
            episode.chapters?.removeAll(where: { $0.type == .mp4 })
            episode.chapters?.append(contentsOf: chapters)
            modelContext.saveIfNeeded()
        } catch {
        }
    }
    
    func extractTranscriptChapters(fileURL: URL) async  {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return  }
        guard let transcriptLines = episode.transcriptLines, transcriptLines != [] else {
            return  }
        
        let extractedData = await generateAIChapters(from: transcriptLines)
        if !extractedData.isEmpty {
            var newchapters:[Marker] = []
            for extractedChapter in extractedData{
                if let startingTime =  extractedChapter.key.durationAsSeconds{
                    let newChapter = Marker(start: startingTime, title: extractedChapter.value, type: .extracted)
                    newchapters.append(newChapter)
                }
            }
            episode.chapters?.removeAll(where: { $0.type == .ai })
            episode.chapters?.append(contentsOf: newchapters)
            modelContext.saveIfNeeded()
        }
        
    }
    
    func extractShownotesChapters(fileURL: URL) async  {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return  }
        guard let text = episode.desc else { return  }
        var extractedData = extractTimeCodesAndTitles(from: text)
        
        if  extractedData == nil || extractedData?.count == 0{
            extractedData = await generateAIChapters(from: text)
        }
       
        if let extractedData {
            var newchapters:[Marker] = []
            for extractedChapter in extractedData{
                if let startingTime =  extractedChapter.key.durationAsSeconds{
                    let newChapter = Marker(start: startingTime, title: extractedChapter.value, type: .extracted)
                    newchapters.append(newChapter)
                }
            }
            episode.chapters?.removeAll(where: { $0.type == .extracted })
            episode.chapters?.append(contentsOf: newchapters)
            modelContext.saveIfNeeded()
        }
    }
    
    func extractTimeCodesAndTitles(from htmlEncodedText: String) -> [String: String]? {
        let pattern = #"(?m)^(\d{2}:\d{2}(?::\d{2})?)\s+(.+)$"#
        let nsText = htmlEncodedText as NSString

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.allowCommentsAndWhitespace, .caseInsensitive]
        ) else { return nil }

        let matches = regex.matches(in: htmlEncodedText, options: [], range: NSRange(location: 0, length: nsText.length))

        var result: [String: String] = [:]

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let timeCode = nsText.substring(with: match.range(at: 1))
            let title = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            result[timeCode] = title
        }

        return result
    }
    
    func generateAIChapters(from htmlEncodedText: String) async -> [String: String] {
        let chapterGenerator = AIChapterGenerator()
        let aiChapters = await chapterGenerator.extractChaptersFromText(htmlEncodedText)
        return aiChapters
    }
    
    func generateAIChapters(from transcript: [TranscriptLineAndTime]) async -> [String: String] {
        guard let prompt = transcriptLinesToJSONArray(transcript) else { return [:] }
        let chapterGenerator = AIChapterGenerator()
        let aiChapters = await chapterGenerator.createChaptersFromTranscriptLines(prompt)
        return aiChapters
    }
    
    private func transcriptLinesToJSONArray(_ lines: [TranscriptLineAndTime]) -> String? {
        let mapped = lines.map { line in
            [
                "starttime": line.startTime,
                "endtime": line.endTime ?? NSNull(),
                "text": line.text
            ] as [String: Any]
        }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: mapped, options: [.prettyPrinted])
            return String(data: jsonData, encoding: .utf8)
        } catch {
            return nil
        }
    }
    
    func updateChapterDurations(episodeURL: URL) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else {
            return }
        var chapters = episode.preferredChapters
        chapters.sort { ($0.start ?? 0.0) < ($1.start ?? 0.0) }
        for i in 0..<chapters.count {
            guard let start = chapters[i].start else { continue }
            let end: Double
            if i + 1 < chapters.count, let nextStart = chapters[i + 1].start {
                end = nextStart
            } else {
                end = episode.duration ?? start
            }
            chapters[i].duration = end - start
        }
        modelContext.saveIfNeeded()
    }
    
    
    
    private func bestExternalFile(
        in files: [ExternalFile],
        preferredTypes: [String] = ["text/vtt", "application/x-subrip", "text/plain"]
    ) -> ExternalFile? {
        // 1) Exact fileType match (e.g. "text/vtt")
        if let vttByType = files.first(where: { file in
            guard let type = file.fileType?.lowercased() else { return false }
            return preferredTypes.contains(where: { type.contains($0) })
        }) {
            return vttByType
        }

        // 2) URL extension contains "vtt" (or "srt" as a fallback)
        if let vttByExt = files.first(where: { URL(string: $0.url)?.pathExtension.lowercased() == "vtt" }) {
            return vttByExt
        }
        if let srtByExt = files.first(where: { URL(string: $0.url)?.pathExtension.lowercased() == "srt" }) {
            return srtByExt
        }

        // 3) Otherwise fall back to the first file
        return files.first
    }
    
    
    enum TranscriptError: Error {
        case transcriptionExists
        case noTranscriptFileFound
        case episodeNotFound
        case decodingFailed
    }
    
    func downloadTranscript(_ episodeID: PersistentIdentifier) async throws {
        print("downloading transcript")
        guard let episode = modelContext.model(for: episodeID) as? Episode else {
            throw TranscriptError.episodeNotFound }
        
        guard episode.transcriptLines == nil || episode.transcriptLines == [] else {
            throw TranscriptError.transcriptionExists }
        

        if let transcriptfile = bestExternalFile(
            in: episode.externalFiles.filter { $0.category == .transcript },
            preferredTypes: ["text/vtt"]
        ) {
            if let url = URL(string: transcriptfile.url) {
                let transcription = await downloadAndParseStringFile(url: url)
                if let transcription {
                    episode.transcriptLines = decodeTranscription(transcription)
                    modelContext.saveIfNeeded()
                    return
                }else{
                    throw TranscriptError.decodingFailed
                }
                
            }else{
                throw TranscriptError.noTranscriptFileFound
            }
        }else{
            throw TranscriptError.noTranscriptFileFound
        }
        
    }
    
    // Inside EpisodeActor
    func setTranscript(for episodeID: UUID, lines: [TranscriptLineAndTime]) async {
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        episode.transcriptLines = lines
        episode.refresh.toggle()
        modelContext.saveIfNeeded()
    }
    
    
    // EpisodeActor.swift additions

    // 1) Snapshot-only getter for local file URL and (optional) language string
    func episodeLocalFileAndLanguage(for episodeID: UUID) async -> (URL, String?)? {
        guard let episode = await fetchEpisode(byID: episodeID),
              let local = episode.localFile else { return nil }
        return (local, episode.podcast?.language)
    }

    // 2) Attach a TranscriptionItem to the Episode safely
    @MainActor
    func attachTranscriptionItem(_ item: TranscriptionItem, to episodeID: UUID) async {
        // Hop back into EpisodeActor isolation to fetch and mutate the model
        await self._attachTranscriptionItem(item, to: episodeID)
    }

    // Private actor-isolated worker
    private func _attachTranscriptionItem(_ item: TranscriptionItem, to episodeID: UUID) async {
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        episode.transcriptionItem = item
        modelContext.saveIfNeeded()
    }

    // 3) Decode VTT and persist transcript lines inside EpisodeActor
    func decodeAndSetTranscript(for episodeID: UUID, vtt: String) async {
        print("decoding vtt")
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        let lines = decodeTranscription(vtt) // existing helper returns [TranscriptLineAndTime]
        episode.transcriptLines = lines
        episode.refresh.toggle()
        modelContext.saveIfNeeded()
    }

    
    
    
    private func downloadAndParseStringFile(url: URL) async -> String?{
        print("downloadAndParseStringFile called with: \(url)")
        var stringURL = url
        do{
            let status = try await stringURL.status()
            switch status?.statusCode {
            case 200:
                break
            case 404:
                return nil
            case 410:
                if let newURL = status?.newURL{
                    stringURL = newURL
                }else{
                   break
                }
            default:
               break
            }
            do{
                 let stringData = try await URLSession(configuration: .default).data(from: stringURL)
                return String(decoding: stringData.0, as: UTF8.self)
            }catch{
                return nil
            }
        }catch {
            return nil
        }
    }
}

private struct SendableChapterData: Sendable {
    let title: String
    let start: Double
    let duration: Double?
    let imageData: Data?
}

private struct AudioFormatInfo: Sendable {
    let formatID: AudioFormatID
}

private struct MetadataLoader {
    static func loadChapters(from url: URL) async throws -> [SendableChapterData] {
        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.metadata)
        guard !metadata.isEmpty else { return [] }
        
        let languages = Locale.preferredLanguages
        let chapterMetadataGroups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages)
        
        var chapters: [SendableChapterData] = []
        
        for group in chapterMetadataGroups {
            guard let titleItem = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
                  let title = try? await titleItem.load(.value) as? String else {
                continue
            }
            
            let artworkData = try? await group.items.first(where: { $0.commonKey == .commonKeyArtwork })?.load(.value) as? Data
            
            let timeRange = group.timeRange
            let start = timeRange.start.seconds
            let duration = timeRange.duration.seconds
            
            let correctedStart = (start.isNaN || start < 0) ? 0 : start
            let correctedDuration = (duration.isNaN || duration < 0) ? nil : duration
            
            let chapter = SendableChapterData(
                title: title,
                start: correctedStart,
                duration: correctedDuration,
                imageData: artworkData
            )
            chapters.append(chapter)
        }
        
        return chapters
    }

    static func getAudioFormat(from url: URL) async throws -> AudioFormatInfo? {
        let asset = AVURLAsset(url: url)
        
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
           let audioTrack = audioTracks.first,
           let formatDescriptions = try? await audioTrack.load(.formatDescriptions) {
            
            for formatDescription in formatDescriptions {
                guard let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
                    continue
                }
                
                let audioFormatID = audioStreamBasicDescription.pointee.mFormatID
                return AudioFormatInfo(formatID: audioFormatID)
            }
        }
        return nil
    }
}

private struct JSONChapterList: Decodable {
    let version: String?
    let chapters: [JSONChapter]
}

private struct JSONChapter: Decodable {
    let startTime: Double
    let title: String
    let img: String?
    let url: String?
}
