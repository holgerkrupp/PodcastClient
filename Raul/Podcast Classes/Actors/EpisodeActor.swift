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
    
    
    
    func fetchEpisode(byURL fileURL: URL) async -> Episode? {
        let predicate = #Predicate<Episode> { episode in
            episode.url == fileURL
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate))
            return results.first
        } catch {
            print("❌ Error fetching episode for file URL: \(fileURL.absoluteString), Error: \(error)")
            return nil
        }
    }
    
    func getLastPlayedEpisode() async -> Episode? {
        guard let episodeID = await getLastPlayedEpisodeID() else { return nil }
        return await fetchEpisode(byID: episodeID)
    }
    
    func updateDuration(fileURL: URL) async{
        guard let episode = await fetchEpisode(byURL: fileURL) else { return }
        if episode.duration == nil{
            if let localFile = episode.localFile, ((episode.metaData?.calculatedIsAvailableLocally) == true){
                do{
                    let duration = try await AVURLAsset(url: localFile).load(.duration)
                    let seconds = CMTimeGetSeconds(duration)
                    if !seconds.isNaN{
                        episode.duration = seconds
                    }
                    modelContext.saveIfNeeded()
                }catch{
                    print(error)
                }
            }else{
                print("no local file")
            }
        }
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
            print("❌ Error fetching or saving metadata: \(error)")
        }
        return nil

    }
    
    func setLastPlayed(_ episodeID: UUID, to date: Date = Date()) async {
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        
        episode.metaData?.lastPlayed = date
        modelContext.saveIfNeeded()
    }
    
    func setPlayPosition(episodeID: UUID, position: TimeInterval) async {
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        if position > episode.metaData?.maxPlayposition ?? 0.0 {
            episode.metaData?.maxPlayposition = position
            
        }
        episode.metaData?.playPosition = position
         modelContext.saveIfNeeded()

    }
    
    func markasPlayed(_ episodeID: UUID) async {
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        episode.metaData?.finishedPlaying = true
        episode.metaData?.isHistory = true
        modelContext.saveIfNeeded()
    }
    
    func archiveEpisode(episodeID: UUID) async {
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        if episode.metaData == nil {
            episode.metaData = EpisodeMetaData()
        }
        episode.metaData?.isArchived = true
        episode.metaData?.isInbox = false
        /*
        let PlaylistmodelActor = PlaylistModelActor(modelContainer: modelContainer)
        await PlaylistmodelActor.remove(episodeID: episodeID)
    */
        await deleteFile(episodeID: episodeID)
         modelContext.saveIfNeeded()
    }
    
    
    func download(episodeID: UUID) async {
        print("download episode \(episodeID)")
        guard let episode = await fetchEpisode(byID: episodeID) else {
            
            print("❌ Could not find episode \(episodeID)")
            return }

        if let localFile = episode.localFile {
            if await DownloadManager.shared.download(from: episode.url, saveTo: localFile, episodeID: episode.id) != nil {
                print("✅ Episode download started - from \(episode.url) to \(localFile)")

            }else{
                print("❌ Could not download Episode \(episodeID)")
            }
        }
    }
    
    func unarchiveEpisode(episodeID: UUID) async  {
        
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        episode.metaData?.isArchived = false
        episode.metaData?.isInbox = true
        await BasicLogger.shared.log("Unarchiving episode \(episode.title)")
        modelContext.saveIfNeeded()
    }
    
    func deleteFile(episodeID: UUID) async{
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        guard  episode.metaData?.isAvailableLocally == true else { return }

        if let file = episode.localFile{
            try? FileManager.default.removeItem(at: file)
            episode.metaData?.isAvailableLocally = false
        }
    }

    func markEpisodeHistory(episodeID: UUID, value: Bool) async {
        guard let episode = await fetchEpisode(byID: episodeID) else { return }

        episode.metaData?.isHistory = value
        modelContext.saveIfNeeded()
        print("✅ Metadata updated")
    }

    func markEpisodeAvailable(fileURL: URL) async {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return }

        episode.metaData?.isAvailableLocally = true
        await createChapters(episode.persistentModelID)
        await downloadTranscript(episode.persistentModelID)
        modelContext.saveIfNeeded()
        print("✅ Metadata updated")
    }
    
    func markEpisodeAvailable(episodeID: UUID) async {
        guard let episode = await fetchEpisode(byID: episodeID) else { return }

        episode.metaData?.isAvailableLocally = true
        await createChapters(episode.persistentModelID)
        await downloadTranscript(episode.persistentModelID)
        modelContext.saveIfNeeded()
        print("✅ Metadata updated")
    }
    
   private func createChapters(_ episodeID: PersistentIdentifier) async {
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return }
        guard let url = episode.localFile else {
            print("no local file")
            return
        }
        if episode.chapters.isEmpty {
            do {
                if let formatInfo = try await MetadataLoader.getAudioFormat(from: url) {
                    if formatInfo.formatID == kAudioFormatMPEGLayer3 {
                        await extractMP3Chapters(episode.persistentModelID)
                    } else if formatInfo.formatID == kAudioFormatMPEG4AAC {
                        await extractM4AChapters(episode.persistentModelID)
                    }
                }
            } catch {
                print("Error determining audio format: \(error)")
            }
        }
    }
    
  private  func extractMP3Chapters(_ episodeID: PersistentIdentifier) async {
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return  }
        print("extractMP3Chapters")
       
        guard let url = episode.localFile else {
            print("no local file")
            return
        }
        guard url.lastPathComponent.hasSuffix(".mp3") else {
            print("not an mp3")
            return
        }
        
        do {
         
            let data = try Data(contentsOf: url)
            
            // Check if the file starts with the "ID3" identifier indicating an ID3v2 tag
            guard data.count >= 3, let id3Identifier = String(data: data[0..<3], encoding: .utf8), id3Identifier == "ID3" else {
                print("could not find ID3v2 tag")
                return
            }
            
            if let mp3Reader = mp3ChapterReader(with: url){
         
                let dict = mp3Reader.getID3Dict()
                dump(dict)
                if let chaptersDict = dict["Chapters"] as? [String:[String:Any]]{
                    var chapters: [Chapter] = []
                    for chapter in chaptersDict {
                        
                        let newChaper = Chapter()
                        newChaper.title = chapter.value["TIT2"] as? String ?? ""
                        newChaper.start = chapter.value["startTime"] as? Double ?? 0
                       
                        newChaper.duration = (chapter.value["endTime"] as? Double ?? 0) - (newChaper.start ?? 0)
                        newChaper.type = .mp3
                        if let imagedata = (chapter.value["APIC"] as? [String:Any])?["Data"] as? Data{
                            print("ImageChapter with Image data")
                            newChaper.imageData = imagedata
                        }else{
                                                    }
                        chapters.append(newChaper)
                    }
                    episode.chapters.removeAll(where: { $0.type == .mp3 })
                    episode.chapters.append(contentsOf: chapters)
                     modelContext.saveIfNeeded()
                }

            }
            
            return  //chapters
        } catch {
            print("Error extracting chapter marks: \(error.localizedDescription)")
            return
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

   private func extractM4AChapters(_ episodeID: PersistentIdentifier) async {
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return }
        guard let url = episode.localFile else {
            print("no local file")
            return
        }
        
        do {
            let chapterData = try await MetadataLoader.loadChapters(from: url)
            
            // Create Chapter objects within the actor context
            let chapters = chapterData.map { data in
                let chapter = Chapter()
                chapter.title = data.title
                chapter.start = data.start
                chapter.duration = data.duration
                chapter.type = .embedded
                chapter.imageData = data.imageData
                return chapter
            }
            
            episode.chapters.removeAll(where: { $0.type == .embedded })
            episode.chapters.append(contentsOf: chapters)
            modelContext.saveIfNeeded()
        } catch {
            print("Error loading chapters: \(error)")
        }
    }
    
    func downloadTranscript(_ episodeID: PersistentIdentifier) async {
        print("downloadTranscript")
        guard let episode = modelContext.model(for: episodeID) as? Episode else {
            print("episode not found")
            return }

        if episode.transcriptData == nil {
            if let vttFileString = episode.transcripts.first(where: {$0.type == "text/vtt"})?.url,
               let vttURL = URL(string: vttFileString) {
                print(vttFileString)
                if let vttData = try? await URLSession(configuration: .default).data(from: vttURL) {
                   
                    episode.transcriptData = String(decoding: vttData.0, as: UTF8.self)
                     modelContext.saveIfNeeded()
                }
            }
        }else{
            print("transcriptData already exists")
        }
        return
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
