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
import ImageIO


@ModelActor
actor EpisodeActor {
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

    func fetchEpisodes(byURL fileURL: URL) async -> [Episode] {
        let predicate = #Predicate<Episode> { episode in
            episode.url == fileURL
        }

        do {
            return try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate))
        } catch {
            return []
        }
    }

    private func ensureMetadata(for episode: Episode) {
        guard episode.metaData == nil else { return }
        let metadata = EpisodeMetaData()
        metadata.episode = episode
        episode.metaData = metadata
    }
    
    func getLastPlayedEpisode() async -> Episode? {
        guard let episodeURL = await getLastPlayedEpisodeURL() else { return nil }
        return await fetchEpisode(byURL: episodeURL)
    }

    
    func updateDuration(fileURL: URL) async{
      
        guard let episode = await fetchEpisode(byURL: fileURL) else { return }
         print("updateDuration of \(episode.title)")
       
            if let localFile = episode.localFile, FileManager.default.fileExists(atPath: localFile.path){
                do{
                    let duration = try await AVURLAsset(url: localFile).load(.duration)
                    let seconds = CMTimeGetSeconds(duration)
                    if !seconds.isNaN{
                        episode.duration = seconds
                    }
                     print("new duration: \(seconds)")
                    modelContext.saveIfNeeded()
                }catch{
                     print(error)
                }
            }else{
                 print("no local file")
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
    
    func getLastPlayedEpisodeURL() async -> URL? {
        let predicate = #Predicate<Episode> { episode in
            episode.metaData?.isHistory == false
        }
        let sortDescriptors: [SortDescriptor<Episode>] = [
            SortDescriptor(\Episode.metaData?.lastPlayed, order: .reverse)
        ]
        do {
            let results = try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate, sortBy: sortDescriptors))

            return results.first?.url
        } catch {
            // print("❌ Error fetching or saving metadata: \(error)")
        }
        return nil

    }
    
    func setLastPlayed(episodeURL: URL, to date: Date = Date()) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        episode.metaData?.lastPlayed = date
        modelContext.saveIfNeeded()
    }
    
    func setPlayPosition(episodeURL: URL, position: TimeInterval, force: Bool = false) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        let previousPosition = episode.metaData?.playPosition ?? 0.0
        if force || abs(previousPosition - position) > 10 {
            if position > episode.metaData?.maxPlayposition ?? 0.0 {
                episode.metaData?.maxPlayposition = position
            }
            episode.metaData?.playPosition = position
            modelContext.saveIfNeeded()
        }

    }
    
    func markasPlayed(_ episodeURL: URL) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        episode.metaData?.completionDate = Date()
        episode.metaData?.isHistory = true
        episode.metaData?.status = .history

        modelContext.saveIfNeeded()
    }
    
    func removeFromPlaylist(_ episodeURL: URL) async {
        if let PlaylistmodelActor = try? PlaylistModelActor(modelContainer: modelContainer){
            try? await PlaylistmodelActor.remove(episodeURL: episodeURL)
        }
    }
    
    func archiveEpisode(_ episodeURL: URL?) async {
        guard let episodeURL else { return }
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard episodes.isEmpty == false else {
            print("could not find episode with URL \(episodeURL) to archive")
            return }
        
        await removeFromPlaylist(episodeURL)

        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.isArchived = true
            episode.metaData?.isInbox = false
            episode.metaData?.status = .archived
        }

        await deleteFile(episodeURL: episodeURL)
         modelContext.saveIfNeeded()
        await MainActor.run {
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
        }
        WatchSyncCoordinator.refreshSoon()
    }
    
    func unarchiveEpisode(_ episodeURL: URL?) async  {
        guard let episodeURL else { return }
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard episodes.isEmpty == false else { return }

        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.isArchived = false
            episode.metaData?.isInbox = true
            episode.metaData?.status = .inbox
        }
        modelContext.saveIfNeeded()
        WatchSyncCoordinator.refreshSoon()
    }
    
    func moveToHistory(episodeURL: URL) async {
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard episodes.isEmpty == false else { return }
        await removeFromPlaylist(episodeURL)

        for episode in episodes {
            ensureMetadata(for: episode)
            if episode.metaData?.lastPlayed == nil {
                episode.metaData?.lastPlayed = Date()
            }

            episode.metaData?.isHistory = true
            episode.metaData?.isInbox = false
            episode.metaData?.status = .history
        }
        
        modelContext.saveIfNeeded()
        NotificationCenter.default.post(name: .inboxDidChange, object: nil)
        WatchSyncCoordinator.refreshSoon()
    }
    
    
    func download(episodeURL: URL) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else {
            return }

        if let localFile = episode.localFile {
            if let url = episode.url, await DownloadManager.shared.download(from: url, saveTo: localFile) != nil {
            }
            try? await downloadTranscript(episode.persistentModelID)

        }
        
    }
    
    func processAfterCreation(episodeURL: URL) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else {
            return }
        
        
     /*   if episode.publishDate ?? Date() < episode.podcast?.metaData?.subscriptionDate ?? Date() {
            episode.metaData?.status = .archived
            episode.metaData?.isArchived = true
            modelContext.saveIfNeeded()
            return
        }
     */
        
        let playnext = await PodcastSettingsModelActor(modelContainer: modelContainer).getPlaynextposition(for: episode.podcast?.feed)
        print("Processing episode: \(episode.title) - playnext Status is \(playnext)")

        if playnext != .none {
            let playlistActor = try? PlaylistModelActor(modelContainer: modelContainer)
            try? await playlistActor?.add(episodeURL: episodeURL, to: playnext)
        }

        await NotificationManager().sendNotification(title: episode.podcast?.title ?? "New Episode", body: episode.title)
        await getRemoteChapters(episodeURL: episodeURL)
    }
    
    func getRemoteChapters(episodeURL: URL) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else {
            return }
        if let url = episode.url, let pubDate = episode.publishDate,
               let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()),
               pubDate > oneWeekAgo{
                await extractRemoteMP3Chapters(url)
                await applyAutoSkipWords(episodeURL: episodeURL)
        }
    }
    
    func createBookmark(for episodeURL: URL, at playPosition: Double) async{
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }

        let bookmarkTitle = episode.transcriptLines?.sorted(by: { $0.startTime < $1.startTime }).last(where: { $0.startTime < playPosition })?.text ?? episode.title
        let bookmark = Bookmark(start: playPosition, title: bookmarkTitle, type: .bookmark)
        episode.bookmarks?.append(bookmark)
        modelContext.saveIfNeeded()
    }
    
    func deleteFile(episodeURL: URL?) async{
        guard let episodeURL else { return }
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard let firstEpisode = episodes.first else { return }

        if let file = firstEpisode.localFile{
            try? FileManager.default.removeItem(at: file)
        }

        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.isAvailableLocally = false
        }
        
        modelContext.saveIfNeeded()
        WatchSyncCoordinator.refreshSoon()
    }

    func markEpisodeAvailable(fileURL: URL) async {
        print("mark Available for \(fileURL)")
        guard let episode = await fetchEpisode(byURL: fileURL) else {
            print("episode not found")
            return }

        print ("markEpisodeAvailable for \(episode.title)")
        guard let url = episode.url else {
            return
        }
        episode.metaData?.isAvailableLocally = true
        await updateDuration(fileURL: url)

        await createChapters(url)
        let settingsActor = PodcastSettingsModelActor(modelContainer: modelContainer)
        let automaticOnDeviceTranscriptionsEnabled = await settingsActor
            .getAutomaticOnDeviceTranscriptionsEnabled()
        let automaticOnDeviceTranscriptionsRequireCharging = await settingsActor
            .getAutomaticOnDeviceTranscriptionsRequiresCharging()
        let isConnectedToPower = automaticOnDeviceTranscriptionsRequireCharging
            ? await isDeviceConnectedToPower()
            : true
        let allowAutomaticOnDeviceFallback = automaticOnDeviceTranscriptionsEnabled
            && isConnectedToPower
        try? await transcribe(url, allowOnDeviceFallback: allowAutomaticOnDeviceFallback)
        modelContext.saveIfNeeded()
        WatchSyncCoordinator.refreshSoon()
    }
    
    // NEW: Delegate to TranscriptionManager
    func transcribe(_ fileURL: URL, allowOnDeviceFallback: Bool = true) async throws {
        print("transcribe")
        guard let episode = await fetchEpisode(byURL: fileURL) else { return }
        guard let episodeURL = episode.url else { return }

        if episode.hasLoadedTranscript {
            return
        }
        
        if episode.externalFiles.contains(where: { $0.category == .transcript}) {
            do {
                try await downloadTranscript(episode.persistentModelID)
                return
            } catch let error as TranscriptError {
                switch error {
                case .transcriptionExists:
                    return
                case .noTranscriptFileFound, .decodingFailed:
                    print(error)
                case .episodeNotFound:
                    throw error
                }
            } catch {
                print(error)
            }
        }

        guard allowOnDeviceFallback else {
            return
        }

        let transcriptionManager = await MainActor.run { TranscriptionManager.shared }
        _ = await transcriptionManager.enqueueTranscription(episodeURL: episodeURL)
    }

    private func isDeviceConnectedToPower() async -> Bool {
        await MainActor.run {
            let device = UIDevice.current
            let wasBatteryMonitoringEnabled = device.isBatteryMonitoringEnabled
            if wasBatteryMonitoringEnabled == false {
                device.isBatteryMonitoringEnabled = true
            }

            let isConnectedToPower: Bool
            switch device.batteryState {
            case .charging, .full:
                isConnectedToPower = true
            case .unknown, .unplugged:
                isConnectedToPower = false
            @unknown default:
                isConnectedToPower = false
            }

            if wasBatteryMonitoringEnabled == false {
                device.isBatteryMonitoringEnabled = false
            }

            return isConnectedToPower
        }
    }

    func isReadyForAutomaticTranscription(episodeURL: URL) async -> Bool {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return false }
        guard episode.url != nil else { return false }
        guard episode.hasLoadedTranscript == false else { return false }
        return episode.metaData?.calculatedIsAvailableLocally == true
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
        
        if episode.chapters == nil {
            episode.chapters = []
        }
        
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
        

        if let chapters = episode.chapters, !(chapters.contains(where: { $0.type == .mp3 }) || chapters.contains(where: { $0.type == .mp4 })) {
            if let url = episode.localFile  {
              
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
        }
        if let chapers = episode.chapters, chapers.isEmpty, let url = episode.url{
            await extractShownotesChapters(fileURL: url)
        }
        if let url = episode.url{
            await updateChapterDurations(episodeURL: url)
        }
        if let url = episode.url {
            await applyAutoSkipWords(episodeURL: url)
        }
    }

    func maintainChapterImageStorage() async -> ChapterImageMaintenanceResult {
        let upNextEpisodeURLs = await currentUpNextEpisodeURLs()
        guard let episodes = try? modelContext.fetch(FetchDescriptor<Episode>()) else {
            return ChapterImageMaintenanceResult()
        }

        var result = ChapterImageMaintenanceResult()

        for episode in episodes {
            guard let episodeURL = episode.url else { continue }

            if upNextEpisodeURLs.contains(episodeURL) {
                result.restoredImageCount += await restoreFullSizeChapterImages(for: episodeURL)
            } else {
                let optimized = optimizeStoredChapterImages(for: episode)
                result.optimizedImageCount += optimized.count
                result.optimizedBytesSaved += optimized.bytesSaved
            }
        }

        modelContext.saveIfNeeded()
        return result
    }

    @discardableResult
    func restoreFullSizeChapterImages(for episodeURL: URL) async -> Int {
        let sourceDataByKey = await bestChapterSourceData(for: episodeURL)
        guard !sourceDataByKey.isEmpty,
              let episode = await fetchEpisode(byURL: episodeURL),
              let chapters = episode.chapters,
              !chapters.isEmpty else {
            return 0
        }

        var restoredImageCount = 0
        var didChange = false

        for chapter in chapters {
            let key = chapterKey(for: chapter.title, start: chapter.start ?? 0, type: chapter.type)
            guard let source = sourceDataByKey[key] else { continue }

            if chapter.image == nil, let imageURL = source.imageURL {
                chapter.image = imageURL
                didChange = true
            }

            guard let sourceImageData = source.imageData else { continue }
            if shouldReplaceChapterImage(currentData: chapter.imageData, sourceData: sourceImageData) {
                chapter.imageData = sourceImageData
                restoredImageCount += 1
                didChange = true
            }
        }

        if didChange {
            episode.refresh.toggle()
            modelContext.saveIfNeeded()
        }

        return restoredImageCount
    }
    
    private func applyAutoSkipWords(episodeURL: URL) async{
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        let actor = PodcastSettingsModelActor(modelContainer: modelContainer)
        guard let skipWord = await actor.getChapterSkipKeywords(for: episode.podcast?.feed) else {
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

    private func currentUpNextEpisodeURLs() async -> Set<URL> {
        guard let playlistActor = try? PlaylistModelActor(modelContainer: modelContainer) else {
            return []
        }

        let upNextURLs = (try? await playlistActor.orderedEpisodeURLs()) ?? []
        return Set(upNextURLs)
    }

    private func bestChapterSourceData(for episodeURL: URL) async -> [String: SendableChapterSourceData] {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return [:] }

        let snapshot = EpisodeChapterSourceSnapshot(
            remoteURL: episode.url,
            localFile: episode.localFile,
            chapterFiles: episode.externalFiles
                .filter { $0.category == .chapter }
                .map { ChapterExternalFileSnapshot(urlString: $0.url, fileType: $0.fileType) },
            chapterImages: (episode.chapters ?? []).map {
                StoredChapterImageSnapshot(
                    title: $0.title,
                    start: $0.start ?? 0,
                    type: $0.type,
                    imageURL: $0.image
                )
            }
        )

        var sourceDataByKey: [String: SendableChapterSourceData] = [:]

        for source in await chapterSourceData(for: snapshot) {
            let key = chapterKey(for: source.title, start: source.start, type: source.type)
            if let existing = sourceDataByKey[key] {
                sourceDataByKey[key] = mergedChapterSource(existing, with: source)
            } else {
                sourceDataByKey[key] = source
            }
        }

        return sourceDataByKey
    }

    private func chapterSourceData(for snapshot: EpisodeChapterSourceSnapshot) async -> [SendableChapterSourceData] {
        var sources: [SendableChapterSourceData] = []

        sources.append(contentsOf: await existingChapterImageSourceData(for: snapshot.chapterImages))
        sources.append(contentsOf: await jsonChapterSourceData(for: snapshot.chapterFiles))

        if let localFile = snapshot.localFile {
            let lowercasedExtension = localFile.pathExtension.lowercased()
            if lowercasedExtension == "mp3" {
                sources.append(contentsOf: mp3ChapterSourceData(from: localFile))
            } else if ChapterImageStorageConfiguration.mpeg4Extensions.contains(lowercasedExtension) {
                sources.append(contentsOf: await m4aChapterSourceData(from: localFile))
            } else if let formatInfo = try? await MetadataLoader.getAudioFormat(from: localFile) {
                switch formatInfo.formatID {
                case kAudioFormatMPEGLayer3:
                    sources.append(contentsOf: mp3ChapterSourceData(from: localFile))
                case kAudioFormatMPEG4AAC:
                    sources.append(contentsOf: await m4aChapterSourceData(from: localFile))
                default:
                    break
                }
            }
        } else if let remoteURL = snapshot.remoteURL {
            let lowercasedExtension = remoteURL.pathExtension.lowercased()
            if lowercasedExtension == "mp3" {
                sources.append(contentsOf: await remoteMP3ChapterSourceData(from: remoteURL))
            } else if ChapterImageStorageConfiguration.mpeg4Extensions.contains(lowercasedExtension) {
                sources.append(contentsOf: await m4aChapterSourceData(from: remoteURL))
            }
        }

        return sources
    }

    private func existingChapterImageSourceData(for chapters: [StoredChapterImageSnapshot]) async -> [SendableChapterSourceData] {
        var sources: [SendableChapterSourceData] = []

        for chapter in chapters {
            guard let imageURL = chapter.imageURL else { continue }
            let imageData = await downloadBinaryFile(url: imageURL)
            sources.append(
                SendableChapterSourceData(
                    title: chapter.title,
                    start: chapter.start,
                    type: chapter.type,
                    imageURL: imageURL,
                    imageData: imageData
                )
            )
        }

        return sources
    }

    private func mp3ChapterSourceData(from url: URL) -> [SendableChapterSourceData] {
        guard let mp3Reader = mp3ChapterReader(with: url),
              let chapters = parse(chapters: mp3Reader.getID3Dict()) else {
            return []
        }

        return chapters.map {
            SendableChapterSourceData(
                title: $0.title,
                start: $0.start ?? 0,
                type: .mp3,
                imageURL: nil,
                imageData: $0.imageData
            )
        }
    }

    private func remoteMP3ChapterSourceData(from url: URL) async -> [SendableChapterSourceData] {
        guard let mp3Reader = await mp3ChapterReader.fromRemoteURL(url),
              let chapters = parse(chapters: mp3Reader.getID3Dict()) else {
            return []
        }

        return chapters.map {
            SendableChapterSourceData(
                title: $0.title,
                start: $0.start ?? 0,
                type: .mp3,
                imageURL: nil,
                imageData: $0.imageData
            )
        }
    }

    private func m4aChapterSourceData(from url: URL) async -> [SendableChapterSourceData] {
        guard let chapterData = try? await MetadataLoader.loadChapters(from: url) else {
            return []
        }

        return chapterData.map {
            SendableChapterSourceData(
                title: $0.title,
                start: $0.start,
                type: .mp4,
                imageURL: nil,
                imageData: $0.imageData
            )
        }
    }

    private func jsonChapterSourceData(for chapterFiles: [ChapterExternalFileSnapshot]) async -> [SendableChapterSourceData] {
        var sources: [SendableChapterSourceData] = []

        for chapterFile in chapterFiles {
            guard let url = URL(string: chapterFile.urlString) else { continue }

            let isJSON = url.pathExtension.lowercased() == "json"
                || (chapterFile.fileType?.lowercased().contains("json") == true)
            guard isJSON,
                  let jsonString = await downloadAndParseStringFile(url: url),
                  let jsonData = jsonString.data(using: .utf8),
                  let chapterSources = await parseJSONChapterData(jsonData: jsonData) else {
                continue
            }

            sources.append(contentsOf: chapterSources)
        }

        return sources
    }

    private func parseJSONChapterData(jsonData: Data) async -> [SendableChapterSourceData]? {
        do {
            let decoder = JSONDecoder()
            let chapterList = try decoder.decode(JSONChapterList.self, from: jsonData)
            var chapters: [SendableChapterSourceData] = []

            for chapter in chapterList.chapters {
                let imageURL = chapter.img.flatMap(URL.init(string:))
                let imageData: Data?
                if let imageURL {
                    imageData = await downloadBinaryFile(url: imageURL)
                } else {
                    imageData = nil
                }

                chapters.append(
                    SendableChapterSourceData(
                        title: chapter.title,
                        start: chapter.startTime,
                        type: .extracted,
                        imageURL: imageURL,
                        imageData: imageData
                    )
                )
            }

            return chapters
        } catch {
            return nil
        }
    }

    private func mergedChapterSource(
        _ current: SendableChapterSourceData,
        with candidate: SendableChapterSourceData
    ) -> SendableChapterSourceData {
        let imageData = preferredImageData(current.imageData, candidate.imageData)

        return SendableChapterSourceData(
            title: current.title,
            start: current.start,
            type: current.type,
            imageURL: current.imageURL ?? candidate.imageURL,
            imageData: imageData
        )
    }

    private func preferredImageData(_ lhs: Data?, _ rhs: Data?) -> Data? {
        switch (lhs, rhs) {
        case let (left?, right?):
            let leftDimension = imageMaxDimension(for: left)
            let rightDimension = imageMaxDimension(for: right)

            if rightDimension > leftDimension + 1 {
                return right
            }
            if leftDimension > rightDimension + 1 {
                return left
            }

            return right.count > left.count ? right : left
        case (nil, let right?):
            return right
        case (let left?, nil):
            return left
        case (nil, nil):
            return nil
        }
    }

    private func optimizeStoredChapterImages(for episode: Episode) -> (count: Int, bytesSaved: Int64) {
        guard let chapters = episode.chapters, !chapters.isEmpty else {
            return (0, 0)
        }

        var optimizedImageCount = 0
        var optimizedBytesSaved: Int64 = 0

        for chapter in chapters {
            guard let currentData = chapter.imageData,
                  let downscaledData = downscaledChapterImageData(from: currentData),
                  downscaledData.count < currentData.count else {
                continue
            }

            chapter.imageData = downscaledData
            optimizedImageCount += 1
            optimizedBytesSaved += Int64(currentData.count - downscaledData.count)
        }

        if optimizedImageCount > 0 {
            episode.refresh.toggle()
        }

        return (optimizedImageCount, optimizedBytesSaved)
    }

    private func downscaledChapterImageData(from data: Data) -> Data? {
        let maxDimension = imageMaxDimension(for: data)
        guard maxDimension > ChapterImageStorageConfiguration.compactMaxPixelSize
                || data.count > ChapterImageStorageConfiguration.minimumCandidateBytes else {
            return nil
        }

        guard let image = ImageLoaderAndCache.makeUIImage(
            from: data,
            maxPixelSize: ChapterImageStorageConfiguration.compactMaxPixelSize
        ) else {
            return nil
        }

        if let jpegData = image.jpegData(compressionQuality: ChapterImageStorageConfiguration.jpegQuality),
           jpegData.count < data.count {
            return jpegData
        }

        if let pngData = image.pngData(), pngData.count < data.count {
            return pngData
        }

        return nil
    }

    private func shouldReplaceChapterImage(currentData: Data?, sourceData: Data) -> Bool {
        guard !sourceData.isEmpty else { return false }
        guard let currentData, !currentData.isEmpty else { return true }

        let currentDimension = imageMaxDimension(for: currentData)
        let sourceDimension = imageMaxDimension(for: sourceData)

        if sourceDimension > currentDimension + ChapterImageStorageConfiguration.minimumRestorePixelGain {
            return true
        }

        return sourceData.count > currentData.count + ChapterImageStorageConfiguration.minimumRestoreByteGain
    }

    private func chapterKey(for title: String, start: Double, type: MarkerType) -> String {
        let normalizedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedStart = Int((start * 100).rounded())
        return "\(type.rawValue)|\(normalizedStart)|\(normalizedTitle)"
    }

    private func imageMaxDimension(for data: Data) -> CGFloat {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return 0
        }

        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        return CGFloat(max(width, height))
    }

    private func downloadBinaryFile(url: URL) async -> Data? {
        await ImageLoaderAndCache.loadImageData(from: url, saveTo: nil)
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
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let headerData = try handle.read(upToCount: 10) ?? Data()
            guard headerData.count >= 3,
                  let id3Identifier = String(data: headerData.prefix(3), encoding: .utf8),
                  id3Identifier == "ID3" else {
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
                    chapter.image = imgUrl
                    chapter.imageData = await downloadBinaryFile(url: imgUrl)
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
            for extractedChapter in extractedData.sorted(by: { ($0.key.durationAsSeconds ?? 0) < ($1.key.durationAsSeconds ?? 0) }) {
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
            for extractedChapter in extractedData.sorted(by: { ($0.key.durationAsSeconds ?? 0) < ($1.key.durationAsSeconds ?? 0) }) {
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
        let normalizedText = normalizedShownotesTextForChapterParsing(from: htmlEncodedText)
        let nsText = normalizedText as NSString

        guard let timeRegex = try? NSRegularExpression(
            pattern: #"(?<!\d)((?:\d{1,2}:)?[0-5]?\d:[0-5]\d)(?!\d)"#
        ) else { return nil }

        let matches = timeRegex.matches(in: normalizedText, range: NSRange(location: 0, length: nsText.length))
        guard matches.isEmpty == false else { return nil }

        var parsedEntries: [(time: String, title: String)] = []

        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges >= 2 else { continue }
            let rawTimeCode = nsText.substring(with: match.range(at: 1))
            guard let canonicalTimeCode = canonicalChapterTimeCode(from: rawTimeCode) else { continue }

            let titleStart = match.range.upperBound
            let titleEnd = index + 1 < matches.count ? matches[index + 1].range.lowerBound : nsText.length
            guard titleStart <= titleEnd else { continue }

            let rawTitleSegment = nsText.substring(with: NSRange(location: titleStart, length: titleEnd - titleStart))
            guard let title = extractChapterTitle(from: rawTitleSegment) else { continue }
            parsedEntries.append((canonicalTimeCode, title))
        }

        guard parsedEntries.count >= 2 else { return nil }

        var result: [String: String] = [:]
        for entry in parsedEntries {
            result[entry.time] = entry.title
        }
        return result.isEmpty ? nil : result
    }

    private func normalizedShownotesTextForChapterParsing(from htmlEncodedText: String) -> String {
        var text = htmlEncodedText.decodeHTML() ?? htmlEncodedText

        let replacements: [String: String] = [
            "\r\n": "\n",
            "\r": "\n",
            "\u{2028}": "\n",
            "\u{2029}": "\n",
            "\u{0085}": "\n",
            "\u{00A0}": " "
        ]
        for (needle, replacement) in replacements {
            text = text.replacingOccurrences(of: needle, with: replacement)
        }

        text = text.replacingOccurrences(
            of: #"(?<=\S)(?=(?:\d{1,2}:)?[0-5]?\d:[0-5]\d)"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text
    }

    private func canonicalChapterTimeCode(from rawValue: String) -> String? {
        let parts = rawValue.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let hours: Int
        let minutes: Int
        let seconds: Int

        if parts.count == 2 {
            hours = 0
            minutes = parts[0]
            seconds = parts[1]
        } else {
            hours = parts[0]
            minutes = parts[1]
            seconds = parts[2]
        }

        guard (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func extractChapterTitle(from rawSegment: String) -> String? {
        let lines = rawSegment
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        for line in lines {
            var candidate = line
            candidate = candidate.replacingOccurrences(
                of: #"^[\-\–\—:\|•·*>\)\]\.]+\s*"#,
                with: "",
                options: .regularExpression
            )
            candidate = candidate.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

            if candidate.isEmpty == false {
                return candidate
            }
        }

        return nil
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
        preferredTypes: [String] = [
            "text/vtt",
            "text/webvtt",
            "application/vtt",
            "application/x-subrip",
            "text/srt",
            "application/json",
            "text/json",
            "text/plain"
        ]
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
        if let jsonByExt = files.first(where: { URL(string: $0.url)?.pathExtension.lowercased() == "json" }) {
            return jsonByExt
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
            preferredTypes: [
                "text/vtt",
                "text/webvtt",
                "application/vtt",
                "application/x-subrip",
                "text/srt",
                "application/json",
                "text/json",
                "text/plain"
            ]
        ) {
            if let url = URL(string: transcriptfile.url) {
                let transcription = await downloadAndParseStringFile(url: url)
                if let transcription {
                    episode.transcriptLines = decodeTranscription(transcription)
                    episode.refresh.toggle()
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
    func setTranscript(for episodeURL: URL, lines: [TranscriptLineAndTime]) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        episode.transcriptLines = lines
        episode.refresh.toggle()
        modelContext.saveIfNeeded()
    }
    
    
    // EpisodeActor.swift additions

    // 1) Snapshot-only getter for local file URL and (optional) language string
    func episodeLocalFileAndLanguage(for episodeURL: URL) async -> (URL, String?)? {
        guard let episode = await fetchEpisode(byURL: episodeURL),
              let local = episode.localFile else { return nil }
        return (local, episode.podcast?.language)
    }

    func transcriptionSnapshot(for episodeURL: URL) async -> TranscriptionEpisodeSnapshot? {
        guard let episode = await fetchEpisode(byURL: episodeURL),
              episode.metaData?.calculatedIsAvailableLocally == true,
              let localFile = episode.localFile else { return nil }

        return TranscriptionEpisodeSnapshot(
            episodeURL: episodeURL,
            episodeTitle: episode.title,
            podcastTitle: episode.podcast?.title,
            audioDuration: episode.duration ?? 0,
            localFile: localFile,
            language: episode.podcast?.language
        )
    }

    // 2) Attach a TranscriptionItem to the Episode safely
    @MainActor
    func attachTranscriptionItem(_ item: TranscriptionItem, to episodeURL: URL) async {
        // Hop back into EpisodeActor isolation to fetch and mutate the model
        await self._attachTranscriptionItem(item, to: episodeURL)
    }

    // Private actor-isolated worker
    private func _attachTranscriptionItem(_ item: TranscriptionItem, to episodeURL: URL) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        episode.transcriptionItem = item
        modelContext.saveIfNeeded()
    }

    // 3) Decode VTT and persist transcript lines inside EpisodeActor
    func decodeAndSetTranscript(for episodeURL: URL, vtt: String) async {
        print("decoding vtt")
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        let lines = decodeTranscription(vtt) // existing helper returns [TranscriptLineAndTime]
        episode.transcriptLines = lines
        episode.refresh.toggle()
        modelContext.saveIfNeeded()
    }

    func saveTranscriptionRecord(
        for snapshot: TranscriptionEpisodeSnapshot,
        localeIdentifier: String,
        startedAt: Date,
        finishedAt: Date
    ) async {
        let record = TranscriptionRecord(
            episodeURL: snapshot.episodeURL,
            episodeTitle: snapshot.episodeTitle,
            podcastTitle: snapshot.podcastTitle,
            localeIdentifier: localeIdentifier,
            startedAt: startedAt,
            finishedAt: finishedAt,
            audioDuration: snapshot.audioDuration
        )
        modelContext.insert(record)
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

struct ChapterImageMaintenanceResult: Sendable {
    var optimizedImageCount: Int = 0
    var optimizedBytesSaved: Int64 = 0
    var restoredImageCount: Int = 0

    var hasChanges: Bool {
        optimizedImageCount > 0 || optimizedBytesSaved > 0 || restoredImageCount > 0
    }
}

struct TranscriptionEpisodeSnapshot: Sendable {
    let episodeURL: URL
    let episodeTitle: String
    let podcastTitle: String?
    let audioDuration: Double
    let localFile: URL
    let language: String?
}

private struct AudioFormatInfo: Sendable {
    let formatID: AudioFormatID
}

private struct SendableChapterSourceData: Sendable {
    let title: String
    let start: Double
    let type: MarkerType
    let imageURL: URL?
    let imageData: Data?
}

private struct ChapterExternalFileSnapshot: Sendable {
    let urlString: String
    let fileType: String?
}

private struct StoredChapterImageSnapshot: Sendable {
    let title: String
    let start: Double
    let type: MarkerType
    let imageURL: URL?
}

private struct EpisodeChapterSourceSnapshot: Sendable {
    let remoteURL: URL?
    let localFile: URL?
    let chapterFiles: [ChapterExternalFileSnapshot]
    let chapterImages: [StoredChapterImageSnapshot]
}

private enum ChapterImageStorageConfiguration {
    static let compactMaxPixelSize: CGFloat = 240
    static let jpegQuality: CGFloat = 0.62
    static let minimumCandidateBytes = 30 * 1024
    static let minimumRestoreByteGain = 4 * 1024
    static let minimumRestorePixelGain: CGFloat = 24
    static let mpeg4Extensions: Set<String> = ["m4a", "m4b", "mp4"]
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
