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
        
        // print("archiveEpisode from Actor - episode: \(episode.title)")
        await removeFromPlaylist(episodeID)

        if episode.metaData == nil {
            episode.metaData = EpisodeMetaData()
        }
        episode.metaData?.isArchived = true
        episode.metaData?.isInbox = false
        episode.metaData?.status = .archived

        await deleteFile(episodeID: episodeID)
         modelContext.saveIfNeeded()
        NotificationCenter.default.post(name: .inboxDidChange, object: nil)
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
        // print("download episode \(episodeID)")
        guard let episode = await fetchEpisode(byID: episodeID) else {
            
            // print("❌ Could not find episode \(episodeID)")
            return }

        if let localFile = episode.localFile {
            if let url = episode.url, await DownloadManager.shared.download(from: url, saveTo: localFile, episodeID: episode.id) != nil {
                // print("✅ Episode download started - from \(String(describing: episode.url)) to \(localFile)")
            }else{
                // print("❌ Could not download Episode \(episodeID)")
            }
            await downloadTranscript(episode.persistentModelID)

        }
        
    }
    
    func processAfterCreation(episodeID: UUID) async {
        
       //  await BasicLogger.shared.log("processAfterCreation  - \(episodeID) - start")
        
        guard let episode = await fetchEpisode(byID: episodeID) else {
           //  await BasicLogger.shared.log("processAfterCreation ❌ Could not find episode \(episodeID)")
            return }
       //  await BasicLogger.shared.log("processAfterCreation  - \(episode.podcast?.title ?? "Unknown Podcast") - \(episode.title)")
        
        await NotificationManager().sendNotification(title: episode.podcast?.title ?? "New Episode", body: episode.title)
        let playnext = await PodcastSettingsModelActor(modelContainer: modelContainer).getPlaynextposition(for: episode.podcast?.id)
       //  await BasicLogger.shared.log("processAfterCreation - \(episode.title) playnext \(playnext)")
        if playnext != .none {
            try? await PlaylistModelActor(modelContainer: modelContainer).add(episodeID: episodeID, to: playnext)
        }
        
        await getRemoteChapters(episodeID: episodeID)

    }
    
    func getRemoteChapters(episodeID: UUID) async {
      
        guard let episode = await fetchEpisode(byID: episodeID) else {
            return }
        // print("check if remote Chapters shall be created for \(episode.title)")
        if let url = episode.url, let pubDate = episode.publishDate,
               let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()),
               pubDate > oneWeekAgo{
                // pubDate is less than 7 days old
             
                await extractRemoteMP3Chapters(url)
                    
                
            
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

       //  await BasicLogger.shared.log("Unarchiving episode \(episode.title)")
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
            
           //  await BasicLogger.shared.log("Could not mark Episode As Available")
            return }

        guard let url = episode.url else {
            return
        }
        episode.metaData?.isAvailableLocally = true
        await updateDuration(fileURL: fileURL)

        await createChapters(url)
  
        try? await transcribe(url)
        modelContext.saveIfNeeded()
        // print("✅ Metadata updated")
       //  await BasicLogger.shared.log("Did mark Episode As Available")
    }
    

    
    func transcribe(_ fileURL: URL) async throws {
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = await UIApplication.shared.beginBackgroundTask(withName: "Transcription") { [task = bgTask] in
            UIApplication.shared.endBackgroundTask(task)
        }
        defer {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        // --- Begin original logic ---
        guard let episode = await fetchEpisode(byURL: fileURL) else {
            return  }
         guard let localFile = episode.localFile else {
            return }
       
        let transcriber = await AITranscripts(url: localFile, language: episode.podcast?.language)
        let transcription = try await transcriber.transcribeTovTT()
        
        if let transcription = transcription {
            episode.transcriptLines = decodeTranscription(transcription)
            episode.refresh.toggle()
        }
        modelContext.saveIfNeeded()
        // --- End original logic ---
    }
    

    
    func decodeTranscription(_ transcription: String) -> [TranscriptLineAndTime] {
        let decoder = TranscriptDecoder(transcription)
        let lines = decoder.transcriptLines
        var transcript = [TranscriptLineAndTime]()
        /*
        let maxLineLength = 84 // Two lines of 42 chars
        let minDuration: Double = 1.0
        let sentenceSeparators: [Character] = [".", "?", "!"]
        */
         for line in lines {
            let text = line.text
            let start = line.startTime
            let end = line.endTime
            let speaker = line.speaker
        /*
         
         The following code should split long lines into shorter lines. but somehow it has a bug. needs more work.
         
         
            if text.count <= maxLineLength {
                transcript.append(TranscriptLineAndTime(speaker: speaker, text: text, startTime: start, endTime: end))
            } else {
                // Split into sentences using period, exclamation, or question mark
                let sentences = text.split(whereSeparator: { sentenceSeparators.contains($0) }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                var chunks: [String] = []
                var currentChunk = ""
                for sentence in sentences where !sentence.isEmpty {
                    let extendedSentence = (sentence.last == "." || sentence.last == "!" || sentence.last == "?") ? sentence : sentence + "."
                    if currentChunk.count + extendedSentence.count + 1 > maxLineLength {
                        if !currentChunk.isEmpty {
                            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                            currentChunk = ""
                        }
                    }
                    if !currentChunk.isEmpty {
                        currentChunk += " "
                    }
                    currentChunk += extendedSentence
                }
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                // If a single sentence is too long, fall back to word-splitting
                for (i, chunk) in chunks.enumerated() where chunk.count > maxLineLength {
                    // Replace the chunk with smaller word-based chunks
                    let words = chunk.split(separator: " ")
                    var wordChunk = ""
                    var replacementChunks: [String] = []
                    for word in words {
                        if (wordChunk.count + word.count + 1) > maxLineLength {
                            if !wordChunk.isEmpty {
                                replacementChunks.append(wordChunk)
                                wordChunk = ""
                            }
                        }
                        if !wordChunk.isEmpty {
                            wordChunk += " "
                        }
                        wordChunk += word
                    }
                    if !wordChunk.isEmpty {
                        replacementChunks.append(wordChunk)
                    }
                    chunks.remove(at: i)
                    chunks.insert(contentsOf: replacementChunks.reversed(), at: i)
                }
                // Assign times proportionally
                let totalChunks = chunks.count
                let totalDuration = end - start
                let baseDuration = max(totalDuration / Double(totalChunks), minDuration)
                var chunkStart = start
                for (i, chunk) in chunks.enumerated() {
                    let chunkEnd: Double
                    if i == totalChunks - 1 {
                        chunkEnd = end
                    } else {
                        chunkEnd = min(chunkStart + baseDuration, end)
                    }
                    transcript.append(TranscriptLineAndTime(speaker: speaker, text: String(chunk), startTime: chunkStart, endTime: chunkEnd))
                    chunkStart = chunkEnd
                }
            }
         */
            transcript.append(TranscriptLineAndTime(speaker: speaker, text: text, startTime: start, endTime: end))
        }
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
       //  await BasicLogger.shared.log("creating Chapters for \(episode.title)")
        
        // Check if there is an external chapter file
        if let chapterFile = episode.externalFiles.first(where: { $0.category == .chapter }) {
           //  await BasicLogger.shared.log("Downloading Chapters for \(episode.title) of type \(chapterFile.fileType ?? "unknown")")
            if let url = URL(string: chapterFile.url) {
                // Check for file extension or fileType indicating JSON
                let isJSON = (url.pathExtension.lowercased() == "json") || (chapterFile.fileType?.lowercased().contains("json") == true)
                if isJSON {
                    // If JSON, download and parse chapters from JSON format
                    if let jsonString = await downloadAndParseStringFile(url: url),
                       let jsonData = jsonString.data(using: .utf8),
                       let chapters = await parseJSONChapters(jsonData: jsonData) {
                        episode.chapters?.removeAll(where: { $0.type == .extracted })
                        episode.chapters?.append(contentsOf: chapters)
                        modelContext.saveIfNeeded()
                        // print("Imported \(chapters.count) chapters from JSON.")
                    }
                }
            }
        }
        
        if episode.chapters == nil {
            episode.chapters = []
        }
        if let chapters = episode.chapters, chapters.isEmpty || !(chapters.contains(where: { $0.type == .mp3 }) || chapters.contains(where: { $0.type == .mp4 })) {
            guard let url = episode.localFile else {
                // print("no local file")
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
            } catch {
                // print("Error determining audio format: \(error)")
            }
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
       //  await BasicLogger.shared.log("apply Auto Skip Chapters for \(episode.title)")

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
                       //  await BasicLogger.shared.log("Chapter \(chapter.title) should be skipped")
                        
                        chapter.shouldPlay = false
                    }
                }
            }
        }
        modelContext.saveIfNeeded()
    }
    

    
  private  func extractMP3Chapters(_ episodeID: PersistentIdentifier) async {
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return  }
        // print("extractMP3Chapters")
       
        guard let url = episode.localFile else {
            // print("no local file")
            return
        }
        guard url.lastPathComponent.hasSuffix(".mp3") else {
            // print("not an mp3")
            return
        }
        
        do {
         
            let data = try Data(contentsOf: url)
            
            // Check if the file starts with the "ID3" identifier indicating an ID3v2 tag
            guard data.count >= 3, let id3Identifier = String(data: data[0..<3], encoding: .utf8), id3Identifier == "ID3" else {
                // print("could not find ID3v2 tag")
                return
            }
            
          //  let id3 = try? await mp3ChapterParser.fromRemoteURL(url)
            
            
            if let mp3Reader = mp3ChapterReader(with: url){
         
                let dict = mp3Reader.getID3Dict()
                
                if let chapters = parse(chapters: dict){
                   
                    episode.chapters?.removeAll(where: { $0.type == .mp3 })
                    episode.chapters?.append(contentsOf: chapters)
                     modelContext.saveIfNeeded()
                }

            }
            
            return  //chapters
        } catch {
            // print("Error extracting chapter marks: \(error.localizedDescription)")
            return
        }
    }
    
    func extractRemoteMP3Chapters(_ fileURL: URL) async {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return  }
        // print("extractRemoteMP3Chapters for \(episode.title)")
        
        if let remoteURL = episode.url, let mp3Reader = await mp3ChapterReader.fromRemoteURL(remoteURL) {
            let dict = mp3Reader.getID3Dict()
            if let chapters = parse(chapters: dict) {
                // print("got \(chapters.count) Remote Chapters")
                episode.chapters?.removeAll(where: { $0.type == .mp3 })
                episode.chapters?.append(contentsOf: chapters)
                modelContext.saveIfNeeded()
            }
        }
    }

    
    private func parse(chapters: [String: Any]) -> [Marker]?{
        // print("parse chapters")
        if let chaptersDict = chapters["Chapters"] as? [String:[String:Any]]{
            var chapters: [Marker] = []
            for chapter in chaptersDict {
                
                let newChaper = Marker()
                newChaper.title = chapter.value["TIT2"] as? String ?? ""
                newChaper.start = chapter.value["startTime"] as? Double ?? 0
               
                newChaper.duration = (chapter.value["endTime"] as? Double ?? 0) - (newChaper.start ?? 0)
                newChaper.type = .mp3
                if let imagedata = (chapter.value["APIC"] as? [String:Any])?["Data"] as? Data{
                    // print("ImageChapter with Image data")
                    newChaper.imageData = imagedata
                }else{
                                            }
                chapters.append(newChaper)
            }
            return chapters
        }
        return nil
    }
    
    /// Parses JSON formatted chapters data into an array of Chapter models asynchronously.
    /// - Parameter jsonData: The JSON data representing chapters.
    /// - Returns: An optional array of Chapter objects or nil if decoding fails.
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
                    // Load image data synchronously here (could be improved to async if needed)
                    chapter.imageData = try? Data(contentsOf: imgUrl)
                }
                // Optionally handle ch.url if needed
                chapters.append(chapter)
            }
            return chapters
        } catch {
            // print("Failed to decode chapter JSON: \(error)")
            return nil
        }
    }
    
    // Non-isolated helper function to load metadata
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
    
    //MARK: CHAPTERS
   private func extractM4AChapters(_ episodeID: PersistentIdentifier) async {
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return }
        guard let url = episode.localFile else {
            // print("no local file")
            return
        }
        
        do {
            let chapterData = try await MetadataLoader.loadChapters(from: url)
            
            // Create Chapter objects within the actor context
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
            // print("Error loading chapters: \(error)")
        }
    }
    
    func extractTranscriptChapters(fileURL: URL) async  {
        // print("extractTranscriptChapters")
        guard let episode = await fetchEpisode(byURL: fileURL) else { return  }
        guard let transcriptLines = episode.transcriptLines, transcriptLines != [] else {
            // print("no transcript")
            return  }
        
        let extractedData = await generateAIChapters(from: transcriptLines)
        if !extractedData.isEmpty {
            var newchapters:[Marker] = []
            for extractedChapter in extractedData{
                if let startingTime =  extractedChapter.key.durationAsSeconds{
                    // print("chapter at \(extractedChapter.key) : \(extractedChapter.value) -- \(startingTime.formatted())")
                    let newChapter = Marker(start: startingTime, title: extractedChapter.value, type: .extracted)
                    newchapters.append(newChapter)
                }
            }
            // print("returning \(newchapters.count.formatted()) Chapters")
            episode.chapters?.removeAll(where: { $0.type == .ai })
            episode.chapters?.append(contentsOf: newchapters)
            modelContext.saveIfNeeded()
        }
        
    }
    
    //MARK: Create Chapters from Episode Description
    func extractShownotesChapters(fileURL: URL) async  {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return  }
        guard let text = episode.desc else { return  }
        // print("extracting Chapters from Shownotes")
        var extractedData = extractTimeCodesAndTitles(from: text)
        
        if  extractedData == nil || extractedData?.count == 0{
            extractedData = await generateAIChapters(from: text)
        }
       
        if let extractedData {
            var newchapters:[Marker] = []
            for extractedChapter in extractedData{
                if let startingTime =  extractedChapter.key.durationAsSeconds{
                    // print("chapter at \(extractedChapter.key) : \(extractedChapter.value) -- \(startingTime.formatted())")
                    let newChapter = Marker(start: startingTime, title: extractedChapter.value, type: .extracted)
                    newchapters.append(newChapter)
                }
            }
            // print("returning \(newchapters.count.formatted()) Chapters")
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
        // print("AI Chapters")
        let chapterGenerator = AIChapterGenerator()
        let aiChapters = await chapterGenerator.extractChaptersFromText(htmlEncodedText)
        return aiChapters
    }
    
    func generateAIChapters(from transcript: [TranscriptLineAndTime]) async -> [String: String] {
        // print("AI Transcript Chapters")
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
            // print("Error serializing transcript lines to JSON: \(error)")
            return nil
        }
    }
    
    func updateChapterDurations(episodeURL: URL) async {
        // print("update Chapter durations")
        guard let episode = await fetchEpisode(byURL: episodeURL) else {
            // print("episode not found")
            return }
        var chapters = episode.preferredChapters

        // Sort chapters in ascending order of start time
        chapters.sort { ($0.start ?? 0.0) < ($1.start ?? 0.0) }
        // print("updating \(chapters.count.formatted()) chapters of type \(chapters.first?.type ?? .unknown)")
   
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
    
   
    
    
    //MARK: Transcript
    
    func downloadTranscript(_ episodeID: PersistentIdentifier) async {
        // print("downloadTranscript")
        guard let episode = modelContext.model(for: episodeID) as? Episode else {
            // print("episode not found")
            return }
        
        guard episode.transcriptLines == nil || episode.transcriptLines == [] else {
            // print("transcriptLines already exists")

            return }

            if let transcriptfile = episode.externalFiles.first(where: { $0.category == .transcript}) {
               //  await BasicLogger.shared.log("Downloading transcript for \(episode.title) of type \(transcriptfile.fileType ?? "unknown")")
                
                    if let url = URL(string: transcriptfile.url){
                        let transcription = await downloadAndParseStringFile(url: url)
                        
                        if let transcription = transcription {
                            episode.transcriptLines = decodeTranscription(transcription)
                        }
                        
                        modelContext.saveIfNeeded()
                    }
                
            }

       
        return
    }
    
    
    private func downloadAndParseStringFile(url: URL) async -> String?{
        var stringURL = url
        do{
            let status = try await stringURL.status()
            
            switch status?.statusCode {
            case 200:
                break
            case 404:
                // print("String file URL 404 failed")
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
                    // print("decoding string from \(stringURL.absoluteString)")
                   
                return String(decoding: stringData.0, as: UTF8.self)
                
                
            }catch{
                // print("error dewnloading String file: \(error)")
                return nil
            }
        }catch {
            // print("String File download failed  \(error)")
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
            
            // Validate the time fields for NaN and negative values
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

// Structures to decode JSON chapter format from external sources
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

