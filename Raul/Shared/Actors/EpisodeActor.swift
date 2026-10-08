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
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import ImageIO


struct EpisodePlaybackStateSnapshot: Sendable {
    let playPosition: Double?
    let maxPlayPosition: Double?
}

struct LastPlayedEpisodeReference: Sendable {
    let url: URL
    let lastPlayed: Date
}

private struct EpisodeTranscriptionSnapshot {
    let url: URL
    let id: PersistentIdentifier
    let hasLoadedTranscript: Bool
    let hasExternalTranscript: Bool
    let publishesTranscripts: Bool
}

enum EpisodeCompletionError: LocalizedError {
    case episodeNotFound(URL)

    var errorDescription: String? {
        switch self {
        case .episodeNotFound(let episodeURL):
            return "Finished episode was not found: \(episodeURL.redactedPodcastURLString)"
        }
    }
}

enum EpisodeChapterMerger {
    static func identity(for chapter: Marker) -> String {
        let normalizedTitle = chapter.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedStart = Int(((chapter.start ?? 0) * 100).rounded())
        return "\(chapter.type.rawValue)|\(normalizedStart)|\(normalizedTitle)"
    }

    static func replaceChapters(
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
            let identity = identity(for: chapter)
            if existingByIdentity[identity] == nil {
                existingByIdentity[identity] = chapter
            }
        }

        var seen = Set<String>()
        let replacementChapters = newChapters.filter { chapter in
            seen.insert(identity(for: chapter)).inserted
        }
        var retainedChapters: [Marker] = []
        var chaptersToInsert: [Marker] = []
        for chapter in replacementChapters {
            if let existing = existingByIdentity[identity(for: chapter)] {
                // Keep user-controlled skip settings and listening progress.
                existing.title = chapter.title
                existing.start = chapter.start
                existing.endTime = chapter.endTime
                existing.duration = chapter.duration
                existing.analysisVariantID = chapter.analysisVariantID
                existing.image = chapter.image ?? existing.image
                existing.imageData = chapter.imageData ?? existing.imageData
                existing.link = chapter.link ?? existing.link
                existing.progress = shouldPreserveChapterProgress ? existing.progress : 0
                retainedChapters.append(existing)
            } else {
                chapter.episode = episode
                chaptersToInsert.append(chapter)
            }
        }

        episode.chapters?.removeAll { chapter in
            types.contains(chapter.type)
                && retainedChapters.contains(where: { $0 === chapter }) == false
        }
        episode.chapters?.append(contentsOf: chaptersToInsert)
        episode.chapters?.sort { ($0.start ?? 0) < ($1.start ?? 0) }
    }
}

enum ChapterSkipKeywordPolicy {
    static func apply(_ rules: [skipKey], to chapters: [Marker]) -> Bool {
        var didChange = false
        for rule in rules {
            guard let keyword = rule.keyWord?.lowercased(), !keyword.isEmpty else { continue }
            let matches: (String) -> Bool
            switch rule.keyOperator {
            case .Contains:
                matches = { $0.contains(keyword) }
            case .Is:
                matches = { $0 == keyword }
            case .StartsWith:
                matches = { $0.hasPrefix(keyword) }
            case .EndsWith:
                matches = { $0.hasSuffix(keyword) }
            }
            for chapter in chapters where matches(chapter.title.lowercased()) {
                didChange = didChange || chapter.shouldPlay
                chapter.shouldPlay = false
            }
        }
        return didChange
    }
}


