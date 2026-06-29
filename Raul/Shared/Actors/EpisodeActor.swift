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
#if canImport(UIKit)
import UIKit
#endif
import ImageIO
import Network


struct EpisodePlaybackStateSnapshot: Sendable {
    let playPosition: Double?
    let maxPlayPosition: Double?
}


@ModelActor
actor EpisodeActor {
    private static let legacyBackCatalogSuppressionMigrationKey = "EpisodeMetaData.backCatalogSuppressionMigration.v1"
    private static let legacyBackCatalogSuppressionArchiveWindow: TimeInterval = 24 * 60 * 60
    private var cachedEpisodeStateWriter: StoreSplitEpisodeStateSyncWriter?
    private var cachedEpisodeStateWriterStoreID: ObjectIdentifier?

    static func scheduleRemoteChapterFetch(episodeURL: URL, modelContainer: ModelContainer) {
        Task.detached(priority: .utility) {
            await EpisodeActor(modelContainer: modelContainer)
                .getRemoteChapters(episodeURL: episodeURL)
        }
    }

    private func logAutoDownload(_ message: String) async {
        await MainActor.run {
            BasicLogger.shared.log("[AutoDL] \(message)")
        }
    }

    private func episodeLogID(_ episode: Episode) -> String {
        if let episodeURL = episode.url?.absoluteString {
            return episodeURL
        }
        return episode.title
    }

    private func chapterIdentity(for chapter: Marker) -> String {
        let normalizedTitle = chapter.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedStart = Int(((chapter.start ?? 0) * 100).rounded())
        return "\(chapter.type.rawValue)|\(normalizedStart)|\(normalizedTitle)"
    }

    private func uniqueChapters(_ chapters: [Marker]) -> [Marker] {
        var seen = Set<String>()
        return chapters.filter { chapter in
            seen.insert(chapterIdentity(for: chapter)).inserted
        }
    }

    private func replaceChapters(
        on episode: Episode,
        replacingTypes types: Set<MarkerType>,
        with newChapters: [Marker]
    ) {
        if episode.chapters == nil {
            episode.chapters = []
        }

        let shouldPreserveChapterProgress = episode.hasPlaybackHistory

        var existingByIdentity: [String: Marker] = [:]
        for chapter in (episode.chapters ?? []) where types.contains(chapter.type) {
            let identity = chapterIdentity(for: chapter)
            if existingByIdentity[identity] == nil {
                existingByIdentity[identity] = chapter
            }
        }

        let replacementChapters = uniqueChapters(newChapters)
        for chapter in replacementChapters {
            chapter.episode = episode
            if let existing = existingByIdentity[chapterIdentity(for: chapter)] {
                chapter.shouldPlay = existing.shouldPlay
                chapter.progress = shouldPreserveChapterProgress ? existing.progress : 0
                chapter.image = chapter.image ?? existing.image
                chapter.imageData = chapter.imageData ?? existing.imageData
                chapter.link = chapter.link ?? existing.link
            }
        }

        episode.chapters?.removeAll { types.contains($0.type) }
        episode.chapters?.append(contentsOf: replacementChapters)
        episode.chapters?.sort { ($0.start ?? 0) < ($1.start ?? 0) }
    }

    @discardableResult
    private func removeDuplicateChapters(on episode: Episode) -> Bool {
        guard let chapters = episode.chapters, chapters.isEmpty == false else { return false }

        var seen = Set<String>()
        let originalCount = chapters.count
        episode.chapters = chapters.filter { chapter in
            seen.insert(chapterIdentity(for: chapter)).inserted
        }

        if episode.chapters?.count != originalCount {
            episode.chapters?.sort { ($0.start ?? 0) < ($1.start ?? 0) }
            return true
        }

        return false
    }

    private func shouldExtractShownotesChapters(for episode: Episode) -> Bool {
        guard let chapters = episode.chapters, chapters.isEmpty == false else { return true }
        guard chapters.allSatisfy({ $0.type == .extracted }) else { return false }

        let uniqueStartTimes = Set(chapters.compactMap(\.start))
        return uniqueStartTimes.count < 2
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

    
    @discardableResult
    func updateDuration(fileURL: URL) async -> Bool {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return false }
        print("updateDuration of \(episode.title)")

        guard let localFile = episode.localFile,
              FileManager.default.fileExists(atPath: localFile.path) else {
            print("no local file")
            return false
        }

        do {
            let duration = try await AVURLAsset(url: localFile).load(.duration)
            let seconds = CMTimeGetSeconds(duration)

            guard seconds.isFinite, seconds > 0 else {
                print("invalid local duration: \(seconds)")
                return false
            }

            if let existingDuration = episode.duration,
               abs(existingDuration - seconds) < 0.5 {
                return false
            }

            episode.duration = seconds
            episode.refresh.toggle()
            print("new duration: \(seconds)")
            modelContext.saveIfNeeded()
            return true
        } catch {
            print(error)
            return false
        }
    }
    
    @discardableResult
    func updateChapterDurations(fileURL: URL) async -> Bool {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return false }
        guard !(episode.chapters?.isEmpty ?? true) else { return false }
        guard let totalDuration = episode.duration else { return false }
        
        // print("updateChapterDurations")
        
        var didChange = false
        if let  chapters = episode.chapters{
            var lastEnd = totalDuration
            for chapter in chapters.sorted(by: {$0.start ?? 0.0 > $1.start ?? lastEnd}){
                if chapter.duration == nil{
                    chapter.duration = lastEnd - (chapter.start ?? 0.0)
                    lastEnd = chapter.start ?? 0.0
                    didChange = true
                }
            }
        }
        if didChange {
            episode.refresh.toggle()
            modelContext.saveIfNeeded()
        }
        return didChange
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
        ensureMetadata(for: episode)
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
        let predicate = #Predicate<EpisodeMetaData> { metadata in
            metadata.isHistory != true && metadata.lastPlayed != nil
        }
        do {
            let results = try modelContext.fetch(FetchDescriptor<EpisodeMetaData>(predicate: predicate))
            let mostRecentlyPlayed = results.max {
                ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast)
            }
            return mostRecentlyPlayed?.episode?.url
        } catch {
            // print("❌ Error fetching or saving metadata: \(error)")
        }
        return nil

    }
    
    func setLastPlayed(episodeURL: URL, to date: Date = Date()) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        ensureMetadata(for: episode)
        episode.metaData?.lastPlayed = date
        modelContext.saveIfNeeded()
        await publishSplitEpisodeState(episode)
    }
    
    func setPlayPosition(episodeURL: URL, position: TimeInterval, force: Bool = false) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        ensureMetadata(for: episode)
        let previousPosition = episode.metaData?.playPosition ?? 0.0
        if force || abs(previousPosition - position) >= 10 {
            if position > episode.metaData?.maxPlayposition ?? 0.0 {
                episode.metaData?.maxPlayposition = position
            }
            episode.metaData?.playPosition = position
            modelContext.saveIfNeeded()
            await publishSplitEpisodeState(episode)
        }

    }

    func applyCachedPlaybackProgress(
        episodeURL: URL,
        playPosition: Double,
        maxPlayPosition: Double,
        chapterProgresses: [String: Double],
        lastPlayed: Date? = nil
    ) async -> Bool {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return false }
        ensureMetadata(for: episode)

        let storedMaxPosition = episode.metaData?.maxPlayposition ?? 0.0
        episode.metaData?.playPosition = playPosition
        episode.metaData?.maxPlayposition = max(storedMaxPosition, maxPlayPosition, playPosition)
        let hasRecoveredPlaybackState = playPosition > 0
            || maxPlayPosition > 0
            || chapterProgresses.values.contains(where: { $0 > 0 })
        if let lastPlayed {
            episode.metaData?.lastPlayed = lastPlayed
        } else if hasRecoveredPlaybackState, episode.metaData?.lastPlayed == nil {
            episode.metaData?.lastPlayed = .now
        }
        if hasRecoveredPlaybackState, episode.metaData?.firstListenDate == nil {
            episode.metaData?.firstListenDate = episode.metaData?.lastPlayed ?? .now
        }

        for (chapterIDString, progress) in chapterProgresses {
            guard let chapterID = UUID(uuidString: chapterIDString) else { continue }
            if let chapter = episode.chapters?.first(where: { $0.uuid == chapterID }) {
                chapter.progress = progress
            }
        }

        guard modelContext.hasChanges else { return true }
        do {
            try modelContext.save()
            await publishSplitEpisodeState(episode)
            return true
        } catch {
            return false
        }
    }

    func playbackStateSnapshot(for episodeURL: URL) async -> EpisodePlaybackStateSnapshot? {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return nil }
        return EpisodePlaybackStateSnapshot(
            playPosition: episode.metaData?.playPosition,
            maxPlayPosition: episode.metaData?.maxPlayposition
        )
    }
    
    func markasPlayed(_ episodeURL: URL) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        ensureMetadata(for: episode)
        episode.metaData?.completionDate = Date()
        episode.metaData?.isHistory = true
        episode.metaData?.isInbox = false
        episode.metaData?.status = .history

        modelContext.saveIfNeeded()
        await publishSplitEpisodeState(episode)

        if let podcastFeed = episode.podcast?.feed {
            await applyAutomaticDownloadPolicy(for: podcastFeed, force: true)
        }
    }

    private func playlistActor(for playlistID: UUID?) -> PlaylistModelActor? {
        if let playlistID,
           let actor = try? PlaylistModelActor(modelContainer: modelContainer, playlistID: playlistID) {
            return actor
        }

        return try? PlaylistModelActor(modelContainer: modelContainer)
    }

    func removeFromPlaylist(_ episodeURL: URL) async {
        await logAutoDownload("trigger/remove-from-all-playlists episode=\(episodeURL.absoluteString)")
        if let playlistModelActor = try? PlaylistModelActor(modelContainer: modelContainer) {
            try? await playlistModelActor.removeFromAllPlaylists(episodeURL: episodeURL)
        } else {
            await logAutoDownload("trigger/remove-from-all-playlists failed-to-create-playlist-actor episode=\(episodeURL.absoluteString)")
        }
    }
    
    func archiveEpisode(_ episodeURL: URL?) async {
        guard let episodeURL else { return }
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard episodes.isEmpty == false else {
            print("could not find episode with URL \(episodeURL) to archive")
            return }
        let podcastFeeds = Set(episodes.compactMap { $0.podcast?.feed })
        await logAutoDownload("trigger/archive episode=\(episodeURL.absoluteString) matchedEpisodes=\(episodes.count) affectedFeeds=\(podcastFeeds.count)")
        
        await removeFromPlaylist(episodeURL)

        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.isArchived = true
            episode.metaData?.isInbox = false
            episode.metaData?.status = .archived
            episode.metaData?.archivedAt = Date()
            episode.metaData?.systemSuppressionReason = nil
        }

        modelContext.saveIfNeeded()
        for episode in episodes {
            await publishSplitEpisodeState(episode)
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
        }
        WatchSyncCoordinator.refreshSoon(force: true)

        for podcastFeed in podcastFeeds {
            await logAutoDownload("trigger/archive applying-policy feed=\(podcastFeed.absoluteString)")
            await applyAutomaticDownloadPolicy(for: podcastFeed, force: true)
        }
    }
    
    func unarchiveEpisode(_ episodeURL: URL?) async  {
        guard let episodeURL else { return }
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard episodes.isEmpty == false else { return }
        await logAutoDownload("trigger/unarchive episode=\(episodeURL.absoluteString) matchedEpisodes=\(episodes.count)")

        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.isArchived = false
            episode.metaData?.isInbox = true
            episode.metaData?.status = .inbox
            episode.metaData?.archivedAt = nil
            episode.metaData?.systemSuppressionReason = nil
        }
        modelContext.saveIfNeeded()
        for episode in episodes {
            await publishSplitEpisodeState(episode)
        }
        WatchSyncCoordinator.refreshSoon(force: true)
    }

    func suppressEpisodeFromInbox(
        _ episodeURL: URL?,
        reason: EpisodeSystemSuppressionReason
    ) async {
        guard let episodeURL else { return }
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard episodes.isEmpty == false else { return }

        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.isArchived = false
            episode.metaData?.isInbox = false
            episode.metaData?.status = nil
            episode.metaData?.archivedAt = nil
            episode.metaData?.systemSuppressionReason = reason
        }

        modelContext.saveIfNeeded()
        await MainActor.run {
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
        }
    }

    private func publishSplitEpisodeState(_ episode: Episode) async {
        guard let metadata = episode.metaData else { return }
        let snapshot = StoreSplitEpisodeStateSnapshot(
            identity: episode.stableEpisodeIdentity,
            playPosition: max(0, metadata.playPosition ?? 0),
            maxPlayPosition: max(
                0,
                metadata.maxPlayposition ?? 0,
                metadata.playPosition ?? 0
            ),
            duration: episode.duration,
            isPlayed: metadata.completionDate != nil || metadata.isHistory == true,
            isArchived: metadata.isArchived == true || metadata.status == .archived,
            wasSkipped: metadata.wasSkipped,
            completedAt: metadata.completionDate,
            archivedAt: metadata.archivedAt,
            firstPlayedAt: metadata.firstListenDate,
            lastPlayedAt: metadata.lastPlayed
        )
        guard let writer = await episodeStateWriter() else { return }
        await writer.upsert(snapshot)
    }

    private func episodeStateWriter() async -> StoreSplitEpisodeStateSyncWriter? {
        guard let userStateContainer = await preparedUserStateContainer() else {
            return nil
        }

        let storeID = ObjectIdentifier(userStateContainer)
        if let cachedEpisodeStateWriter,
           cachedEpisodeStateWriterStoreID == storeID {
            return cachedEpisodeStateWriter
        }

        let writer = StoreSplitEpisodeStateSyncWriter(
            modelContainer: userStateContainer
        )
        cachedEpisodeStateWriter = writer
        cachedEpisodeStateWriterStoreID = storeID
        return writer
    }

    func clearSystemSuppression(_ episodeURL: URL?) async {
        guard let episodeURL else { return }
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard episodes.isEmpty == false else { return }

        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.systemSuppressionReason = nil
        }

        modelContext.saveIfNeeded()
    }
    
    func moveToHistory(episodeURL: URL) async {
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard episodes.isEmpty == false else { return }
        let podcastFeeds = Set(episodes.compactMap { $0.podcast?.feed })
        await logAutoDownload("trigger/move-to-history episode=\(episodeURL.absoluteString) matchedEpisodes=\(episodes.count) affectedFeeds=\(podcastFeeds.count)")
        await removeFromPlaylist(episodeURL)

        for episode in episodes {
            ensureMetadata(for: episode)
            if episode.metaData?.lastPlayed == nil {
                episode.metaData?.lastPlayed = Date()
            }

            episode.metaData?.isArchived = false
            episode.metaData?.isHistory = true
            episode.metaData?.isInbox = false
            episode.metaData?.status = .history
            episode.metaData?.systemSuppressionReason = nil
        }
        
        modelContext.saveIfNeeded()
        for episode in episodes {
            await publishSplitEpisodeState(episode)
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
            WatchSyncCoordinator.refreshSoon(force: true)
        }

        for podcastFeed in podcastFeeds {
            await logAutoDownload("trigger/move-to-history applying-policy feed=\(podcastFeed.absoluteString)")
            await applyAutomaticDownloadPolicy(for: podcastFeed, force: true)
        }
    }

    func applyAutomaticDownloadPolicy(for podcastFeed: URL, force: Bool = false) async {
        let settingsActor = PodcastSettingsModelActor(modelContainer: modelContainer)
        let playedProgressThreshold = 0.99
        let throttle = AutoDownloadPolicyThrottle.shared

        switch await throttle.begin(feed: podcastFeed, force: force) {
        case .run:
            break
        case .skip(let reason):
            await logAutoDownload("policy/skip feed=\(podcastFeed.absoluteString) reason=\(reason)")
            return
        }
        defer {
            Task {
                await throttle.finish(feed: podcastFeed)
            }
        }

        await logAutoDownload("policy/start feed=\(podcastFeed.absoluteString) force=\(force)")

        guard let policy = await settingsActor.autoDownloadPolicy(for: podcastFeed) else {
            await logAutoDownload("policy/skip feed=\(podcastFeed.absoluteString) reason=no-policy")
            return
        }

        let keepCount = policy.keepCount
        let selection = policy.selection
        let queuePosition = policy.queuePosition
        let playlistID = policy.playlistID
        let networkMode = policy.networkMode
        let includesBackCatalogEpisodes = policy.includesArchivedEpisodes
        await logAutoDownload(
            "policy/config feed=\(podcastFeed.absoluteString) keep=\(keepCount) selection=\(selection.rawValue) queuePosition=\(queuePosition) playlistID=\(playlistID?.uuidString ?? "nil") network=\(networkMode.rawValue) includeBackCatalog=\(includesBackCatalogEpisodes)"
        )

        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.podcast?.feed == podcastFeed
            }
        )

        let podcastEpisodes: [Episode]
        do {
            podcastEpisodes = try modelContext.fetch(descriptor)
        } catch {
            await logAutoDownload("policy/error feed=\(podcastFeed.absoluteString) step=fetch-episodes error=\(error.localizedDescription)")
            return
        }

        guard podcastEpisodes.isEmpty == false else {
            await logAutoDownload("policy/skip feed=\(podcastFeed.absoluteString) reason=no-episodes")
            return
        }

        var skippedHistory = 0
        var skippedArchived = 0
        var skippedPlayed = 0
        var skippedMissingSideload = 0
        var skippedBackCatalogToggle = 0
        var sampledDecisions: [String] = []
        let maxSampledDecisions = 25

        let eligibleEpisodes = podcastEpisodes.filter { episode in
            let isHistory = episode.metaData?.isHistory == true
            let isUserArchived = episode.metaData?.isArchived == true
            let hasCompletionDate = episode.metaData?.completionDate != nil
            let isPlayed = hasCompletionDate || episode.maxPlayProgress >= playedProgressThreshold
            let suppressionReason = episode.metaData?.systemSuppressionReason

            if isHistory {
                skippedHistory += 1
                if sampledDecisions.count < maxSampledDecisions {
                    sampledDecisions.append("\(episodeLogID(episode)) => skipped:history")
                }
                return false
            }

            if isUserArchived {
                skippedArchived += 1
                if sampledDecisions.count < maxSampledDecisions {
                    sampledDecisions.append("\(episodeLogID(episode)) => skipped:userArchived")
                }
                return false
            }

            // Auto-download selection is explicitly based on unplayed episodes.
            if isPlayed {
                skippedPlayed += 1
                if sampledDecisions.count < maxSampledDecisions {
                    sampledDecisions.append("\(episodeLogID(episode)) => skipped:played")
                }
                return false
            }

            if suppressionReason == .missingSideload {
                skippedMissingSideload += 1
                if sampledDecisions.count < maxSampledDecisions {
                    sampledDecisions.append("\(episodeLogID(episode)) => skipped:missingSideload")
                }
                return false
            }

            if suppressionReason == .backCatalogImport && includesBackCatalogEpisodes == false {
                skippedBackCatalogToggle += 1
                if sampledDecisions.count < maxSampledDecisions {
                    sampledDecisions.append("\(episodeLogID(episode)) => skipped:backCatalogToggleOff")
                }
                return false
            }

            if sampledDecisions.count < maxSampledDecisions {
                sampledDecisions.append("\(episodeLogID(episode)) => eligible")
            }
            return true
        }

        await logAutoDownload(
            "policy/eligibility feed=\(podcastFeed.absoluteString) total=\(podcastEpisodes.count) eligible=\(eligibleEpisodes.count) skippedHistory=\(skippedHistory) skippedArchived=\(skippedArchived) skippedPlayed=\(skippedPlayed) skippedMissingSideload=\(skippedMissingSideload) skippedBackCatalogToggle=\(skippedBackCatalogToggle) sampleCount=\(sampledDecisions.count)"
        )
        if sampledDecisions.isEmpty == false {
            await logAutoDownload("policy/eligibility-sample feed=\(podcastFeed.absoluteString) \(sampledDecisions.joined(separator: " | "))")
        }

        guard eligibleEpisodes.isEmpty == false else {
            await logAutoDownload("policy/stop feed=\(podcastFeed.absoluteString) reason=no-eligible-episodes")
            return
        }

        let sortedEpisodes = eligibleEpisodes.sorted { lhs, rhs in
            let lhsDate: Date
            let rhsDate: Date

            switch selection {
            case .newestUnplayed:
                lhsDate = lhs.publishDate ?? .distantPast
                rhsDate = rhs.publishDate ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
            case .oldestUnplayed:
                lhsDate = lhs.publishDate ?? .distantFuture
                rhsDate = rhs.publishDate ?? .distantFuture
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
            }

            let lhsKey = lhs.url?.absoluteString ?? lhs.title
            let rhsKey = rhs.url?.absoluteString ?? rhs.title
            return lhsKey.localizedStandardCompare(rhsKey) == .orderedAscending
        }

        let targetEpisodes = Array(sortedEpisodes.prefix(keepCount))
        let overflowEpisodes = Array(sortedEpisodes.dropFirst(keepCount))
        let targetEpisodeURLs = Set(targetEpisodes.compactMap(\.url))
        let playlistActor = playlistActor(for: playlistID)
        let canScheduleDownloads = await canScheduleAutoDownloads(for: networkMode)
        await logAutoDownload(
            "policy/target feed=\(podcastFeed.absoluteString) targetCount=\(targetEpisodes.count) queuePosition=\(queuePosition) playlistActorAvailable=\(playlistActor != nil) canScheduleDownloads=\(canScheduleDownloads)"
        )
        if targetEpisodes.isEmpty == false {
            let targetIDs = targetEpisodes.map(episodeLogID).joined(separator: ", ")
            await logAutoDownload("policy/target-episodes feed=\(podcastFeed.absoluteString) \(targetIDs)")
        }

        for episode in targetEpisodes {
            guard let episodeURL = episode.url else { continue }
            let isDownloaded = episode.metaData?.calculatedIsAvailableLocally == true

            if queuePosition != .none {
                let isUserArchived = episode.metaData?.isArchived == true
                let hasCompletionDate = episode.metaData?.completionDate != nil
                let isPlayed = hasCompletionDate || episode.maxPlayProgress >= playedProgressThreshold
                var isQueued = false
                if let playlistActor {
                    do {
                        isQueued = try await playlistActor.containsEpisodeURL(episodeURL)
                    } catch {
                        await logAutoDownload("policy/error feed=\(podcastFeed.absoluteString) step=contains-in-playlist episode=\(episodeURL.absoluteString) error=\(error.localizedDescription)")
                    }
                } else {
                    await logAutoDownload("policy/queue-skip feed=\(podcastFeed.absoluteString) episode=\(episodeURL.absoluteString) reason=no-playlist-actor")
                }
                if isQueued == false && isUserArchived == false && isPlayed == false {
                    if let playlistActor {
                        do {
                            try await playlistActor.add(
                                episodeURL: episodeURL,
                                to: queuePosition,
                                startDownload: false
                            )
                            await logAutoDownload("policy/queue-add feed=\(podcastFeed.absoluteString) episode=\(episodeURL.absoluteString) result=success")
                        } catch {
                            await logAutoDownload("policy/queue-add feed=\(podcastFeed.absoluteString) episode=\(episodeURL.absoluteString) result=failure error=\(error.localizedDescription)")
                        }
                    } else {
                        await logAutoDownload("policy/queue-add feed=\(podcastFeed.absoluteString) episode=\(episodeURL.absoluteString) result=skipped-no-playlist-actor")
                    }
                } else {
                    await logAutoDownload(
                        "policy/queue-skip feed=\(podcastFeed.absoluteString) episode=\(episodeURL.absoluteString) reason=\(isQueued ? "already-queued" : (isUserArchived ? "user-archived" : "played"))"
                    )
                }
            } else {
                await logAutoDownload("policy/queue-skip feed=\(podcastFeed.absoluteString) episode=\(episodeURL.absoluteString) reason=queue-position-none")
            }

            if canScheduleDownloads && isDownloaded == false {
                await logAutoDownload("policy/download feed=\(podcastFeed.absoluteString) episode=\(episodeURL.absoluteString) action=start")
                await download(episodeURL: episodeURL)
            } else if canScheduleDownloads == false && isDownloaded == false {
                await logAutoDownload("policy/download feed=\(podcastFeed.absoluteString) episode=\(episodeURL.absoluteString) action=defer-network-gate")
            }
        }

        var removedFromPlaylist = 0
        if overflowEpisodes.isEmpty == false {
            if queuePosition == .none {
                await logAutoDownload("policy/prune-skip feed=\(podcastFeed.absoluteString) reason=queue-position-none overflowCount=\(overflowEpisodes.count)")
            } else if let playlistActor {
                let queuedEpisodeURLs: Set<URL>
                do {
                    queuedEpisodeURLs = Set(try await playlistActor.orderedEpisodeURLs())
                } catch {
                    await logAutoDownload("policy/error feed=\(podcastFeed.absoluteString) step=fetch-playlist-urls error=\(error.localizedDescription)")
                    queuedEpisodeURLs = []
                }

                for episode in overflowEpisodes {
                    guard let episodeURL = episode.url else { continue }
                    guard queuedEpisodeURLs.contains(episodeURL) else { continue }

                    do {
                        try await playlistActor.remove(
                            episodeURL: episodeURL,
                            triggerAutoDownload: false
                        )
                        removedFromPlaylist += 1
                        await logAutoDownload("policy/prune-remove feed=\(podcastFeed.absoluteString) episode=\(episodeURL.absoluteString)")
                    } catch {
                        await logAutoDownload("policy/prune-remove feed=\(podcastFeed.absoluteString) episode=\(episodeURL.absoluteString) result=failure error=\(error.localizedDescription)")
                    }
                }
            } else {
                await logAutoDownload("policy/prune-skip feed=\(podcastFeed.absoluteString) reason=no-playlist-actor overflowCount=\(overflowEpisodes.count)")
            }
        }
        await logAutoDownload("policy/prune-summary feed=\(podcastFeed.absoluteString) overflowCount=\(overflowEpisodes.count) removedFromPlaylist=\(removedFromPlaylist)")

        let hasTargetCoverage = targetEpisodes.allSatisfy { episode in
            episode.metaData?.calculatedIsAvailableLocally == true
        }

        if hasTargetCoverage == false {
            await logAutoDownload("policy/cleanup-skip feed=\(podcastFeed.absoluteString) reason=targets-not-downloaded")
            return
        }

        var deletedDownloads = 0
        for episode in podcastEpisodes {
            guard let episodeURL = episode.url else { continue }
            guard targetEpisodeURLs.contains(episodeURL) == false else { continue }
            guard episode.metaData?.calculatedIsAvailableLocally == true else { continue }
            guard (episode.playlist?.isEmpty ?? true) else { continue }

            await deleteFile(episodeURL: episodeURL)
            deletedDownloads += 1
            await logAutoDownload("policy/cleanup-delete feed=\(podcastFeed.absoluteString) episode=\(episodeURL.absoluteString)")
        }
        await logAutoDownload("policy/done feed=\(podcastFeed.absoluteString) deletedDownloads=\(deletedDownloads)")
    }

    func migrateLegacyBackCatalogSuppressionIfNeeded() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.legacyBackCatalogSuppressionMigrationKey) == false else {
            return
        }

        let descriptor = FetchDescriptor<Episode>()
        guard let episodes = try? modelContext.fetch(descriptor),
              episodes.isEmpty == false else {
            defaults.set(true, forKey: Self.legacyBackCatalogSuppressionMigrationKey)
            return
        }

        var didChange = false

        for episode in episodes {
            guard let metadata = episode.metaData,
                  metadata.isArchived == true else {
                continue
            }
            guard metadata.isHistory != true else { continue }
            guard metadata.completionDate == nil else { continue }
            guard metadata.lastPlayed == nil else { continue }
            guard episode.maxPlayProgress <= 0.01 else { continue }
            guard let publishDate = episode.publishDate,
                  let subscriptionDate = episode.podcast?.metaData?.subscriptionDate else {
                continue
            }
            guard publishDate < subscriptionDate else { continue }
            guard let archivedAt = metadata.archivedAt else { continue }

            let interval = abs(archivedAt.timeIntervalSince(subscriptionDate))
            guard interval <= Self.legacyBackCatalogSuppressionArchiveWindow else { continue }

            metadata.isArchived = false
            metadata.isInbox = false
            metadata.status = nil
            metadata.archivedAt = nil
            metadata.systemSuppressionReason = .backCatalogImport
            didChange = true
        }

        if didChange {
            modelContext.saveIfNeeded()
            await MainActor.run {
                NotificationCenter.default.post(name: .inboxDidChange, object: nil)
            }
        }

        defaults.set(true, forKey: Self.legacyBackCatalogSuppressionMigrationKey)
    }

    private func canScheduleAutoDownloads(for networkMode: AutoDownloadNetworkMode) async -> Bool {
        switch networkMode {
        case .wifiAndCellular:
            return true
        case .wifiOnly:
            return await isOnWiFi()
        }
    }

    private func isOnWiFi() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "AutoDownloadNetworkMonitor")

            monitor.pathUpdateHandler = { path in
                let isConnected = path.status == .satisfied
                let isWiFiLikeConnection = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                monitor.cancel()
                continuation.resume(returning: isConnected && isWiFiLikeConnection)
            }

            monitor.start(queue: queue)
        }
    }
    
    
    func download(episodeURL: URL) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else {
            return }
        guard episode.source != .sideLoaded else { return }

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
        
        let settingsActor = PodcastSettingsModelActor(modelContainer: modelContainer)
        let playnext = await settingsActor.getPlaynextposition(for: episode.podcast?.feed)
        let playlistID = await settingsActor.getDefaultPlaylistID(for: episode.podcast?.feed)
        print("Processing episode: \(episode.title) - playnext Status is \(playnext)")

        if playnext != .none {
            let playlistActor = playlistActor(for: playlistID)
            try? await playlistActor?.add(episodeURL: episodeURL, to: playnext)
        }

        await NotificationManager().sendNotification(title: episode.displayPodcastTitle ?? "New Episode", body: episode.title)
        Self.scheduleRemoteChapterFetch(episodeURL: episodeURL, modelContainer: modelContainer)
    }
    
    func getRemoteChapters(episodeURL: URL) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else {
            return }
        guard let url = episode.url else { return }

        // Remote episodes do not pass through markEpisodeAvailable(), so run the
        // regular chapter creation flow here before attempting MP3-only remote
        // extraction. This keeps shownotes/external JSON chapters available for
        // streamed episodes published without embedded chapter metadata.
        _ = await createChapters(url)
        await extractRemoteMP3Chapters(url)
        await applyAutoSkipWords(episodeURL: episodeURL)
    }
    
    func createBookmark(for episodeURL: URL, at playPosition: Double) async{
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }

        let bookmarkTitle = episode.transcriptLines?.sorted(by: { $0.startTime < $1.startTime }).last(where: { $0.startTime < playPosition })?.text ?? episode.title
        let bookmark = Bookmark(start: playPosition, title: bookmarkTitle, type: .bookmark)
        episode.bookmarks?.append(bookmark)
        modelContext.saveIfNeeded()
        guard let bookmarkID = bookmark.uuid?.uuidString else { return }
        let snapshot = StoreSplitBookmarkSnapshot(
            id: bookmarkID,
            identity: episode.stableEpisodeIdentity,
            time: playPosition,
            title: bookmarkTitle,
            createdAt: bookmark.creationtime ?? .now
        )
        if let userStateContainer = await preparedUserStateContainer() {
            await StoreSplitBookmarkSyncWriter(modelContainer: userStateContainer)
                .upsert(snapshot)
        }
    }
    
    func deleteFile(episodeURL: URL?) async{
        guard let episodeURL else { return }
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard let firstEpisode = episodes.first else { return }
        guard firstEpisode.source != .sideLoaded else { return }

        if let file = firstEpisode.localFile{
            try? FileManager.default.removeItem(at: file)
        }

        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.isAvailableLocally = false
            episode.refresh.toggle()
        }
        
        modelContext.saveIfNeeded()
        WatchSyncCoordinator.refreshSoon(force: true)
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
        ensureMetadata(for: episode)
        let wasAvailableLocally = episode.metaData?.isAvailableLocally == true
            && episode.metaData?.calculatedIsAvailableLocally == true

        if wasAvailableLocally == false {
            episode.metaData?.isAvailableLocally = true
            episode.refresh.toggle()
            modelContext.saveIfNeeded()
            WatchSyncCoordinator.refreshSoon(force: true)
        }

        await updateDuration(fileURL: url)
        await createChapters(url)

        if wasAvailableLocally {
            return
        }

        let settingsActor = PodcastSettingsModelActor(modelContainer: modelContainer)
        let transcriptionsEnabled = await settingsActor.getTranscriptionsEnabled()
        let automaticOnDeviceTranscriptionsEnabled = await settingsActor
            .getAutomaticOnDeviceTranscriptionsEnabled()
        let automaticOnDeviceTranscriptionsRequireCharging = await settingsActor
            .getAutomaticOnDeviceTranscriptionsRequiresCharging()
        let isConnectedToPower = automaticOnDeviceTranscriptionsRequireCharging
            ? await isDeviceConnectedToPower()
            : true
        let allowAutomaticOnDeviceFallback = automaticOnDeviceTranscriptionsEnabled
            && isConnectedToPower
        if transcriptionsEnabled {
            try? await transcribe(
                url,
                allowOnDeviceFallback: allowAutomaticOnDeviceFallback,
                origin: .automatic
            )
        }
        modelContext.saveIfNeeded()
        WatchSyncCoordinator.refreshSoon(force: true)
    }
    
    // NEW: Delegate to TranscriptionManager
    func transcribe(
        _ fileURL: URL,
        allowOnDeviceFallback: Bool = true,
        origin: TranscriptionStartOrigin = .manual
    ) async throws {
        print("transcribe")
        guard let episode = await fetchEpisode(byURL: fileURL) else { return }
        guard let episodeURL = episode.url else { return }
        let settingsActor = PodcastSettingsModelActor(modelContainer: modelContainer)
        guard await settingsActor.getTranscriptionsEnabled() else { return }

        if episode.hasLoadedTranscript {
            await finalizeTranscriptChapters(for: episodeURL)
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
        _ = await transcriptionManager.enqueueTranscription(
            episodeURL: episodeURL,
            origin: origin
        )
    }

    private func isDeviceConnectedToPower() async -> Bool {
#if canImport(UIKit)
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
#else
        true
#endif
    }

    func isReadyForAutomaticTranscription(episodeURL: URL) async -> Bool {
        let settingsActor = PodcastSettingsModelActor(modelContainer: modelContainer)
        guard await settingsActor.getTranscriptionsEnabled() else { return false }
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return false }
        guard episode.url != nil else { return false }
        guard episode.hasLoadedTranscript == false else { return false }
        return episode.metaData?.calculatedIsAvailableLocally == true
    }
    
    func decodeTranscription(_ transcription: String) -> [TranscriptLineAndTime] {
        print("decodeTranscription")
        let decoder = TranscriptDecoder(transcription)
        let lines = decoder.transcriptLines
        let transcript = lines.enumerated().map { _, line in
            let text = line.text
            let start = line.startTime
            let end = line.endTime
            let speaker = line.speaker
            return TranscriptLineAndTime(speaker: speaker, text: text, startTime: start, endTime: end)
        }.sorted {
            if $0.startTime != $1.startTime {
                return $0.startTime < $1.startTime
            }
            let leftEnd = $0.endTime ?? .greatestFiniteMagnitude
            let rightEnd = $1.endTime ?? .greatestFiniteMagnitude
            return leftEnd < rightEnd
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

    @discardableResult
    func createChapters(_ fileURL: URL) async -> Bool {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return false }
        var didChange = false
        
        if episode.chapters == nil {
            episode.chapters = []
        }
        let removedDuplicateChapters = removeDuplicateChapters(on: episode)
        didChange = didChange || removedDuplicateChapters

        let refreshedLocalChapters = await refreshLocalFileChapters(for: episode)
        didChange = didChange || refreshedLocalChapters

        if let chapters = episode.chapters, chapters.isEmpty,
           let chapterFile = episode.externalFiles.first(where: { $0.category == .chapter }),
           let url = URL(string: chapterFile.url) {
            let isJSON = (url.pathExtension.lowercased() == "json")
                || (chapterFile.fileType?.lowercased().contains("json") == true)
            if isJSON,
               let jsonString = await downloadAndParseStringFile(url: url),
               let jsonData = jsonString.data(using: .utf8),
               let chapters = await parseJSONChapters(jsonData: jsonData) {
                replaceChapters(on: episode, replacingTypes: [.extracted], with: chapters)
                modelContext.saveIfNeeded()
                didChange = true
            }
        }

        if shouldExtractShownotesChapters(for: episode), let url = episode.url {
            let extractedShownotesChapters = await extractShownotesChapters(fileURL: url)
            didChange = didChange || extractedShownotesChapters
        }
        if let url = episode.url {
            let finalizedTranscriptChapters = await finalizeTranscriptChapters(for: url)
            didChange = didChange || finalizedTranscriptChapters
        }
        if removedDuplicateChapters {
            modelContext.saveIfNeeded()
        }
        return didChange
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
    
    @discardableResult
    func rerunChapterSkipRules(for episodeURL: URL) async -> Bool {
        return await applyAutoSkipWords(episodeURL: episodeURL)
    }

    @discardableResult
    private func applyAutoSkipWords(episodeURL: URL) async -> Bool {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return false }
        let actor = PodcastSettingsModelActor(modelContainer: modelContainer)
        guard let skipWord = await actor.getChapterSkipKeywords(for: episode.podcast?.feed) else {
            return false
        }
        var didChange = false
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
                        didChange = didChange || chapter.shouldPlay
                        chapter.shouldPlay = false
                    }
                }
            }
        }
        if didChange {
            episode.refresh.toggle()
            modelContext.saveIfNeeded()
        }
        return didChange
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
    
    @discardableResult
    private func extractMP3Chapters(_ episodeID: PersistentIdentifier) async -> Bool {
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return false }
        guard let url = episode.localFile else {
            return false
        }
        let chapters = await ChapterExtractionHooks.loadLocalMP3Chapters(url)
        guard chapters.isEmpty == false else { return false }

        replaceChapters(on: episode, replacingTypes: [.mp3], with: chapters)
        episode.refresh.toggle()
        modelContext.saveIfNeeded()
        return true
    }
    
    @discardableResult
    func extractRemoteMP3Chapters(_ fileURL: URL) async -> Bool {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return false }
        guard let remoteURL = episode.url else { return false }

        let chapters = await ChapterExtractionHooks.loadRemoteMP3Chapters(remoteURL)
        guard chapters.isEmpty == false else { return false }

        replaceChapters(on: episode, replacingTypes: [.mp3], with: chapters)
        episode.refresh.toggle()
        modelContext.saveIfNeeded()
        await MainActor.run {
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
        }
        WatchSyncCoordinator.refreshSoon(force: true)
        return true
    }

    @discardableResult
    func rerunLocalAudioChapters(for episodeURL: URL) async -> Bool {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return false }
        return await refreshLocalFileChapters(for: episode)
    }

    @discardableResult
    private func refreshLocalFileChapters(for episode: Episode) async -> Bool {
        guard let localFile = episode.localFile else { return false }
        guard FileManager.default.fileExists(atPath: localFile.path) else { return false }

        let lowercasedExtension = localFile.pathExtension.lowercased()
        if lowercasedExtension == "mp3" {
            return await extractMP3Chapters(episode.persistentModelID)
        }

        if ChapterImageStorageConfiguration.mpeg4Extensions.contains(lowercasedExtension) {
            return await extractM4AChapters(episode.persistentModelID)
        }

        do {
            if let formatInfo = try await MetadataLoader.getAudioFormat(from: localFile) {
                if formatInfo.formatID == kAudioFormatMPEGLayer3 {
                    return await extractMP3Chapters(episode.persistentModelID)
                } else if formatInfo.formatID == kAudioFormatMPEG4AAC {
                    return await extractM4AChapters(episode.persistentModelID)
                }
            }
        } catch {
            return false
        }
        return false
    }
    
    private func parse(chapters: [String: Any]) -> [Marker]? {
        parseMP3Chapters(from: chapters)
    }

    private func chapterTitle(from chapterData: [String: Any], elementID: String) -> String {
        UpNext.chapterTitle(from: chapterData, fallback: elementID)
    }

    private func firstNonEmptyString(from value: Any?) -> String? {
        UpNext.firstNonEmptyString(in: value)
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
    
    @discardableResult
    private func extractM4AChapters(_ episodeID: PersistentIdentifier) async -> Bool {
        guard let episode = modelContext.model(for: episodeID) as? Episode else { return false }
        guard let url = episode.localFile else {
            return false
        }
        let chapters = await ChapterExtractionHooks.loadM4AChapters(url)
        guard chapters.isEmpty == false else { return false }

        replaceChapters(on: episode, replacingTypes: [.mp4], with: chapters)
        episode.refresh.toggle()
        modelContext.saveIfNeeded()
        return true
    }
    
    @discardableResult
    func extractTranscriptChapters(fileURL: URL, force: Bool = false) async -> Bool {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return false }
        guard force || shouldGenerateTranscriptChapters(for: episode) else { return false }
        guard let transcriptLines = episode.transcriptLines, transcriptLines != [] else {
            return false
        }
        
        let extractedData = await generateAIChapters(from: transcriptLines)
        guard !extractedData.isEmpty else { return false }

        var newchapters:[Marker] = []
        for extractedChapter in extractedData.sorted(by: { ($0.key.durationAsSeconds ?? 0) < ($1.key.durationAsSeconds ?? 0) }) {
            if let startingTime =  extractedChapter.key.durationAsSeconds{
                let title = extractedChapter.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard title.isEmpty == false else { continue }
                let newChapter = Marker(start: startingTime, title: title, type: .ai)
                newchapters.append(newChapter)
            }
        }
        guard newchapters.isEmpty == false else { return false }

        if episode.chapters == nil {
            episode.chapters = []
        }
        replaceChapters(on: episode, replacingTypes: [.extracted, .ai], with: newchapters)
        episode.refresh.toggle()
        modelContext.saveIfNeeded()
        await writeAIChaptersToSplitStore(
            episode: episode,
            chapters: newchapters,
            generatedAt: .now
        )
        return true
        
    }
    
    @discardableResult
    func rerunExternalJSONChapters(for episodeURL: URL) async -> Bool {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return false }
        var didChange = false

        for chapterFile in episode.externalFiles where chapterFile.category == .chapter {
            guard let url = URL(string: chapterFile.url) else { continue }
            let isJSON = (url.pathExtension.lowercased() == "json")
                || (chapterFile.fileType?.lowercased().contains("json") == true)
            guard isJSON,
                  let jsonString = await downloadAndParseStringFile(url: url),
                  let jsonData = jsonString.data(using: .utf8),
                  let chapters = await parseJSONChapters(jsonData: jsonData),
                  chapters.isEmpty == false else {
                continue
            }

            replaceChapters(on: episode, replacingTypes: [.extracted], with: chapters)
            didChange = true
        }

        if didChange {
            episode.refresh.toggle()
            modelContext.saveIfNeeded()
        }
        return didChange
    }

    @discardableResult
    func extractShownotesChapters(fileURL: URL) async -> Bool {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return false }
        let shownotesCandidates = [episode.content, episode.desc]
        guard let text = shownotesCandidates.compactMap({ $0 }).first(where: { $0.isEmpty == false }) else {
            return false
        }
        var extractedData = ShownotesChapterExtractor.extractTimeCodesAndTitles(
            fromShownotesCandidates: shownotesCandidates
        )
        
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
            guard Set(newchapters.compactMap(\.start)).count >= 2 else { return false }
            replaceChapters(on: episode, replacingTypes: [.extracted], with: newchapters)
            episode.refresh.toggle()
            modelContext.saveIfNeeded()
            return true
        }
        return false
    }
    
    func extractTimeCodesAndTitles(from htmlEncodedText: String) -> [String: String]? {
        ShownotesChapterExtractor.extractTimeCodesAndTitles(from: htmlEncodedText)
    }
    
    func generateAIChapters(from htmlEncodedText: String) async -> [String: String] {
        let chapterGenerator = AIChapterGenerator()
        let aiChapters = await chapterGenerator.extractChaptersFromText(htmlEncodedText)
        return aiChapters
    }
    
    func generateAIChapters(from transcript: [TranscriptLineAndTime]) async -> [String: String] {
        let chapterGenerator = AIChapterGenerator()
        let orderedTranscript = transcript.enumerated().sorted { left, right in
            if left.element.startTime != right.element.startTime {
                return left.element.startTime < right.element.startTime
            }
            return left.offset < right.offset
        }.map(\.element)

        let snapshots = orderedTranscript.map {
            TranscriptLineSnapshot(
                speaker: $0.speaker,
                text: $0.text,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
        let aiChapters = await chapterGenerator.createChaptersFromTranscriptLines(snapshots)
        return aiChapters
    }
    
    private func shouldGenerateTranscriptChapters(for episode: Episode) -> Bool {
        guard episode.transcriptLines?.isEmpty == false else { return false }

        let chapters = episode.chapters ?? []
        guard chapters.isEmpty == false else { return true }
        return chapters.allSatisfy { $0.type == .extracted }
    }

    @discardableResult
    private func finalizeTranscriptChapters(for episodeURL: URL, force: Bool = false) async -> Bool {
        let didGenerate = await extractTranscriptChapters(fileURL: episodeURL, force: force)
        await updateChapterDurations(episodeURL: episodeURL)
        await applyAutoSkipWords(episodeURL: episodeURL)
        return didGenerate
    }

    @discardableResult
    func regenerateTranscriptChapters(for episodeURL: URL) async -> Bool {
        return await finalizeTranscriptChapters(for: episodeURL, force: true)
    }
    
    @discardableResult
    func updateChapterDurations(episodeURL: URL) async -> Bool {
        guard let episode = await fetchEpisode(byURL: episodeURL) else {
            return false
        }
        var chapters = episode.preferredChapters
        chapters.sort { ($0.start ?? 0.0) < ($1.start ?? 0.0) }
        var didChange = false
        for i in 0..<chapters.count {
            guard let start = chapters[i].start else { continue }
            let end: Double
            if i + 1 < chapters.count, let nextStart = chapters[i + 1].start {
                end = nextStart
            } else {
                end = episode.duration ?? start
            }
            let duration = end - start
            if chapters[i].duration != duration {
                chapters[i].duration = duration
                didChange = true
            }
        }
        if didChange {
            episode.refresh.toggle()
            modelContext.saveIfNeeded()
        }
        return didChange
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
    
    
    enum TranscriptError: LocalizedError {
        case transcriptionExists
        case noTranscriptFileFound
        case episodeNotFound
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .transcriptionExists:
                return "This episode already has transcript lines."
            case .noTranscriptFileFound:
                return "No supported transcript file was found for this episode."
            case .episodeNotFound:
                return "The episode could not be found."
            case .decodingFailed:
                return "The transcript file could not be downloaded or decoded."
            }
        }
    }
    
    func downloadTranscript(_ episodeID: PersistentIdentifier) async throws {
        print("downloading transcript")
        guard let episode = modelContext.model(for: episodeID) as? Episode else {
            throw TranscriptError.episodeNotFound }
        let settingsActor = PodcastSettingsModelActor(modelContainer: modelContainer)
        guard await settingsActor.getTranscriptionsEnabled() else {
            throw TranscriptError.noTranscriptFileFound
        }
        
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
                    if let episodeURL = episode.url {
                        await finalizeTranscriptChapters(for: episodeURL)
                    }
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
        await finalizeTranscriptChapters(for: episodeURL)
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
            podcastTitle: episode.displayPodcastTitle,
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
        await finalizeTranscriptChapters(for: episodeURL)
    }

    func transcriptLineCount() async -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<TranscriptLineAndTime>())) ?? 0
    }

    @discardableResult
    func deleteAllTranscriptLines() async -> Int {
        let lines = (try? modelContext.fetch(FetchDescriptor<TranscriptLineAndTime>())) ?? []
        guard lines.isEmpty == false else { return 0 }

        let episodes = (try? modelContext.fetch(FetchDescriptor<Episode>())) ?? []
        let generatedEpisodeURLs = Set(
            ((try? modelContext.fetch(FetchDescriptor<TranscriptionRecord>())) ?? [])
                .compactMap(\.episodeURL)
        )
        let generatedIdentities = episodes.compactMap { episode -> EpisodeStableIdentity? in
            guard let episodeURL = episode.url,
                  generatedEpisodeURLs.contains(episodeURL),
                  episode.transcriptLines?.isEmpty == false else {
                return nil
            }
            return episode.stableEpisodeIdentity
        }
        for episode in episodes where episode.transcriptLines?.isEmpty == false {
            episode.transcriptLines = nil
            episode.refresh.toggle()
        }

        for line in lines {
            modelContext.delete(line)
        }

        modelContext.saveIfNeeded()
        if generatedIdentities.isEmpty == false,
           let userStateContainer = await preparedUserStateContainer() {
            let writer = StoreSplitAIContentSyncWriter(
                modelContainer: userStateContainer
            )
            await writer.tombstoneTranscripts(identities: generatedIdentities)
        }
        WatchSyncCoordinator.refreshSoon()
        return lines.count
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
        guard let episode = await fetchEpisode(byURL: snapshot.episodeURL),
              let transcriptLines = episode.transcriptLines else {
            return
        }
        await writeAITranscriptToSplitStore(
            episode: episode,
            lines: transcriptLines,
            localeIdentifier: localeIdentifier,
            generatedAt: finishedAt
        )
    }

    private func writeAITranscriptToSplitStore(
        episode: Episode,
        lines: [TranscriptLineAndTime],
        localeIdentifier: String?,
        generatedAt: Date
    ) async {
        let identity = episode.stableEpisodeIdentity
        let values = lines.map {
            AITranscriptLineValue(
                speaker: $0.speaker,
                text: $0.text,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
        guard values.isEmpty == false else { return }
        guard let userStateContainer = await preparedUserStateContainer() else { return }
        let writer = StoreSplitAIContentSyncWriter(modelContainer: userStateContainer)
        await writer.writeTranscript(
            identity: identity,
            lines: values,
            localeIdentifier: localeIdentifier,
            generatedAt: generatedAt
        )
    }

    private func writeAIChaptersToSplitStore(
        episode: Episode,
        chapters: [Marker],
        generatedAt: Date
    ) async {
        let values = chapters.compactMap { chapter -> AIChapterValue? in
            guard chapter.type == .ai, let start = chapter.start else { return nil }
            return AIChapterValue(
                title: chapter.title,
                startTime: start,
                duration: chapter.duration
            )
        }
        guard values.isEmpty == false else { return }
        guard let userStateContainer = await preparedUserStateContainer() else { return }
        let writer = StoreSplitAIContentSyncWriter(modelContainer: userStateContainer)
        await writer.writeChapters(
            identity: episode.stableEpisodeIdentity,
            chapters: values,
            generatedAt: generatedAt
        )
    }

    private func preparedUserStateContainer() async -> ModelContainer? {
        await ModelContainerManager.shared.prepareSplitStores()
        return await MainActor.run {
            ModelContainerManager.shared.preparedUserStateContainer
        }
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

fileprivate func parseMP3Chapters(from chapters: [String: Any]) -> [Marker]? {
    guard let chaptersDict = chapters["Chapters"] as? [String: Any] else {
        return nil
    }

    let parsedChapters = chaptersDict.compactMap { elementID, value -> Marker? in
        guard let chapterData = value as? [String: Any] else {
            return nil
        }

        let chapter = Marker()
        chapter.title = chapterTitle(from: chapterData, fallback: elementID)
        chapter.start = chapterData["startTime"] as? Double ?? 0
        chapter.duration = (chapterData["endTime"] as? Double ?? 0) - (chapter.start ?? 0)
        chapter.type = .mp3
        if let imageData = (chapterData["APIC"] as? [String: Any])?["Data"] as? Data {
            chapter.imageData = imageData
        }
        return chapter
    }

    return parsedChapters.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
}

fileprivate func chapterTitle(from chapterData: [String: Any], fallback elementID: String) -> String {
    let titleCandidates = [
        chapterData["TIT2"],
        chapterData["Title"],
        chapterData["TIT3"],
        chapterData["TIT1"]
    ]

    for candidate in titleCandidates {
        if let title = firstNonEmptyString(in: candidate) {
            return title
        }
    }

    return elementID
}

fileprivate func firstNonEmptyString(in value: Any?) -> String? {
    if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    if let strings = value as? [String] {
        return strings.lazy.compactMap { firstNonEmptyString(in: $0) }.first
    }

    if let values = value as? [Any] {
        return values.lazy.compactMap { firstNonEmptyString(in: $0) }.first
    }

    if let dictionary = value as? [String: Any] {
        let nestedCandidates = [
            dictionary["Value"],
            dictionary["Title"],
            dictionary["Description"],
            dictionary["Text"],
            dictionary["rawText"]
        ]

        for candidate in nestedCandidates {
            if let string = firstNonEmptyString(in: candidate) {
                return string
            }
        }
    }

    return nil
}

enum ChapterExtractionHooks {
    nonisolated(unsafe) static var loadLocalMP3Chapters: (URL) async -> [Marker] = { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            let headerData = try handle.read(upToCount: 10) ?? Data()
            guard headerData.count >= 3,
                  let id3Identifier = String(data: headerData.prefix(3), encoding: .utf8),
                  id3Identifier == "ID3" else {
                return []
            }

            guard let mp3Reader = mp3ChapterReader(with: url) else { return [] }
            return parseMP3Chapters(from: mp3Reader.getID3Dict()) ?? []
        } catch {
            return []
        }
    }

    nonisolated(unsafe) static var loadRemoteMP3Chapters: (URL) async -> [Marker] = { url in
        guard let mp3Reader = await mp3ChapterReader.fromRemoteURL(url) else { return [] }
        return parseMP3Chapters(from: mp3Reader.getID3Dict()) ?? []
    }

    nonisolated(unsafe) static var loadM4AChapters: (URL) async -> [Marker] = { url in
        guard let chapterData = try? await MetadataLoader.loadChapters(from: url) else {
            return []
        }

        return chapterData.map { data in
            let chapter = Marker()
            chapter.title = data.title
            chapter.start = data.start
            chapter.duration = data.duration
            chapter.type = .mp4
            chapter.imageData = data.imageData
            return chapter
        }
    }
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