@ModelActor
actor EpisodeActor {
    private static let legacyBackCatalogSuppressionMigrationKey = "EpisodeMetaData.backCatalogSuppressionMigration.v1"
    private static let legacyBackCatalogSuppressionArchiveWindow: TimeInterval = 24 * 60 * 60
    private var cachedEpisodeStateWriter: StoreSplitEpisodeStateSyncWriter?
    private var cachedEpisodeStateWriterStoreID: ObjectIdentifier?
    private var cachedLocalClassificationWriter:
        StoreSplitLocalEpisodeClassificationWriter?
    private var cachedLocalClassificationWriterStoreID: ObjectIdentifier?

    static func scheduleRemoteChapterFetch(episodeURL: URL, modelContainer: ModelContainer) {
        Task.detached(priority: .utility) {
#if canImport(UIKit)
            // Chapter extraction parses arbitrary HTML and may fault several
            // related SwiftData records. Starting that work from a download
            // callback while the app is backgrounded can keep scene updates
            // alive long enough for the watchdog to terminate the process.
            let isBackgrounded = await MainActor.run {
                UIApplication.shared.applicationState != .active
            }
            guard isBackgrounded == false else { return }
#endif
            await EpisodeActor(modelContainer: modelContainer)
                .getRemoteChapters(episodeURL: episodeURL)
        }
    }

    private func logAutoDownload(_ message: String) async {
        await MainActor.run {
            AppDiagnostics.log("[AutoDL] \(message)")
        }
    }

    private func episodeLogID(_ episode: Episode) -> String {
        if let episodeURL = episode.url?.redactedPodcastURLString {
            return episodeURL
        }
        return episode.title
    }

    private func chapterIdentity(for chapter: Marker) -> String {
        EpisodeChapterMerger.identity(for: chapter)
    }

    private func replaceChapters(
        on episode: Episode,
        replacingTypes types: Set<MarkerType>,
        with newChapters: [Marker]
    ) {
        EpisodeChapterMerger.replaceChapters(on: episode, replacingTypes: types, with: newChapters)
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
        ChapterSourcePolicy.shouldExtractShownotes(from: episode.chapters ?? [])
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
                let start = chapter.start ?? 0.0
                let end = max(lastEnd, start)
                let duration = end - start

                if chapter.duration != duration {
                    chapter.duration = duration
                    didChange = true
                }
                if chapter.endTime != end {
                    chapter.endTime = end
                    didChange = true
                }

                lastEnd = start
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
        await lastPlayedEpisodeReference()?.url
    }

    /// Newest played episode, resolved with a sorted single-row fetch.
    ///
    /// This runs on the launch path before playback can be restored, so it must
    /// not materialize every episode that was ever played just to take the
    /// maximum in memory.
    func lastPlayedEpisodeReference() async -> LastPlayedEpisodeReference? {
        let predicate = #Predicate<EpisodeMetaData> { metadata in
            metadata.isHistory != true && metadata.lastPlayed != nil
        }
        var descriptor = FetchDescriptor<EpisodeMetaData>(
            predicate: predicate,
            sortBy: [SortDescriptor(\EpisodeMetaData.lastPlayed, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        do {
            guard let metadata = try modelContext.fetch(descriptor).first,
                  let url = metadata.episode?.url,
                  let lastPlayed = metadata.lastPlayed else {
                return nil
            }
            return LastPlayedEpisodeReference(url: url, lastPlayed: lastPlayed)
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
        await persistLocalEpisodeClassification([episode])
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

    /// Commits the local source of truth for a naturally finished episode in one
    /// explicit SwiftData save. The player keeps its transition background lease
    /// until this method and the queue mutation both complete.
    func commitFinishedEpisode(
        episodeURL: URL,
        finalPlaybackPosition: TimeInterval,
        completionDate: Date = Date()
    ) async throws {
        let predicate = #Predicate<Episode> { episode in
            episode.url == episodeURL
        }
        let episodes = try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate))
        guard episodes.isEmpty == false else {
            throw EpisodeCompletionError.episodeNotFound(episodeURL)
        }

        let position = max(0, finalPlaybackPosition.isFinite ? finalPlaybackPosition : 0)
        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.playPosition = position
            episode.metaData?.maxPlayposition = max(
                episode.metaData?.maxPlayposition ?? 0,
                position
            )
            episode.metaData?.completionDate = completionDate
            episode.metaData?.lastPlayed = completionDate
            episode.metaData?.isArchived = false
            episode.metaData?.isHistory = true
            episode.metaData?.isInbox = false
            episode.metaData?.status = .history
            episode.metaData?.systemSuppressionReason = nil
        }

        // Do not use saveIfNeeded here: a completion handoff must be able to
        // report a failed commit instead of continuing as though it succeeded.
        try modelContext.save()

        // These projections are useful follow-up work, but the local SwiftData
        // save above is the durable completion boundary used by playback recovery.
        let podcastFeeds = Set(episodes.compactMap { $0.podcast?.feed })
        Task { [self] in
            await persistLocalEpisodeClassification(episodes)
            for episode in episodes {
                await publishSplitEpisodeState(episode)
            }

            // Moving to history used to trigger automatic download policy updates.
            // Keep that work off the protected playback handoff while preserving
            // the post-completion behavior.
            for podcastFeed in podcastFeeds {
                await applyAutomaticDownloadPolicy(for: podcastFeed, force: true)
            }
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
        await persistLocalEpisodeClassification([episode])
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
        await logAutoDownload("trigger/remove-from-all-playlists episode=\(episodeURL.redactedPodcastURLString)")
        if let playlistModelActor = try? PlaylistModelActor(modelContainer: modelContainer) {
            try? await playlistModelActor.removeFromAllPlaylists(episodeURL: episodeURL)
        } else {
            await logAutoDownload("trigger/remove-from-all-playlists failed-to-create-playlist-actor episode=\(episodeURL.redactedPodcastURLString)")
        }
    }
    
    func archiveEpisode(_ episodeURL: URL?) async {
        guard let episodeURL else { return }
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard episodes.isEmpty == false else {
            print("could not find episode with URL \(episodeURL.redactedPodcastURLString) to archive")
            return }
        let podcastFeeds = Set(episodes.compactMap { $0.podcast?.feed })
        await logAutoDownload("trigger/archive episode=\(episodeURL.redactedPodcastURLString) matchedEpisodes=\(episodes.count) affectedFeeds=\(podcastFeeds.count)")
        
        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.setArchived(true)
            episode.metaData?.setInboxMembership(false)
        }

        modelContext.saveIfNeeded()
        await persistLocalEpisodeClassification(episodes)
        await MainActor.run {
            NotificationCenter.default.post(name: .smartPlaylistEpisodeDataDidChange, object: nil)
        }
        for episode in episodes {
            await publishSplitEpisodeState(episode)
        }
        WatchSyncCoordinator.refreshSoon(force: true)

        for podcastFeed in podcastFeeds {
            await logAutoDownload("trigger/archive applying-policy feed=\(podcastFeed.redactedPodcastURLString)")
            await applyAutomaticDownloadPolicy(for: podcastFeed, force: true)
        }
    }
    
    func unarchiveEpisode(_ episodeURL: URL?) async  {
        guard let episodeURL else { return }
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard episodes.isEmpty == false else { return }
        await logAutoDownload("trigger/unarchive episode=\(episodeURL.redactedPodcastURLString) matchedEpisodes=\(episodes.count)")

        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.setArchived(false)
        }
        modelContext.saveIfNeeded()
        await persistLocalEpisodeClassification(episodes)
        await MainActor.run {
            NotificationCenter.default.post(name: .smartPlaylistEpisodeDataDidChange, object: nil)
        }
        for episode in episodes {
            await publishSplitEpisodeState(episode)
        }
        WatchSyncCoordinator.refreshSoon(force: true)
    }

    func removeFromInbox(_ episodeURL: URL?) async {
        guard let episodeURL else { return }
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard episodes.isEmpty == false else { return }

        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.setInboxMembership(false)
        }

        modelContext.saveIfNeeded()
        await persistLocalEpisodeClassification(episodes)
        await MainActor.run {
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
        }
        WatchSyncCoordinator.refreshSoon(force: true)
    }

    func addToInbox(_ episodeURL: URL?) async {
        guard let episodeURL else { return }
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard episodes.isEmpty == false else { return }

        for episode in episodes {
            ensureMetadata(for: episode)
            episode.metaData?.setInboxMembership(true)
        }

        modelContext.saveIfNeeded()
        await persistLocalEpisodeClassification(episodes)
        await MainActor.run {
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
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
            episode.metaData?.setInboxMembership(false)
            episode.metaData?.systemSuppressionReason = reason
        }

        modelContext.saveIfNeeded()
        await persistLocalEpisodeClassification(episodes)
        await MainActor.run {
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
        }
    }

    private func publishSplitEpisodeState(_ episode: Episode) async {
        guard let metadata = episode.metaData else { return }
        // Stamp before publishing so the local row and the UserState record carry
        // the same generation. The importer compares the two and refuses to
        // replace local state with an older remote record.
        //
        // `setPlayPosition` calls this every 10 seconds during playback, so the
        // stamp is only advanced when the published state actually differs from
        // what this device last published. Writing it unconditionally dirtied the
        // row on every tick and forced a save each time.
        let publishedAt = Date()
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
        let mayPublish = await MainActor.run {
            ModelContainerManager.shared.mayStartCloudKitBackedStoreWrite
        }
        guard mayPublish else {
            CrashBreadcrumbs.shared.record(
                "store_split_episode_state_write_deferred",
                details: "reason=cloudkit_export_or_lifecycle_gate"
            )
            return
        }
        guard let writer = await episodeStateWriter() else { return }
        let didChange = await writer.upsert(snapshot, at: publishedAt)
        if didChange {
            metadata.stateUpdatedAt = publishedAt
            modelContext.saveIfNeeded()
        }
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
        await persistLocalEpisodeClassification(episodes)
    }
    
    func moveToHistory(episodeURL: URL) async {
        let episodes = await fetchEpisodes(byURL: episodeURL)
        guard episodes.isEmpty == false else { return }
        let podcastFeeds = Set(episodes.compactMap { $0.podcast?.feed })
        await logAutoDownload("trigger/move-to-history episode=\(episodeURL.redactedPodcastURLString) matchedEpisodes=\(episodes.count) affectedFeeds=\(podcastFeeds.count)")
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
        await persistLocalEpisodeClassification(episodes)
        for episode in episodes {
            await publishSplitEpisodeState(episode)
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
            WatchSyncCoordinator.refreshSoon(force: true)
        }

        for podcastFeed in podcastFeeds {
            await logAutoDownload("trigger/move-to-history applying-policy feed=\(podcastFeed.redactedPodcastURLString)")
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
            await logAutoDownload("policy/skip feed=\(podcastFeed.redactedPodcastURLString) reason=\(reason)")
            return
        }
        defer {
            Task {
                await throttle.finish(feed: podcastFeed)
            }
        }

        await logAutoDownload("policy/start feed=\(podcastFeed.redactedPodcastURLString) force=\(force)")

        guard let policy = await settingsActor.autoDownloadPolicy(for: podcastFeed) else {
            await logAutoDownload("policy/skip feed=\(podcastFeed.redactedPodcastURLString) reason=no-policy")
            return
        }

        let keepCount = policy.keepCount
        let selection = policy.selection
        let queuePosition = policy.queuePosition
        let playlistID = policy.playlistID
        let networkMode = policy.networkMode
        let includesBackCatalogEpisodes = policy.includesArchivedEpisodes
        let episodeFilter = policy.episodeFilter
        await logAutoDownload(
            "policy/config feed=\(podcastFeed.redactedPodcastURLString) keep=\(keepCount) selection=\(selection.rawValue) queuePosition=\(queuePosition) playlistID=\(playlistID?.uuidString ?? "nil") network=\(networkMode.rawValue) includeBackCatalog=\(includesBackCatalogEpisodes)"
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
            await logAutoDownload("policy/error feed=\(podcastFeed.redactedPodcastURLString) step=fetch-episodes error=\(error.localizedDescription)")
            return
        }

        guard podcastEpisodes.isEmpty == false else {
            await logAutoDownload("policy/skip feed=\(podcastFeed.redactedPodcastURLString) reason=no-episodes")
            return
        }

        var skippedHistory = 0
        var skippedArchived = 0
        var skippedPlayed = 0
        var skippedManualPlaylistRemoval = 0
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

            if suppressionReason == .manualPlaylistRemoval {
                skippedManualPlaylistRemoval += 1
                if sampledDecisions.count < maxSampledDecisions {
                    sampledDecisions.append("\(episodeLogID(episode)) => skipped:manualPlaylistRemoval")
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
            "policy/eligibility feed=\(podcastFeed.redactedPodcastURLString) total=\(podcastEpisodes.count) eligible=\(eligibleEpisodes.count) skippedHistory=\(skippedHistory) skippedArchived=\(skippedArchived) skippedPlayed=\(skippedPlayed) skippedManualPlaylistRemoval=\(skippedManualPlaylistRemoval) skippedMissingSideload=\(skippedMissingSideload) skippedBackCatalogToggle=\(skippedBackCatalogToggle) sampleCount=\(sampledDecisions.count)"
        )
        if sampledDecisions.isEmpty == false {
            await logAutoDownload("policy/eligibility-sample feed=\(podcastFeed.redactedPodcastURLString) \(sampledDecisions.joined(separator: " | "))")
        }

        guard eligibleEpisodes.isEmpty == false else {
            await logAutoDownload("policy/stop feed=\(podcastFeed.redactedPodcastURLString) reason=no-eligible-episodes")
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

        // The established queue and retention policy uses this stable set. New
        // metadata rules only gate downloads, so they never alter queue membership.
        let policyTargetEpisodes = Array(sortedEpisodes.prefix(keepCount))
        let targetEpisodes = policyTargetEpisodes.filter { episode in
            episodeFilter.allows(
                title: episode.title,
                duration: episode.duration,
                publishDate: episode.publishDate,
                type: episode.type
            )
        }
        let overflowEpisodes = Array(sortedEpisodes.dropFirst(keepCount))
        let targetEpisodeURLs = Set(policyTargetEpisodes.compactMap(\.url))
        let downloadTargetURLs = Set(targetEpisodes.compactMap(\.url))
        let playlistActor = playlistActor(for: playlistID)
        let canScheduleDownloads = await canScheduleAutoDownloads(for: networkMode)
        await logAutoDownload(
            "policy/target feed=\(podcastFeed.redactedPodcastURLString) targetCount=\(targetEpisodes.count) queuePosition=\(queuePosition) playlistActorAvailable=\(playlistActor != nil) canScheduleDownloads=\(canScheduleDownloads)"
        )
        if targetEpisodes.isEmpty == false {
            let targetIDs = targetEpisodes.map(episodeLogID).joined(separator: ", ")
            await logAutoDownload("policy/target-episodes feed=\(podcastFeed.redactedPodcastURLString) \(targetIDs)")
        }

        for episode in policyTargetEpisodes {
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
                        await logAutoDownload("policy/error feed=\(podcastFeed.redactedPodcastURLString) step=contains-in-playlist episode=\(episodeURL.redactedPodcastURLString) error=\(error.localizedDescription)")
                    }
                } else {
                    await logAutoDownload("policy/queue-skip feed=\(podcastFeed.redactedPodcastURLString) episode=\(episodeURL.redactedPodcastURLString) reason=no-playlist-actor")
                }
                if isQueued == false && isUserArchived == false && isPlayed == false {
                    if let playlistActor {
                        do {
                            try await playlistActor.add(
                                episodeURL: episodeURL,
                                to: queuePosition,
                                startDownload: false,
                                origin: .automatic
                            )
                            await logAutoDownload("policy/queue-add feed=\(podcastFeed.redactedPodcastURLString) episode=\(episodeURL.redactedPodcastURLString) result=success")
                        } catch {
                            await logAutoDownload("policy/queue-add feed=\(podcastFeed.redactedPodcastURLString) episode=\(episodeURL.redactedPodcastURLString) result=failure error=\(error.localizedDescription)")
                        }
                    } else {
                        await logAutoDownload("policy/queue-add feed=\(podcastFeed.redactedPodcastURLString) episode=\(episodeURL.redactedPodcastURLString) result=skipped-no-playlist-actor")
                    }
                } else {
                    await logAutoDownload(
                        "policy/queue-skip feed=\(podcastFeed.redactedPodcastURLString) episode=\(episodeURL.redactedPodcastURLString) reason=\(isQueued ? "already-queued" : (isUserArchived ? "user-archived" : "played"))"
                    )
                }
            } else {
                await logAutoDownload("policy/queue-skip feed=\(podcastFeed.redactedPodcastURLString) episode=\(episodeURL.redactedPodcastURLString) reason=queue-position-none")
            }

            if downloadTargetURLs.contains(episodeURL) == false {
                await logAutoDownload("policy/download feed=\(podcastFeed.redactedPodcastURLString) episode=\(episodeURL.redactedPodcastURLString) action=skip-filter")
            } else if canScheduleDownloads && isDownloaded == false {
                await logAutoDownload("policy/download feed=\(podcastFeed.redactedPodcastURLString) episode=\(episodeURL.redactedPodcastURLString) action=start")
                await download(episodeURL: episodeURL)
            } else if canScheduleDownloads == false && isDownloaded == false {
                await logAutoDownload("policy/download feed=\(podcastFeed.redactedPodcastURLString) episode=\(episodeURL.redactedPodcastURLString) action=defer-network-gate")
            }
        }

        var removedFromPlaylist = 0
        if overflowEpisodes.isEmpty == false {
            if queuePosition == .none {
                await logAutoDownload("policy/prune-skip feed=\(podcastFeed.redactedPodcastURLString) reason=queue-position-none overflowCount=\(overflowEpisodes.count)")
            } else if let playlistActor {
                let queuedEpisodeURLs: Set<URL>
                do {
                    queuedEpisodeURLs = Set(try await playlistActor.orderedEpisodeURLs())
                } catch {
                    await logAutoDownload("policy/error feed=\(podcastFeed.redactedPodcastURLString) step=fetch-playlist-urls error=\(error.localizedDescription)")
                    queuedEpisodeURLs = []
                }

                for episode in overflowEpisodes {
                    guard let episodeURL = episode.url else { continue }
                    guard queuedEpisodeURLs.contains(episodeURL) else { continue }

                    do {
                        try await playlistActor.remove(
                            episodeURL: episodeURL,
                            origin: .policyMaintenance
                        )
                        removedFromPlaylist += 1
                        await logAutoDownload("policy/prune-remove feed=\(podcastFeed.redactedPodcastURLString) episode=\(episodeURL.redactedPodcastURLString)")
                    } catch {
                        await logAutoDownload("policy/prune-remove feed=\(podcastFeed.redactedPodcastURLString) episode=\(episodeURL.redactedPodcastURLString) result=failure error=\(error.localizedDescription)")
                    }
                }
            } else {
                await logAutoDownload("policy/prune-skip feed=\(podcastFeed.redactedPodcastURLString) reason=no-playlist-actor overflowCount=\(overflowEpisodes.count)")
            }
        }
        await logAutoDownload("policy/prune-summary feed=\(podcastFeed.redactedPodcastURLString) overflowCount=\(overflowEpisodes.count) removedFromPlaylist=\(removedFromPlaylist)")

        let hasTargetCoverage = targetEpisodes.allSatisfy { episode in
            episode.metaData?.calculatedIsAvailableLocally == true
        }

        if hasTargetCoverage == false {
            await logAutoDownload("policy/cleanup-skip feed=\(podcastFeed.redactedPodcastURLString) reason=targets-not-downloaded")
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
            await logAutoDownload("policy/cleanup-delete feed=\(podcastFeed.redactedPodcastURLString) episode=\(episodeURL.redactedPodcastURLString)")
        }
        await logAutoDownload("policy/done feed=\(podcastFeed.redactedPodcastURLString) deletedDownloads=\(deletedDownloads)")
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
            await persistLocalEpisodeClassification(episodes)
            await MainActor.run {
                NotificationCenter.default.post(name: .inboxDidChange, object: nil)
            }
        }

        defaults.set(true, forKey: Self.legacyBackCatalogSuppressionMigrationKey)
    }

    private func persistLocalEpisodeClassification(
        _ episodes: [Episode]
    ) async {
        let snapshots = episodes.compactMap {
            episode -> StoreSplitLocalEpisodeClassificationSnapshot? in
            guard let metadata = episode.metaData else { return nil }
            return StoreSplitLocalEpisodeClassificationSnapshot(
                identity: episode.stableEpisodeIdentity,
                isInbox: metadata.isInbox == true,
                statusRawValue: metadata.status?.rawValue,
                systemSuppressionReasonRawValue:
                    metadata.systemSuppressionReasonRawValue
            )
        }
        guard snapshots.isEmpty == false,
              let writer = await localEpisodeClassificationWriter() else { return }
        await writer.upsert(snapshots)
    }

    private func localEpisodeClassificationWriter() async
        -> StoreSplitLocalEpisodeClassificationWriter? {
        guard let cacheContainer = await preparedCacheContainer() else {
            return nil
        }
        let storeID = ObjectIdentifier(cacheContainer)
        if let cachedLocalClassificationWriter,
           cachedLocalClassificationWriterStoreID == storeID {
            return cachedLocalClassificationWriter
        }
        let writer = StoreSplitLocalEpisodeClassificationWriter(
            modelContainer: cacheContainer
        )
        cachedLocalClassificationWriter = writer
        cachedLocalClassificationWriterStoreID = storeID
        return writer
    }

    private func canScheduleAutoDownloads(for networkMode: AutoDownloadNetworkMode) async -> Bool {
        await AutoDownloadNetworkGate.canScheduleDownloads(for: networkMode)
    }
    
    
    func download(episodeURL: URL) async {
        guard let episode = await fetchEpisode(byURL: episodeURL) else {
            return }
        guard episode.source != .sideLoaded else { return }

        if let localFile = episode.localFile {
            let accessProfile = episode.podcast?.metaData.flatMap { metadata -> PodcastAccessProfile? in
                guard let feedURL = episode.podcast?.feed,
                      let profileID = metadata.accessProfileID,
                      let rawKind = metadata.accessKindRawValue,
                      let kind = PodcastAccessKind(rawValue: rawKind) else {
                    return nil
                }
                return PodcastAccessProfile(
                    id: profileID,
                    kind: kind,
                    resourceURL: feedURL,
                    providerID: metadata.accessProviderID.flatMap(PremiumPodcastProviderID.init(rawValue:))
                )
            }
            if let url = episode.url,
               await DownloadManager.shared.download(from: url, saveTo: localFile, profile: accessProfile) != nil {
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
            try? await playlistActor?.add(
                episodeURL: episodeURL,
                to: playnext,
                origin: .automatic
            )
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
        print("mark Available for \(fileURL.redactedPodcastURLString)")
        guard let episode = await fetchEpisode(byURL: fileURL) else {
            print("episode not found")
            return }

        print ("markEpisodeAvailable for \(episode.title)")
        guard let url = episode.url else {
            return
        }
        if let artworkURL = episode.imageURL ?? episode.podcast?.imageURL {
            Task(priority: .utility) {
                _ = await ImageLoaderAndCache.loadUIImage(from: artworkURL)
            }
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
        guard let snapshot = await transcriptionSnapshot(for: fileURL, origin: origin) else { return }
        let episodeURL = snapshot.url
        let episodeID = snapshot.id
        let settingsActor = PodcastSettingsModelActor(modelContainer: modelContainer)
        if origin == .automatic, await settingsActor.getTranscriptionsEnabled() == false { return }

        if snapshot.hasLoadedTranscript {
            await finalizeTranscriptChapters(for: episodeURL)
            return
        }
        
        if snapshot.hasExternalTranscript {
            do {
                try await downloadTranscript(episodeID, manuallyRequested: origin == .manual)
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

        // A podcast that publishes transcripts for its other episodes publishes
        // one for this episode too, usually within a day of release. Running the
        // analyzer automatically would spend minutes of CPU and battery on a
        // transcript the next feed refresh imports for free. A transcription the
        // user asked for still goes ahead.
        if origin == .automatic, snapshot.publishesTranscripts {
            return
        }

        let transcriptionManager = await MainActor.run { TranscriptionManager.shared }
        _ = await transcriptionManager.enqueueTranscription(
            episodeURL: episodeURL,
            origin: origin
        )
    }

    private func transcriptionSnapshot(
        for fileURL: URL,
        origin: TranscriptionStartOrigin
    ) async -> EpisodeTranscriptionSnapshot? {
        guard let episode = await fetchEpisode(byURL: fileURL),
              let episodeURL = episode.url else { return nil }
        return EpisodeTranscriptionSnapshot(
            url: episodeURL,
            id: episode.persistentModelID,
            hasLoadedTranscript: episode.hasLoadedTranscript,
            hasExternalTranscript: episode.externalFiles.contains {
                $0.category == .transcript
            },
            publishesTranscripts: origin == .automatic
                && podcastPublishesTranscripts(for: episode)
        )
    }

    /// Whether the episode's podcast ships transcript files with its feed.
    func podcastPublishesTranscripts(for episode: Episode) -> Bool {
        guard let podcastID = episode.podcast?.persistentModelID else { return false }
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { candidate in
                candidate.podcast?.persistentModelID == podcastID
            }
        )
        guard let episodes = try? modelContext.fetch(descriptor) else { return false }
        return episodes.contains { candidate in
            candidate.externalFiles.contains { $0.category == .transcript }
        }
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

    
    func decodeTranscription(_ transcription: String) -> [TranscriptLineAndTime] {
        print("decodeTranscription")
        let snapshots = decodeTranscriptSnapshots(transcription)
        print("created \(snapshots.count) lines")
        return snapshots.map {
            TranscriptLineAndTime(
                speaker: $0.speaker,
                text: $0.text,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
    }

    private func decodeTranscriptSnapshots(_ transcription: String) -> [TranscriptLineSnapshot] {
        let decoder = TranscriptDecoder(transcription)
        return decoder.transcriptLines.map {
            TranscriptLineSnapshot(
                speaker: $0.speaker,
                text: $0.text,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }.sorted {
            if $0.startTime != $1.startTime {
                return $0.startTime < $1.startTime
            }
            let leftEnd = $0.endTime ?? .greatestFiniteMagnitude
            let rightEnd = $1.endTime ?? .greatestFiniteMagnitude
            return leftEnd < rightEnd
        }
    }
    
    func deleteMarker(markerID: UUID) async{
        guard let marker = await fetchMarker(byID: markerID) else { return}
        if let episode = marker.bookmarkEpisode,
           let userStateContainer = await preparedUserStateContainer() {
            await StoreSplitBookmarkSyncWriter(modelContainer: userStateContainer)
                .tombstone(
                    StoreSplitBookmarkSnapshot(
                        id: markerID.uuidString,
                        identity: episode.stableEpisodeIdentity,
                        time: marker.start ?? 0,
                        title: marker.title,
                        createdAt: marker.creationtime ?? .now
                    )
                )
        }
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
               let jsonString = await downloadAndParseStringFile(
                   url: url,
                   profile: accessProfile(for: episode)
               ),
               let jsonData = jsonString.data(using: .utf8),
               let chapters = await parseJSONChapters(
                   jsonData: jsonData,
                   profile: accessProfile(for: episode)
               ) {
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
        guard let skipWords = await actor.getChapterSkipKeywords(for: episode.podcast?.feed) else {
            return false
        }
        let didChange = ChapterSkipKeywordPolicy.apply(skipWords, to: episode.chapters ?? [])
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
                .map {
                    ChapterExternalFileSnapshot(
                        urlString: $0.url,
                        fileType: $0.fileType,
                        profile: accessProfile(for: episode)
                    )
                },
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

        sources.append(contentsOf: await existingChapterImageSourceData(
            for: snapshot.chapterImages,
            profile: snapshot.profile
        ))
        sources.append(contentsOf: await jsonChapterSourceData(
            for: snapshot.chapterFiles,
            profile: snapshot.profile
        ))

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
                sources.append(contentsOf: await m4aChapterSourceData(
                    from: remoteURL,
                    profile: snapshot.profile
                ))
            }
        }

        return sources
    }

    private func existingChapterImageSourceData(
        for chapters: [StoredChapterImageSnapshot],
        profile: PodcastAccessProfile?
    ) async -> [SendableChapterSourceData] {
        var sources: [SendableChapterSourceData] = []

        for chapter in chapters {
            guard let imageURL = chapter.imageURL else { continue }
            let imageData = await downloadBinaryFile(url: imageURL, profile: profile)
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

    private func m4aChapterSourceData(
        from url: URL,
        profile: PodcastAccessProfile? = nil
    ) async -> [SendableChapterSourceData] {
        guard let chapterData = try? await MetadataLoader.loadChapters(from: url, profile: profile) else {
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

    private func jsonChapterSourceData(
        for chapterFiles: [ChapterExternalFileSnapshot],
        profile: PodcastAccessProfile?
    ) async -> [SendableChapterSourceData] {
        var sources: [SendableChapterSourceData] = []

        for chapterFile in chapterFiles {
            guard let url = URL(string: chapterFile.urlString) else { continue }

            let isJSON = url.pathExtension.lowercased() == "json"
                || (chapterFile.fileType?.lowercased().contains("json") == true)
            guard isJSON,
                  let jsonString = await downloadAndParseStringFile(url: url, profile: profile ?? chapterFile.profile),
                  let jsonData = jsonString.data(using: .utf8),
                  let chapterSources = await parseJSONChapterData(
                      jsonData: jsonData,
                      profile: profile ?? chapterFile.profile
                  ) else {
                continue
            }

            sources.append(contentsOf: chapterSources)
        }

        return sources
    }

    private func parseJSONChapterData(
        jsonData: Data,
        profile: PodcastAccessProfile?
    ) async -> [SendableChapterSourceData]? {
        do {
            let decoder = JSONDecoder()
            let chapterList = try decoder.decode(JSONChapterList.self, from: jsonData)
            var chapters: [SendableChapterSourceData] = []

            for chapter in chapterList.chapters {
                let imageURL = chapter.img.flatMap(URL.init(string:))
                let imageData: Data?
                if let imageURL {
                    imageData = await downloadBinaryFile(url: imageURL, profile: profile)
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

    private func downloadBinaryFile(url: URL, profile: PodcastAccessProfile? = nil) async -> Data? {
        await ImageLoaderAndCache.loadImageData(from: url, saveTo: nil, profile: profile)
    }
    
    @discardableResult
    private func extractMP3Chapters(_ episodeID: PersistentIdentifier) async -> Bool {
        guard let episode: Episode = modelContext.existingModel(for: episodeID) else { return false }
        guard let url = episode.localFile else {
            return false
        }
        let chapters = await ChapterExtractionHooks.loadLocalMP3Chapters(url)
        guard chapters.isEmpty == false else { return false }

        // Re-acquired rather than carried across the await: reading the file
        // takes long enough that the episode may be gone by now.
        guard let episode: Episode = modelContext.existingModel(for: episodeID) else { return false }
        replaceChapters(on: episode, replacingTypes: [.mp3], with: chapters)
        episode.refresh.toggle()
        modelContext.saveIfNeeded()
        return true
    }
    
    @discardableResult
    func extractRemoteMP3Chapters(_ fileURL: URL) async -> Bool {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return false }
        guard let remoteURL = episode.url else { return false }
        let episodeID = episode.persistentModelID

        let chapters = await ChapterExtractionHooks.loadRemoteMP3Chapters(
            remoteURL,
            accessProfile(for: episode)
        )
        guard chapters.isEmpty == false else { return false }
        guard let episode: Episode = modelContext.existingModel(for: episodeID) else { return false }

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
    
    func parseJSONChapters(
        jsonData: Data,
        profile: PodcastAccessProfile? = nil
    ) async -> [Marker]? {
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
                    chapter.imageData = await downloadBinaryFile(url: imgUrl, profile: profile)
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
        guard let episode: Episode = modelContext.existingModel(for: episodeID) else { return false }
        guard let url = episode.localFile else {
            return false
        }
        let chapters = await ChapterExtractionHooks.loadM4AChapters(url, nil)
        guard chapters.isEmpty == false else { return false }

        // Re-acquired rather than carried across the await: reading the file
        // takes long enough that the episode may be gone by now.
        guard let episode: Episode = modelContext.existingModel(for: episodeID) else { return false }
        replaceChapters(on: episode, replacingTypes: [.mp4], with: chapters)
        episode.refresh.toggle()
        modelContext.saveIfNeeded()
        return true
    }
    
    @discardableResult
    func extractTranscriptChapters(fileURL: URL, force: Bool = false) async -> Bool {
        guard let episode = await fetchEpisode(byURL: fileURL) else { return false }
        let automaticGenerationEnabled = await shouldAutomaticallyGenerateChapters()
        guard force || automaticGenerationEnabled else { return false }
        return await generateEpisodeChapters(for: episode, fileURL: fileURL, force: force)
    }

    /// Generates editorial and confirmed-ad chapters together, while leaving
    /// publisher, embedded, and extracted chapters untouched.
    @discardableResult
    func generateEpisodeChapters(for episodeURL: URL, force: Bool = false) async -> Bool {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return false }
        let automaticGenerationEnabled = await shouldAutomaticallyGenerateChapters()
        guard force || automaticGenerationEnabled else { return false }
        return await generateEpisodeChapters(for: episode, fileURL: episodeURL, force: force)
    }

    /// Adds newly detected advertisement ranges to an existing generated set
    /// without rerunning transcript or semantic analysis.
    @discardableResult
    func mergeDetectedAdvertisementChapters(for episodeURL: URL) async -> Bool {
        guard await shouldAutomaticallyGenerateChapters(),
              let episode = await fetchEpisode(byURL: episodeURL) else { return false }
        let expectedVariantID = AudioVariantIdentity.make(
            episodeURL: episodeURL,
            mediaURL: episode.localFile ?? episode.url
        )
        let adSegments = await AdDetectionResultsStore.shared.segments(
            for: episodeURL.absoluteString,
            audioVariantID: expectedVariantID
        )
        guard adSegments.isEmpty == false else { return false }
        let editorialCandidates = (episode.chapters ?? [])
            .filter { $0.type == .ai }
            .compactMap { chapter -> GeneratedEditorialChapterCandidate? in
                guard let start = chapter.start else { return nil }
                return GeneratedEditorialChapterCandidate(title: chapter.title, start: start)
            }
        return await materializeGeneratedChapters(
            for: episode,
            fileURL: episodeURL,
            editorialCandidates: editorialCandidates,
            adSegments: adSegments
        )
    }

    private func generateEpisodeChapters(
        for episode: Episode,
        fileURL: URL,
        force: Bool,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> Bool {
        let transcriptLines = episode.transcriptLines ?? []
        let audioVariantID = AudioVariantIdentity.make(
            episodeURL: fileURL,
            mediaURL: episode.localFile ?? episode.url
        )
        let adSegments = await AdDetectionResultsStore.shared.segments(
            for: fileURL.absoluteString,
            audioVariantID: audioVariantID
        )

        guard force || shouldGenerateTranscriptChapters(for: episode) else { return false }

        var editorialCandidates: [GeneratedEditorialChapterCandidate] = []
        var advertisementCandidates: [GeneratedAdvertisementCandidate] = []
        if transcriptLines.isEmpty == false {
            progress?(String(localized: "Preparing transcript chapters…"))
            let extractedData = await generateAIChapters(from: transcriptLines, progress: progress)
            guard Task.isCancelled == false else { return false }
            editorialCandidates = extractedData.compactMap { timecode, title in
                guard let start = timecode.durationAsSeconds else { return nil }
                let isAdvertisement = title.lowercased().hasPrefix("advertisement:")
                if isAdvertisement {
                    advertisementCandidates.append(GeneratedAdvertisementCandidate(start: start))
                    return nil
                }
                let normalizedTitle = title
                    .replacingOccurrences(
                        of: #"(?i)^\s*advertisement\s*:\s*"#,
                        with: "",
                        options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalizedTitle.isEmpty == false else { return nil }
                return GeneratedEditorialChapterCandidate(title: normalizedTitle, start: start)
            }
        }

        return await materializeGeneratedChapters(
            for: episode,
            fileURL: fileURL,
            editorialCandidates: editorialCandidates,
            advertisementCandidates: advertisementCandidates,
            adSegments: adSegments,
            audioVariantID: audioVariantID
        )
    }

    private func materializeGeneratedChapters(
        for episode: Episode,
        fileURL: URL,
        editorialCandidates: [GeneratedEditorialChapterCandidate],
        advertisementCandidates: [GeneratedAdvertisementCandidate] = [],
        adSegments: [AdSegment],
        audioVariantID: String? = nil
    ) async -> Bool {
        let resolvedAudioVariantID = audioVariantID ?? AudioVariantIdentity.make(
            episodeURL: fileURL,
            mediaURL: episode.localFile ?? episode.url
        )
        let proposals = GeneratedChapterEngine.makeProposals(
            editorialCandidates: editorialCandidates,
            advertisementCandidates: advertisementCandidates,
            adSegments: adSegments,
            existingTypes: (episode.chapters ?? []).map(\.type),
            episodeDuration: episode.duration,
            audioVariantID: resolvedAudioVariantID
        )
        guard proposals.isEmpty == false, Task.isCancelled == false else { return false }

        let newChapters = proposals.map { proposal in
            let chapter = Marker(
                start: proposal.start,
                title: proposal.title,
                type: .ai,
                duration: proposal.end.map { $0 - proposal.start }
            )
            chapter.endTime = proposal.end
            chapter.analysisVariantID = proposal.audioVariantID
            return chapter
        }
        var generatedTypes: Set<MarkerType> = [.ai]
        if ChapterSourcePolicy.shouldGenerateTranscriptChapters(from: episode.chapters ?? []) {
            generatedTypes.insert(.extracted)
        }
        replaceChapters(on: episode, replacingTypes: generatedTypes, with: newChapters)
        episode.refresh.toggle()
        modelContext.saveIfNeeded()
        await writeAIChaptersToSplitStore(
            episode: episode,
            chapters: newChapters,
            generatedAt: .now
        )
        return true
    }

    private func shouldAutomaticallyGenerateChapters() async -> Bool {
        await PodcastSettingsModelActor(modelContainer: modelContainer)
            .getAutomaticChapterGenerationEnabled()
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
                  let jsonString = await downloadAndParseStringFile(
                      url: url,
                      profile: accessProfile(for: episode)
                  ),
                  let jsonData = jsonString.data(using: .utf8),
                  let chapters = await parseJSONChapters(
                      jsonData: jsonData,
                      profile: accessProfile(for: episode)
                  ),
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
        let parsedShownotes = ShownotesChapterExtractor.extractTimeCodesAndTitles(
            fromShownotesCandidates: shownotesCandidates
        )
        var extractedData = parsedShownotes

        // Keep an existing transcript-derived result when there are no actual
        // timestamps in the shownotes. The AI fallback below is only useful when
        // no better generated chapter set already exists.
        if extractedData == nil,
           (episode.chapters ?? []).contains(where: { $0.type == .ai }) == false {
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
            let replacedTypes: Set<MarkerType> = parsedShownotes == nil
                ? [.extracted]
                : [.extracted, .ai]
            replaceChapters(on: episode, replacingTypes: replacedTypes, with: newchapters)
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
        await generateAIChapters(from: transcript, progress: nil)
    }

    func generateAIChapters(
        from transcript: [TranscriptLineAndTime],
        progress: (@Sendable (String) -> Void)?
    ) async -> [String: String] {
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
        let aiChapters = await chapterGenerator.createChaptersFromTranscriptLines(snapshots, progress: progress)
        return aiChapters
    }
    
    private func shouldGenerateTranscriptChapters(for episode: Episode) -> Bool {
        guard episode.transcriptLines?.isEmpty == false else { return false }
        return ChapterSourcePolicy.shouldGenerateTranscriptChapters(from: episode.chapters ?? [])
    }

    @discardableResult
    func finalizeTranscriptChapters(for episodeURL: URL, force: Bool = false) async -> Bool {
        let didGenerate = await extractTranscriptChapters(fileURL: episodeURL, force: force)
        await updateChapterDurations(episodeURL: episodeURL)
        await applyAutoSkipWords(episodeURL: episodeURL)
        return didGenerate
    }

    @discardableResult
    func regenerateTranscriptChapters(for episodeURL: URL) async -> Bool {
        return await finalizeTranscriptChapters(for: episodeURL, force: true)
    }

    func hasTranscript(for episodeURL: URL) async -> Bool {
        await fetchEpisode(byURL: episodeURL)?.transcriptLines?.isEmpty == false
    }

    @discardableResult
    func generateChaptersOnDemand(
        for episodeURL: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> Bool {
        guard let episode = await fetchEpisode(byURL: episodeURL),
              episode.transcriptLines?.isEmpty == false else { return false }
        return await generateEpisodeChapters(
            for: episode,
            fileURL: episodeURL,
            force: true,
            progress: progress
        )
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
            let end: Double?
            if i + 1 < chapters.count, let nextStart = chapters[i + 1].start {
                end = max(nextStart, start)
            } else {
                end = episode.duration.map { max($0, start) }
            }

            let duration = end.map { $0 - start }
            if isGeneratedAdvertisementChapter(chapters[i]) {
                continue
            }
            if chapters[i].duration != duration {
                chapters[i].duration = duration
                didChange = true
            }
            if chapters[i].endTime != end {
                chapters[i].endTime = end
                didChange = true
            }
        }
        if didChange {
            episode.refresh.toggle()
            modelContext.saveIfNeeded()
        }
        return didChange
    }

    private func isGeneratedAdvertisementChapter(_ chapter: Marker) -> Bool {
        guard chapter.type == .ai, chapter.end != nil else { return false }
        return chapter.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Advertisement") == .orderedSame
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
    
    func downloadTranscript(_ episodeID: PersistentIdentifier, manuallyRequested: Bool = false) async throws {
        print("downloading transcript")
        let settingsActor = PodcastSettingsModelActor(modelContainer: modelContainer)
        if manuallyRequested == false, await settingsActor.getTranscriptionsEnabled() == false {
            throw TranscriptError.noTranscriptFileFound
        }

        guard let episode: Episode = modelContext.existingModel(for: episodeID) else {
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
                let transcription = await downloadAndParseStringFile(
                    url: url,
                    profile: accessProfile(for: episode)
                )
                if let transcription {
                    let snapshots = decodeTranscriptSnapshots(transcription)
                    // The episode is taken from the store again: the download
                    // above may have outlived it.
                    guard let episode: Episode = modelContext.existingModel(for: episodeID) else {
                        throw TranscriptError.episodeNotFound
                    }
                    try await replaceTranscriptLines(for: episode, with: snapshots, source: .publisher)
                    episode.refresh.toggle()
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
    func setTranscript(for episodeURL: URL, lines: [TranscriptLineAndTime]) async throws {
        guard let episode = await fetchEpisode(byURL: episodeURL) else { return }
        let snapshots = lines.map {
            TranscriptLineSnapshot(
                speaker: $0.speaker,
                text: $0.text,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
        try await replaceTranscriptLines(
            for: episode,
            with: snapshots,
            source: lines.first?.transcriptSource ?? .unknown
        )
        episode.refresh.toggle()
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
    func decodeAndSetTranscript(
        for episodeURL: URL,
        vtt: String
    ) async throws -> [TranscriptLineSnapshot] {
        print("decoding vtt")
        guard let episode = await fetchEpisode(byURL: episodeURL) else {
            throw TranscriptError.episodeNotFound
        }
        let snapshots = decodeTranscriptSnapshots(vtt)
        try await replaceTranscriptLines(for: episode, with: snapshots, source: .localAI)
        episode.refresh.toggle()
        return snapshots
    }

    private func replaceTranscriptLines(
        for episode: Episode,
        with snapshots: [TranscriptLineSnapshot],
        source: CachedTranscriptSource
    ) async throws {
        let batchSize = 100
        let episodeID = episode.persistentModelID

        // Do not touch episode.transcriptLines here. Reading or assigning the
        // relationship materializes the entire old/new graph and was the direct
        // cause of the 1.8 GB CPU-kill report. Delete through a bounded fetch.
        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<TranscriptLineAndTime>(
                predicate: #Predicate { line in
                    line.episode?.persistentModelID == episodeID
                }
            )
            descriptor.fetchLimit = batchSize
            let existing = try modelContext.fetch(descriptor)
            guard existing.isEmpty == false else { break }
            for line in existing {
                modelContext.delete(line)
            }
            try modelContext.save()
        }

        var pending = 0
        for snapshot in snapshots {
            try Task.checkCancellation()
            let line = TranscriptLineAndTime(
                speaker: snapshot.speaker,
                text: snapshot.text,
                startTime: snapshot.startTime,
                endTime: snapshot.endTime,
                source: source
            )
            // Insert first so SwiftData uses managed backing storage for the inverse
            // relationship update. Setting the relationship on an uninserted model
            // repeatedly copied the growing Episode.transcriptLines graph (O(n²)).
            modelContext.insert(line)
            line.episode = episode
            pending += 1

            if pending >= batchSize {
                try Task.checkCancellation()
                try modelContext.save()
                pending = 0
            }
        }

        if pending > 0 {
            try Task.checkCancellation()
            try modelContext.save()
        }
    }

    func transcriptLineCount() async -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<TranscriptLineAndTime>())) ?? 0
    }

#if DEBUG
    func deleteTranscript(for episodeURL: URL) async throws {
        // The singleton is initialized from the app's main-actor model container.
        // Resolve it on the main actor before crossing to this model actor; accessing
        // it here can be its first initialization and trips MainActor.assumeIsolated.
        let transcriptionManager = await MainActor.run { TranscriptionManager.shared }
        await transcriptionManager.clearTranscriptionState(for: episodeURL)

        guard let episode = await fetchEpisode(byURL: episodeURL) else {
            throw TranscriptError.episodeNotFound
        }

        let identity = episode.stableEpisodeIdentity
        try Task.checkCancellation()

        // Detaching the relationship is sufficient to make the episode eligible for
        // transcription again. Deleting every line individually updates the inverse
        // relationship once per row and becomes quadratic for long transcripts.
        episode.transcriptLines = nil

        let recordDescriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate { record in
                record.episodeURL == episodeURL
            }
        )
        for record in try modelContext.fetch(recordDescriptor) {
            modelContext.delete(record)
        }
        try modelContext.save()
        episode.refresh.toggle()

        if let cacheContainer = await preparedCacheContainer() {
            await StoreSplitAIContentSyncWriter(modelContainer: cacheContainer)
                .tombstoneTranscripts(identities: [identity])
        }
    }
#endif

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
           let cacheContainer = await preparedCacheContainer() {
            let writer = StoreSplitAIContentSyncWriter(
                modelContainer: cacheContainer
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
        finishedAt: Date,
        transcriptSnapshots: [TranscriptLineSnapshot]
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
        guard let episode = await fetchEpisode(byURL: snapshot.episodeURL) else {
            return
        }
        await writeAITranscriptToSplitStore(
            episode: episode,
            lines: transcriptSnapshots,
            localeIdentifier: localeIdentifier,
            generatedAt: finishedAt
        )
    }

    private func writeAITranscriptToSplitStore(
        episode: Episode,
        lines: [TranscriptLineSnapshot],
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
        guard let cacheContainer = await preparedCacheContainer() else { return }
        let writer = StoreSplitAIContentSyncWriter(modelContainer: cacheContainer)
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
            guard chapter.type == .ai,
                  let start = chapter.start else { return nil }
            return AIChapterValue(
                title: chapter.title,
                startTime: start,
                duration: chapter.duration,
                typeRawValue: chapter.type.rawValue,
                analysisVariantID: chapter.analysisVariantID
            )
        }
        guard values.isEmpty == false else { return }
        guard let cacheContainer = await preparedCacheContainer() else { return }
        let writer = StoreSplitAIContentSyncWriter(modelContainer: cacheContainer)
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

    private func preparedCacheContainer() async -> ModelContainer? {
        await ModelContainerManager.shared.prepareSplitStores()
        return await MainActor.run {
            ModelContainerManager.shared.preparedCacheContainer
        }
    }

    
    
    
    private func accessProfile(for episode: Episode) -> PodcastAccessProfile? {
        guard let metadata = episode.podcast?.metaData,
              let id = metadata.accessProfileID,
              let rawKind = metadata.accessKindRawValue,
              let kind = PodcastAccessKind(rawValue: rawKind),
              let feedURL = episode.podcast?.feed else { return nil }
        return PodcastAccessProfile(
            id: id,
            kind: kind,
            resourceURL: feedURL,
            providerID: metadata.accessProviderID.flatMap(PremiumPodcastProviderID.init(rawValue:))
        )
    }

    private func downloadAndParseStringFile(
        url: URL,
        profile: PodcastAccessProfile? = nil
    ) async -> String?{
        print("downloadAndParseStringFile called with: \(url.redactedPodcastURLString)")
        var stringURL = url
        do{
            let status = try await stringURL.status(profile: profile)
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
                let (data, _) = try await PodcastHTTPClient.shared.data(for: stringURL, profile: profile)
                return String(decoding: data, as: UTF8.self)
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
    let profile: PodcastAccessProfile?
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
    var profile: PodcastAccessProfile? {
        chapterFiles.first?.profile
    }
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

enum ChapterSourcePolicy {
    static func shouldExtractShownotes(from chapters: [Marker]) -> Bool {
        let timelineChapters = chapters.filter { $0.type != .soundbite }
        guard timelineChapters.isEmpty == false else { return true }

        // Publisher timestamps in the shownotes are preferable to locally
        // generated transcript chapters. Re-check shownotes when AI is the only
        // timeline source so a later feed refresh can promote those timestamps.
        if timelineChapters.allSatisfy({ $0.type == .ai || $0.type == .extracted }),
           timelineChapters.contains(where: { $0.type == .ai }) {
            return true
        }

        guard timelineChapters.allSatisfy({ $0.type == .extracted }) else { return false }
        return Set(timelineChapters.compactMap(\.start)).count < 2
    }

    static func shouldGenerateTranscriptChapters(from chapters: [Marker]) -> Bool {
        let timelineChapters = chapters.filter { $0.type != .soundbite }
        guard timelineChapters.isEmpty == false else { return true }

        // Do not overwrite a valid publisher timestamp list with a usually
        // smaller, locally generated set. Invalid legacy extractions still fall
        // through so transcript generation can repair them.
        let extractedStartTimes = Set(
            timelineChapters
                .filter { $0.type == .extracted }
                .compactMap(\.start)
        )
        return extractedStartTimes.count < 2
            && timelineChapters.allSatisfy { $0.type == .extracted || $0.type == .ai }
    }
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

    nonisolated(unsafe) static var loadRemoteMP3Chapters: (URL, PodcastAccessProfile?) async -> [Marker] = { url, profile in
        if let profile {
            guard let (data, _) = try? await PodcastHTTPClient.shared.data(for: url, profile: profile) else {
                return []
            }
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp3")
            do {
                try data.write(to: temporaryURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                guard let mp3Reader = mp3ChapterReader(with: temporaryURL) else { return [] }
                return parseMP3Chapters(from: mp3Reader.getID3Dict()) ?? []
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                return []
            }
        }

        guard let mp3Reader = await mp3ChapterReader.fromRemoteURL(url) else { return [] }
        return parseMP3Chapters(from: mp3Reader.getID3Dict()) ?? []
    }

    nonisolated(unsafe) static var loadM4AChapters: (URL, PodcastAccessProfile?) async -> [Marker] = { url, profile in
        guard let chapterData = try? await MetadataLoader.loadChapters(from: url, profile: profile) else {
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
    static func loadChapters(
        from url: URL,
        profile: PodcastAccessProfile? = nil
    ) async throws -> [SendableChapterData] {
        let asset = try authorizedAsset(for: url, profile: profile)
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

    static func getAudioFormat(
        from url: URL,
        profile: PodcastAccessProfile? = nil
    ) async throws -> AudioFormatInfo? {
        let asset = try authorizedAsset(for: url, profile: profile)
        
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

    private static func authorizedAsset(
        for url: URL,
        profile: PodcastAccessProfile?
    ) throws -> AVURLAsset {
        guard let profile else { return AVURLAsset(url: url) }
        let request = try PodcastAccessResolver().request(for: url, profile: profile)
        var options: [String: Any] = [:]
        if let authorization = request.value(forHTTPHeaderField: "Authorization") {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": authorization]
        }
        return AVURLAsset(url: request.url ?? url, options: options)
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
