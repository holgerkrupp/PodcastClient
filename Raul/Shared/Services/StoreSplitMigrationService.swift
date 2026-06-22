import Foundation
import SwiftData

struct StoreSplitMigrationResult: Sendable {
    var subscriptions = StoreSplitMigrationPhaseResult()
    var episodeStates = StoreSplitMigrationPhaseResult()
    var playlists = StoreSplitMigrationPhaseResult()
    var playlistEntries = StoreSplitMigrationPhaseResult()
    var queueEntries = StoreSplitMigrationPhaseResult()
    var bookmarks = StoreSplitMigrationPhaseResult()
    var listeningHistory = StoreSplitMigrationPhaseResult()
    var listeningSummaries = StoreSplitMigrationPhaseResult()
    var aiTranscripts = StoreSplitMigrationPhaseResult()
    var aiChapters = StoreSplitMigrationPhaseResult()

    var failedCount: Int {
        subscriptions.failed
            + episodeStates.failed
            + playlists.failed
            + playlistEntries.failed
            + queueEntries.failed
            + bookmarks.failed
            + listeningHistory.failed
            + listeningSummaries.failed
            + aiTranscripts.failed
            + aiChapters.failed
    }
}

struct StoreSplitMigrationPhaseResult: Sendable {
    var scanned = 0
    var inserted = 0
    var updated = 0
    var skipped = 0
    var failed = 0
}

actor StoreSplitMigrationService {
    nonisolated static let migrationVersion = 3
    private static let episodePageSize = 50
    private static let listeningHistoryPageSize = 10
    private static let aiContentPageSize = 10
    private static let maximumFailedItemKeys = 100

    private let legacyContainer: ModelContainer
    private let userStateContainer: ModelContainer
    private let cacheContainer: ModelContainer
    private var legacyContext: ModelContext
    private var userStateContext: ModelContext
    private var cacheContext: ModelContext
    private let includeAIContent: Bool

    private init(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer,
        includeAIContent: Bool
    ) {
        self.legacyContainer = legacyContainer
        self.userStateContainer = userStateContainer
        self.cacheContainer = cacheContainer
        self.includeAIContent = includeAIContent
        legacyContext = ModelContext(legacyContainer)
        userStateContext = ModelContext(userStateContainer)
        cacheContext = ModelContext(cacheContainer)
        legacyContext.autosaveEnabled = false
        userStateContext.autosaveEnabled = false
        cacheContext.autosaveEnabled = false
    }

    nonisolated static func migrate(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer,
        includeAIContent: Bool = true
    ) async -> StoreSplitMigrationResult {
        let worker = StoreSplitMigrationService(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer,
            includeAIContent: includeAIContent
        )
        return await worker.run()
    }

    private func run() async -> StoreSplitMigrationResult {
        var result = StoreSplitMigrationResult()

        CrashBreadcrumbs.shared.record(
            "store_split_migration_started",
            details: "version=\(Self.migrationVersion)"
        )

        result.subscriptions = Self.migrateSubscriptions(
            legacyContext: legacyContext,
            destinationContext: userStateContext
        )
        guard Task.isCancelled == false else { return result }
        Self.recordCheckpoint(
            phase: "subscriptions",
            result: result.subscriptions,
            context: cacheContext
        )
        resetWorkingContexts()
        await Task.yield()

        result.episodeStates = await migrateEpisodeStates()
        guard Task.isCancelled == false else { return result }
        resetWorkingContexts()

        let playlistResults = Self.migratePlaylists(
            legacyContext: legacyContext,
            destinationContext: userStateContext
        )
        guard Task.isCancelled == false else { return result }
        result.playlists = playlistResults.playlists
        result.playlistEntries = playlistResults.entries
        result.queueEntries = playlistResults.queueEntries
        Self.recordCheckpoint(phase: "playlists", result: result.playlists, context: cacheContext)
        Self.recordCheckpoint(phase: "playlist_entries", result: result.playlistEntries, context: cacheContext)
        Self.recordCheckpoint(phase: "queue_entries", result: result.queueEntries, context: cacheContext)
        resetWorkingContexts()
        await Task.yield()

        result.bookmarks = Self.migrateBookmarks(
            legacyContext: legacyContext,
            destinationContext: userStateContext
        )
        guard Task.isCancelled == false else { return result }
        Self.recordCheckpoint(
            phase: "bookmarks",
            result: result.bookmarks,
            context: cacheContext
        )
        resetWorkingContexts()
        await Task.yield()

        result.listeningHistory = await migrateListeningHistory()
        guard Task.isCancelled == false else { return result }
        Self.recordCheckpoint(
            phase: "listening_history",
            result: result.listeningHistory,
            context: cacheContext
        )
        resetWorkingContexts()

        result.listeningSummaries = Self.migrateListeningSummaries(
            legacyContext: legacyContext,
            destinationContext: userStateContext
        )
        guard Task.isCancelled == false else { return result }
        Self.recordCheckpoint(
            phase: "listening_summaries",
            result: result.listeningSummaries,
            context: cacheContext
        )
        resetWorkingContexts()

        if includeAIContent {
            let aiContentResults = Self.migrateAIContent(
                legacyContext: legacyContext,
                destinationContext: userStateContext
            )
            guard Task.isCancelled == false else { return result }
            result.aiTranscripts = aiContentResults.transcripts
            result.aiChapters = aiContentResults.chapters
            Self.recordCheckpoint(
                phase: "ai_transcripts",
                result: result.aiTranscripts,
                context: cacheContext
            )
            Self.recordCheckpoint(
                phase: "ai_chapters",
                result: result.aiChapters,
                context: cacheContext
            )
            resetWorkingContexts()
        } else {
            CrashBreadcrumbs.shared.record(
                "store_split_ai_migration_deferred",
                details: "reason=automatic_memory_safety"
            )
        }

        try? legacyContext.save()
        try? userStateContext.save()
        try? cacheContext.save()
        StoreSplitMigrationDiagnostics.recordMigrationRun()
        StoreSplitMigrationDiagnostics.recordFailedItems(Self.failedItemKeys(from: cacheContext))

        CrashBreadcrumbs.shared.record(
            "store_split_migration_completed",
            details: "failed=\(result.failedCount),subscriptions=\(result.subscriptions.scanned),episodes=\(result.episodeStates.scanned),playlists=\(result.playlists.scanned),bookmarks=\(result.bookmarks.scanned),history=\(result.listeningHistory.scanned),summaries=\(result.listeningSummaries.scanned),ai_transcripts=\(result.aiTranscripts.scanned),ai_chapters=\(result.aiChapters.scanned)"
        )
        return result
    }

    private func resetWorkingContexts() {
        legacyContext = Self.makeContext(for: legacyContainer)
        userStateContext = Self.makeContext(for: userStateContainer)
        cacheContext = Self.makeContext(for: cacheContainer)
    }

    private static func makeContext(for container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private static func migrateAIContent(
        legacyContext: ModelContext,
        destinationContext: ModelContext
    ) -> (
        transcripts: StoreSplitMigrationPhaseResult,
        chapters: StoreSplitMigrationPhaseResult
    ) {
        var transcriptResult = StoreSplitMigrationPhaseResult()
        var chapterResult = StoreSplitMigrationPhaseResult()
        let records = (try? legacyContext.fetch(FetchDescriptor<TranscriptionRecord>())) ?? []
        let latestRecordByEpisodeURL = records.reduce(
            into: [URL: TranscriptionRecord]()
        ) { result, record in
            guard let episodeURL = record.episodeURL else { return }
            if let existing = result[episodeURL], existing.finishedAt >= record.finishedAt {
                return
            }
            result[episodeURL] = record
        }
        var transcriptsByID = ((try? destinationContext.fetch(FetchDescriptor<AITranscriptSync>())) ?? [])
            .reduce(into: [String: AITranscriptSync]()) { $0[$1.id] = $1 }
        var chapterSetsByID = ((try? destinationContext.fetch(FetchDescriptor<AIChapterSetSync>())) ?? [])
            .reduce(into: [String: AIChapterSetSync]()) { $0[$1.id] = $1 }
        let sourceDeviceID = ListeningDeviceIdentity.current().id

        for (episodeURL, record) in latestRecordByEpisodeURL {
            transcriptResult.scanned += 1
            let episodeDescriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.url == episodeURL }
            )
            guard let episode = try? legacyContext.fetch(episodeDescriptor).first,
                  let lines = episode.transcriptLines,
                  lines.isEmpty == false else {
                transcriptResult.skipped += 1
                continue
            }

            do {
                let identity = episode.stableEpisodeIdentity
                let values = lines.map {
                    AITranscriptLineValue(
                        speaker: $0.speaker,
                        text: $0.text,
                        startTime: $0.startTime,
                        endTime: $0.endTime
                    )
                }
                let encoded = try AIContentSyncCodec.encodeTranscript(values)

                for (index, payload) in encoded.chunks.enumerated() {
                    let chunkID = StableIdentityKey.make(
                        identity.key,
                        encoded.revisionID,
                        String(index)
                    )
                    let chunkDescriptor = FetchDescriptor<AITranscriptChunkSync>(
                        predicate: #Predicate<AITranscriptChunkSync> { $0.id == chunkID }
                    )
                    if (try? destinationContext.fetch(chunkDescriptor).first) == nil {
                        let chunk = AITranscriptChunkSync(
                            transcriptID: identity.key,
                            revisionID: encoded.revisionID,
                            chunkIndex: index,
                            payloadJSON: payload,
                            contentHash: AIContentSyncCodec.sha256Hex(Data(payload.utf8)),
                            updatedAt: record.finishedAt
                        )
                        destinationContext.insert(chunk)
                    }
                }

                if let transcript = transcriptsByID[identity.key] {
                    guard record.finishedAt > transcript.updatedAt else {
                        transcriptResult.skipped += 1
                        continue
                    }
                    transcript.revisionID = encoded.revisionID
                    transcript.localeIdentifier = record.localeIdentifier
                    transcript.chunkCount = encoded.chunks.count
                    transcript.lineCount = encoded.lineCount
                    transcript.contentHash = encoded.contentHash
                    transcript.generatedAt = record.finishedAt
                    transcript.deletedAt = nil
                    transcript.updatedAt = record.finishedAt
                    transcript.sourceDeviceID = sourceDeviceID
                    transcriptResult.updated += 1
                } else {
                    let transcript = AITranscriptSync(
                        feedURL: identity.feedURL,
                        episodeID: identity.episodeID,
                        revisionID: encoded.revisionID,
                        localeIdentifier: record.localeIdentifier,
                        chunkCount: encoded.chunks.count,
                        lineCount: encoded.lineCount,
                        contentHash: encoded.contentHash,
                        generatedAt: record.finishedAt,
                        deletedAt: nil,
                        updatedAt: record.finishedAt,
                        sourceDeviceID: sourceDeviceID
                    )
                    destinationContext.insert(transcript)
                    transcriptsByID[identity.key] = transcript
                    transcriptResult.inserted += 1
                }
            } catch {
                transcriptResult.failed += 1
            }
        }
        save(destinationContext, result: &transcriptResult)

        var episodeOffset = 0
        while true {
            guard Task.isCancelled == false else { break }
            var descriptor = FetchDescriptor<Episode>(
                sortBy: [SortDescriptor(\Episode.publishDate)]
            )
            descriptor.fetchLimit = aiContentPageSize
            descriptor.fetchOffset = episodeOffset
            guard let episodes = try? legacyContext.fetch(descriptor),
                  episodes.isEmpty == false else {
                break
            }

            for episode in episodes {
                let aiChapters = (episode.chapters ?? []).filter { $0.type == .ai }
                guard aiChapters.isEmpty == false else { continue }
                chapterResult.scanned += 1

                do {
                    let identity = episode.stableEpisodeIdentity
                    let values = aiChapters.compactMap { chapter -> AIChapterValue? in
                        guard let start = chapter.start else { return nil }
                        return AIChapterValue(
                            title: chapter.title,
                            startTime: start,
                            duration: chapter.duration
                        )
                    }
                    guard values.isEmpty == false else {
                        chapterResult.skipped += 1
                        continue
                    }
                    let encoded = try AIContentSyncCodec.encodeChapters(values)
                    let generatedAt = aiChapters.compactMap(\.creationtime).max() ?? .distantPast

                    if let chapterSet = chapterSetsByID[identity.key] {
                        guard generatedAt > chapterSet.updatedAt else {
                            chapterResult.skipped += 1
                            continue
                        }
                        chapterSet.revisionID = encoded.hash
                        chapterSet.payloadJSON = encoded.payload
                        chapterSet.chapterCount = values.count
                        chapterSet.contentHash = encoded.hash
                        chapterSet.generatedAt = generatedAt
                        chapterSet.updatedAt = generatedAt
                        chapterSet.sourceDeviceID = sourceDeviceID
                        chapterResult.updated += 1
                    } else {
                        let chapterSet = AIChapterSetSync(
                            feedURL: identity.feedURL,
                            episodeID: identity.episodeID,
                            revisionID: encoded.hash,
                            payloadJSON: encoded.payload,
                            chapterCount: values.count,
                            contentHash: encoded.hash,
                            generatedAt: generatedAt,
                            updatedAt: generatedAt,
                            sourceDeviceID: sourceDeviceID
                        )
                        destinationContext.insert(chapterSet)
                        chapterSetsByID[identity.key] = chapterSet
                        chapterResult.inserted += 1
                    }
                } catch {
                    chapterResult.failed += 1
                }
            }

            save(destinationContext, result: &chapterResult)
            episodeOffset += episodes.count
            if episodes.count < aiContentPageSize {
                break
            }
        }

        save(destinationContext, result: &chapterResult)
        return (transcriptResult, chapterResult)
    }

    private static func migrateSubscriptions(
        legacyContext: ModelContext,
        destinationContext: ModelContext
    ) -> StoreSplitMigrationPhaseResult {
        var result = StoreSplitMigrationPhaseResult()
        let existing = ((try? destinationContext.fetch(FetchDescriptor<SubscriptionSync>())) ?? [])
            .reduce(into: [String: SubscriptionSync]()) { $0[$1.id] = $1 }
        var recordsByID = existing
        let podcasts = (try? legacyContext.fetch(FetchDescriptor<Podcast>())) ?? []

        for podcast in podcasts {
            result.scanned += 1
            guard let feed = podcast.feed else {
                result.failed += 1
                continue
            }

            let feedURL = PodcastFeedIdentity.normalizedFeedURLString(feed)
            let metadata = podcast.metaData
            let subscribedAt = metadata?.subscriptionDate ?? .distantPast
            let isSubscribed = metadata?.isSubscribed != false
            // Feed refresh timestamps are cache activity, not subscription edits.
            let updatedAt = metadata?.subscriptionDate ?? .distantPast

            if let destination = recordsByID[feedURL] {
                guard StoreSplitMergePolicy.prefersIncoming(
                    existingUpdatedAt: destination.updatedAt,
                    incomingUpdatedAt: updatedAt
                ) else {
                    result.skipped += 1
                    continue
                }

                destination.feedURL = feedURL
                destination.isSubscribed = isSubscribed
                destination.subscribedAt = subscribedAt
                destination.unsubscribedAt = isSubscribed ? nil : updatedAt
                destination.updatedAt = updatedAt
                result.updated += 1
            } else {
                let destination = SubscriptionSync(
                    feedURL: feedURL,
                    isSubscribed: isSubscribed,
                    subscribedAt: subscribedAt,
                    unsubscribedAt: isSubscribed ? nil : updatedAt,
                    updatedAt: updatedAt
                )
                destinationContext.insert(destination)
                recordsByID[feedURL] = destination
                result.inserted += 1
            }
        }

        save(destinationContext, result: &result)
        return result
    }

    private func migrateEpisodeStates() async -> StoreSplitMigrationPhaseResult {
        let resume = Self.resumeProgress(
            phase: "episode_states",
            context: cacheContext
        )
        var result = resume.result
        var offset = resume.offset
        var completed = true

        while true {
            guard Task.isCancelled == false else {
                completed = false
                break
            }
            var descriptor = FetchDescriptor<Episode>(
                sortBy: [SortDescriptor(\Episode.publishDate)]
            )
            descriptor.fetchLimit = Self.episodePageSize
            descriptor.fetchOffset = offset

            let episodes: [Episode]
            do {
                episodes = try legacyContext.fetch(descriptor)
            } catch {
                result.failed += 1
                completed = false
                Self.recordCheckpoint(
                    phase: "episode_states",
                    result: result,
                    cursor: String(offset),
                    completed: false,
                    error: error.localizedDescription,
                    context: cacheContext
                )
                break
            }

            guard episodes.isEmpty == false else { break }

            for episode in episodes {
                result.scanned += 1
                guard let metadata = episode.metaData,
                      episode.podcast?.feed != nil else {
                    result.skipped += 1
                    continue
                }

                let isPlayed = metadata.isHistory == true
                    || metadata.status == .history
                    || metadata.completionDate != nil
                let isArchived = metadata.isArchived == true || metadata.status == .archived
                let hasMeaningfulState = (metadata.playPosition ?? 0) > 0
                    || (metadata.maxPlayposition ?? 0) > 0
                    || isPlayed
                    || isArchived
                    || metadata.wasSkipped
                    || metadata.firstListenDate != nil
                    || metadata.lastPlayed != nil

                guard hasMeaningfulState else {
                    result.skipped += 1
                    continue
                }

                let identity = episode.stableEpisodeIdentity
                let updatedAt = Self.latestDate(
                    metadata.lastPlayed,
                    metadata.completionDate,
                    metadata.archivedAt,
                    metadata.firstListenDate
                ) ?? .distantPast

                let stateID = identity.key
                let destinationDescriptor = FetchDescriptor<EpisodeStateSync>(
                    predicate: #Predicate<EpisodeStateSync> { $0.id == stateID }
                )
                if let destination = try? userStateContext.fetch(
                    destinationDescriptor
                ).first {
                    guard StoreSplitMergePolicy.prefersIncoming(
                        existingUpdatedAt: destination.updatedAt,
                        incomingUpdatedAt: updatedAt
                    ) else {
                        result.skipped += 1
                        continue
                    }

                    Self.applyEpisodeState(
                        metadata: metadata,
                        episode: episode,
                        identity: identity,
                        isPlayed: isPlayed,
                        isArchived: isArchived,
                        updatedAt: updatedAt,
                        to: destination
                    )
                    result.updated += 1
                } else {
                    let destination = EpisodeStateSync(
                        feedURL: identity.feedURL,
                        episodeID: identity.episodeID,
                        playPosition: metadata.playPosition ?? 0,
                        maxPlayPosition: metadata.maxPlayposition ?? 0,
                        duration: episode.duration,
                        isPlayed: isPlayed,
                        isArchived: isArchived,
                        wasSkipped: metadata.wasSkipped,
                        completedAt: metadata.completionDate,
                        archivedAt: metadata.archivedAt,
                        firstPlayedAt: metadata.firstListenDate,
                        lastPlayedAt: metadata.lastPlayed,
                        updatedAt: updatedAt
                    )
                    userStateContext.insert(destination)
                    result.inserted += 1
                }
            }

            Self.save(userStateContext, result: &result)
            offset += episodes.count
            Self.recordCheckpoint(
                phase: "episode_states",
                result: result,
                cursor: String(offset),
                completed: false,
                context: cacheContext
            )
            resetWorkingContexts()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))

            if episodes.count < Self.episodePageSize {
                break
            }
        }

        Self.recordCheckpoint(
            phase: "episode_states",
            result: result,
            cursor: String(offset),
            completed: completed,
            context: cacheContext
        )
        return result
    }

    private static func applyEpisodeState(
        metadata: EpisodeMetaData,
        episode: Episode,
        identity: EpisodeStableIdentity,
        isPlayed: Bool,
        isArchived: Bool,
        updatedAt: Date,
        to destination: EpisodeStateSync
    ) {
        destination.feedURL = identity.feedURL
        destination.episodeID = identity.episodeID
        destination.playPosition = metadata.playPosition ?? 0
        destination.maxPlayPosition = max(
            destination.maxPlayPosition,
            metadata.maxPlayposition ?? 0
        )
        destination.duration = episode.duration ?? destination.duration
        destination.isPlayed = isPlayed
        destination.isArchived = isArchived
        destination.wasSkipped = metadata.wasSkipped
        destination.completedAt = metadata.completionDate
        destination.archivedAt = metadata.archivedAt
        destination.firstPlayedAt = metadata.firstListenDate
        destination.lastPlayedAt = metadata.lastPlayed
        destination.updatedAt = updatedAt
    }

    private static func migratePlaylists(
        legacyContext: ModelContext,
        destinationContext: ModelContext
    ) -> (
        playlists: StoreSplitMigrationPhaseResult,
        entries: StoreSplitMigrationPhaseResult,
        queueEntries: StoreSplitMigrationPhaseResult
    ) {
        var playlistResult = StoreSplitMigrationPhaseResult()
        var entryResult = StoreSplitMigrationPhaseResult()
        var queueResult = StoreSplitMigrationPhaseResult()
        var playlistsByID = ((try? destinationContext.fetch(FetchDescriptor<PlaylistSync>())) ?? [])
            .reduce(into: [String: PlaylistSync]()) { $0[$1.id] = $1 }
        var entriesByID = ((try? destinationContext.fetch(FetchDescriptor<PlaylistEntrySync>())) ?? [])
            .reduce(into: [String: PlaylistEntrySync]()) { $0[$1.id] = $1 }
        var queueByID = ((try? destinationContext.fetch(FetchDescriptor<QueueEntrySync>())) ?? [])
            .reduce(into: [String: QueueEntrySync]()) { $0[$1.id] = $1 }
        let playlists = (try? legacyContext.fetch(FetchDescriptor<Playlist>())) ?? []

        for playlist in playlists {
            playlistResult.scanned += 1
            let playlistID = playlist.id.uuidString
            let entryDates = playlist.ordered.compactMap(\.dateAdded)
            let createdAt = entryDates.min() ?? .distantPast
            let updatedAt = entryDates.max() ?? createdAt
            let smartFilterRawValue = playlist.smartFilter.flatMap {
                try? JSONEncoder().encode($0)
            }.flatMap {
                String(data: $0, encoding: .utf8)
            }

            if let destination = playlistsByID[playlistID] {
                if StoreSplitMergePolicy.prefersIncoming(
                    existingUpdatedAt: destination.updatedAt,
                    incomingUpdatedAt: updatedAt
                ) {
                    destination.title = playlist.title
                    destination.symbolName = playlist.symbolName
                    destination.sortIndex = playlist.sortIndex
                    destination.kindRawValue = playlist.kindRawValue
                    destination.smartFilterRawValue = smartFilterRawValue
                    destination.isHidden = playlist.hidden
                    destination.updatedAt = updatedAt
                    playlistResult.updated += 1
                } else {
                    playlistResult.skipped += 1
                }
            } else {
                let destination = PlaylistSync(
                    id: playlistID,
                    title: playlist.title,
                    symbolName: playlist.symbolName,
                    sortIndex: playlist.sortIndex,
                    kindRawValue: playlist.kindRawValue,
                    smartFilterRawValue: smartFilterRawValue,
                    isHidden: playlist.hidden,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
                destinationContext.insert(destination)
                playlistsByID[playlistID] = destination
                playlistResult.inserted += 1
            }

            for entry in playlist.ordered {
                entryResult.scanned += 1
                guard let episode = entry.episode,
                      episode.podcast?.feed != nil else {
                    entryResult.skipped += 1
                    if playlist.title == Playlist.defaultQueueTitle {
                        queueResult.scanned += 1
                        queueResult.skipped += 1
                    }
                    continue
                }

                let identity = episode.stableEpisodeIdentity
                let addedAt = entry.dateAdded ?? .distantPast
                let entryID = StableIdentityKey.make(
                    playlistID,
                    identity.feedURL,
                    identity.episodeID
                )
                upsertPlaylistEntry(
                    id: entryID,
                    playlistID: playlistID,
                    identity: identity,
                    sortIndex: entry.order,
                    addedAt: addedAt,
                    destinationContext: destinationContext,
                    recordsByID: &entriesByID,
                    result: &entryResult
                )

                if playlist.title == Playlist.defaultQueueTitle {
                    queueResult.scanned += 1
                    upsertQueueEntry(
                        identity: identity,
                        sortIndex: entry.order,
                        addedAt: addedAt,
                        destinationContext: destinationContext,
                        recordsByID: &queueByID,
                        result: &queueResult
                    )
                }
            }
        }

        save(destinationContext, result: &playlistResult)
        return (playlistResult, entryResult, queueResult)
    }

    private static func upsertPlaylistEntry(
        id: String,
        playlistID: String,
        identity: EpisodeStableIdentity,
        sortIndex: Int,
        addedAt: Date,
        destinationContext: ModelContext,
        recordsByID: inout [String: PlaylistEntrySync],
        result: inout StoreSplitMigrationPhaseResult
    ) {
        if let destination = recordsByID[id] {
            guard StoreSplitMergePolicy.prefersIncoming(
                existingUpdatedAt: destination.updatedAt,
                incomingUpdatedAt: addedAt
            ) else {
                result.skipped += 1
                return
            }
            destination.sortIndex = sortIndex
            destination.addedAt = addedAt
            destination.isDeleted = false
            destination.deletedAt = nil
            destination.updatedAt = addedAt
            result.updated += 1
        } else {
            let destination = PlaylistEntrySync(
                playlistID: playlistID,
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                sortIndex: sortIndex,
                addedAt: addedAt,
                updatedAt: addedAt
            )
            destinationContext.insert(destination)
            recordsByID[id] = destination
            result.inserted += 1
        }
    }

    private static func upsertQueueEntry(
        identity: EpisodeStableIdentity,
        sortIndex: Int,
        addedAt: Date,
        destinationContext: ModelContext,
        recordsByID: inout [String: QueueEntrySync],
        result: inout StoreSplitMigrationPhaseResult
    ) {
        if let destination = recordsByID[identity.key] {
            guard StoreSplitMergePolicy.prefersIncoming(
                existingUpdatedAt: destination.updatedAt,
                incomingUpdatedAt: addedAt
            ) else {
                result.skipped += 1
                return
            }
            destination.sortIndex = sortIndex
            destination.addedAt = addedAt
            destination.isDeleted = false
            destination.deletedAt = nil
            destination.updatedAt = addedAt
            result.updated += 1
        } else {
            let destination = QueueEntrySync(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                sortIndex: sortIndex,
                addedAt: addedAt,
                updatedAt: addedAt
            )
            destinationContext.insert(destination)
            recordsByID[identity.key] = destination
            result.inserted += 1
        }
    }

    private static func migrateBookmarks(
        legacyContext: ModelContext,
        destinationContext: ModelContext
    ) -> StoreSplitMigrationPhaseResult {
        var result = StoreSplitMigrationPhaseResult()
        var recordsByID = ((try? destinationContext.fetch(FetchDescriptor<BookmarkSync>())) ?? [])
            .reduce(into: [String: BookmarkSync]()) { $0[$1.id] = $1 }
        let bookmarks = (try? legacyContext.fetch(FetchDescriptor<Bookmark>())) ?? []

        for bookmark in bookmarks {
            result.scanned += 1
            guard let episode = bookmark.bookmarkEpisode,
                  episode.podcast?.feed != nil else {
                result.skipped += 1
                continue
            }

            let identity = episode.stableEpisodeIdentity
            let createdAt = bookmark.creationtime ?? .distantPast
            let bookmarkID = bookmark.uuid?.uuidString ?? StableIdentityKey.make(
                "legacy-bookmark",
                identity.key,
                String(bookmark.start ?? 0),
                bookmark.title,
                String(createdAt.timeIntervalSince1970)
            )

            if let destination = recordsByID[bookmarkID] {
                guard StoreSplitMergePolicy.prefersIncoming(
                    existingUpdatedAt: destination.updatedAt,
                    incomingUpdatedAt: createdAt
                ) else {
                    result.skipped += 1
                    continue
                }
                destination.feedURL = identity.feedURL
                destination.episodeID = identity.episodeID
                destination.time = bookmark.start ?? 0
                destination.title = bookmark.title
                destination.createdAt = createdAt
                destination.updatedAt = createdAt
                result.updated += 1
            } else {
                let destination = BookmarkSync(
                    id: bookmarkID,
                    feedURL: identity.feedURL,
                    episodeID: identity.episodeID,
                    time: bookmark.start ?? 0,
                    title: bookmark.title,
                    createdAt: createdAt,
                    updatedAt: createdAt
                )
                destinationContext.insert(destination)
                recordsByID[bookmarkID] = destination
                result.inserted += 1
            }
        }

        save(destinationContext, result: &result)
        return result
    }

    private func migrateListeningHistory() async -> StoreSplitMigrationPhaseResult {
        let resume = Self.resumeProgress(
            phase: "listening_history",
            context: cacheContext
        )
        var result = resume.result
        var offset = resume.offset

        while true {
            guard Task.isCancelled == false else { break }
            var descriptor = FetchDescriptor<PlaySession>(
                sortBy: [SortDescriptor(\PlaySession.startTime)]
            )
            descriptor.fetchLimit = Self.listeningHistoryPageSize
            descriptor.fetchOffset = offset
            let sessions = (try? legacyContext.fetch(descriptor)) ?? []
            guard sessions.isEmpty == false else { break }

            for session in sessions {
                result.scanned += 1
                guard let episode = session.episode,
                      episode.podcast?.feed != nil,
                      let startedAt = session.startTime,
                      let endedAt = session.endTime,
                      endedAt > startedAt else {
                    result.skipped += 1
                    continue
                }

                let identity = episode.stableEpisodeIdentity
                let sourceDeviceID = session.sourceDeviceID ?? Self.legacyDeviceID(
                    deviceModel: session.deviceModel,
                    osVersion: session.osVersion
                )
                let sourceDeviceName = session.sourceDeviceName
                    ?? session.deviceModel
                    ?? "Legacy device"
                let recordID = ListeningHistoryIdentity.make(
                    feedURL: identity.feedURL,
                    episodeID: identity.episodeID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    startPosition: session.startPosition ?? 0,
                    endPosition: session.endPosition ?? 0,
                )
                let listenedSeconds = endedAt.timeIntervalSince(startedAt)
                let updatedAt = endedAt
                let destinationDescriptor = FetchDescriptor<ListeningHistorySync>(
                    predicate: #Predicate<ListeningHistorySync> { $0.id == recordID }
                )

                if let destination = try? userStateContext.fetch(
                    destinationDescriptor
                ).first {
                    guard StoreSplitMergePolicy.prefersIncoming(
                        existingUpdatedAt: destination.updatedAt,
                        incomingUpdatedAt: updatedAt
                    ) else {
                        result.skipped += 1
                        continue
                    }
                    Self.applyListeningHistory(
                        session: session,
                        episode: episode,
                        identity: identity,
                        sourceDeviceID: sourceDeviceID,
                        sourceDeviceName: sourceDeviceName,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        listenedSeconds: listenedSeconds,
                        updatedAt: updatedAt,
                        to: destination
                    )
                    result.updated += 1
                } else {
                    userStateContext.insert(
                        ListeningHistorySync(
                            id: recordID,
                            feedURL: identity.feedURL,
                            episodeID: identity.episodeID,
                            podcastName: session.podcastName ?? episode.displayPodcastTitle,
                            episodeTitle: episode.title,
                            sourceDeviceID: sourceDeviceID,
                            sourceDeviceName: sourceDeviceName,
                            deviceModel: session.deviceModel,
                            startedAt: startedAt,
                            endedAt: endedAt,
                            startPosition: session.startPosition ?? 0,
                            endPosition: session.endPosition ?? 0,
                            listenedSeconds: listenedSeconds,
                            silenceGapTimeSavedSeconds:
                                session.silenceGapTimeSavedSeconds ?? 0,
                            playbackRateTimeSavedSeconds:
                                PlaybackRateSavingsCalculator.secondsSaved(in: session),
                            endedCleanly: session.endedCleanly == true,
                            updatedAt: updatedAt
                        )
                    )
                    result.inserted += 1
                }
            }

            Self.save(userStateContext, result: &result)
            offset += sessions.count
            Self.recordCheckpoint(
                phase: "listening_history",
                result: result,
                cursor: String(offset),
                completed: false,
                context: cacheContext
            )
            resetWorkingContexts()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(100))
        }

        return result
    }

    private static func applyListeningHistory(
        session: PlaySession,
        episode: Episode,
        identity: EpisodeStableIdentity,
        sourceDeviceID: String,
        sourceDeviceName: String,
        startedAt: Date,
        endedAt: Date,
        listenedSeconds: Double,
        updatedAt: Date,
        to destination: ListeningHistorySync
    ) {
        destination.feedURL = identity.feedURL
        destination.episodeID = identity.episodeID
        destination.podcastName = session.podcastName ?? episode.displayPodcastTitle
        destination.episodeTitle = episode.title
        destination.sourceDeviceID = sourceDeviceID
        destination.sourceDeviceName = sourceDeviceName
        destination.deviceModel = session.deviceModel
        destination.startedAt = startedAt
        destination.endedAt = endedAt
        destination.startPosition = session.startPosition ?? 0
        destination.endPosition = session.endPosition ?? 0
        destination.listenedSeconds = listenedSeconds
        destination.silenceGapTimeSavedSeconds = session.silenceGapTimeSavedSeconds ?? 0
        destination.playbackRateTimeSavedSeconds = PlaybackRateSavingsCalculator.secondsSaved(in: session)
        destination.endedCleanly = session.endedCleanly == true
        destination.updatedAt = updatedAt
    }

    private struct LegacySummaryKey: Hashable {
        let feedURL: String
        let periodKind: String
        let periodStart: Date
    }

    private struct LegacySummaryValue {
        var podcastName: String?
        var totalSeconds = 0.0
        var silenceGapTimeSavedSeconds = 0.0
        var playbackRateTimeSavedSeconds = 0.0
        var activeHourCount = 0
        var seenRecordIDs = Set<String>()
    }

    private static func migrateListeningSummaries(
        legacyContext: ModelContext,
        destinationContext: ModelContext
    ) -> StoreSplitMigrationPhaseResult {
        var result = StoreSplitMigrationPhaseResult()
        let legacySummaries = (try? legacyContext.fetch(FetchDescriptor<PlaySessionSummary>())) ?? []
        var aggregates: [LegacySummaryKey: LegacySummaryValue] = [:]

        for summary in legacySummaries {
            result.scanned += 1
            guard let periodKind = summary.periodKind,
                  let periodStart = summary.periodStart else {
                result.skipped += 1
                continue
            }

            let feedURL = summary.podcastFeed
                .map(PodcastFeedIdentity.normalizedFeedURLString)
                ?? "__all_podcasts__"
            let key = LegacySummaryKey(
                feedURL: feedURL,
                periodKind: periodKind,
                periodStart: periodStart
            )
            let recordID = summary.id?.uuidString ?? StableIdentityKey.make(
                feedURL,
                periodKind,
                String(periodStart.timeIntervalSince1970),
                summary.podcastName ?? ""
            )
            guard aggregates[key]?.seenRecordIDs.contains(recordID) != true else {
                result.skipped += 1
                continue
            }

            var value = aggregates[key] ?? LegacySummaryValue()
            value.seenRecordIDs.insert(recordID)
            value.podcastName = summary.podcastName ?? value.podcastName
            value.totalSeconds += max(0, summary.totalSeconds ?? 0)
            value.silenceGapTimeSavedSeconds += max(0, summary.silenceGapTimeSavedSeconds ?? 0)
            value.playbackRateTimeSavedSeconds += max(0, summary.playbackRateTimeSavedSeconds ?? 0)
            value.activeHourCount += max(0, summary.activeHourCount ?? 0)
            aggregates[key] = value
        }

        var recordsByID = ((try? destinationContext.fetch(FetchDescriptor<ListeningSummarySync>())) ?? [])
            .reduce(into: [String: ListeningSummarySync]()) { $0[$1.id] = $1 }

        for (key, value) in aggregates {
            let candidate = ListeningSummarySync(
                feedURL: key.feedURL,
                periodKind: key.periodKind,
                periodStart: key.periodStart,
                sourceDeviceID: ListeningDeviceIdentity.legacySharedID,
                sourceDeviceName: "Migrated history",
                podcastName: value.podcastName,
                totalSeconds: value.totalSeconds,
                silenceGapTimeSavedSeconds: value.silenceGapTimeSavedSeconds,
                playbackRateTimeSavedSeconds: value.playbackRateTimeSavedSeconds,
                activeHourCount: value.activeHourCount,
                updatedAt: .now
            )

            if let destination = recordsByID[candidate.id] {
                // Partial CloudKit imports may reveal additional legacy summaries later.
                let totalSeconds = max(destination.totalSeconds, candidate.totalSeconds)
                let silenceGapTimeSavedSeconds = max(
                    destination.silenceGapTimeSavedSeconds,
                    candidate.silenceGapTimeSavedSeconds
                )
                let playbackRateTimeSavedSeconds = max(
                    destination.playbackRateTimeSavedSeconds,
                    candidate.playbackRateTimeSavedSeconds
                )
                let activeHourCount = max(
                    destination.activeHourCount,
                    candidate.activeHourCount
                )
                let podcastName = candidate.podcastName ?? destination.podcastName
                let changed = totalSeconds != destination.totalSeconds
                    || silenceGapTimeSavedSeconds != destination.silenceGapTimeSavedSeconds
                    || playbackRateTimeSavedSeconds != destination.playbackRateTimeSavedSeconds
                    || activeHourCount != destination.activeHourCount
                    || podcastName != destination.podcastName

                if changed {
                    destination.totalSeconds = totalSeconds
                    destination.silenceGapTimeSavedSeconds = silenceGapTimeSavedSeconds
                    destination.playbackRateTimeSavedSeconds = playbackRateTimeSavedSeconds
                    destination.activeHourCount = activeHourCount
                    destination.podcastName = podcastName
                    destination.updatedAt = .now
                    result.updated += 1
                } else {
                    result.skipped += 1
                }
            } else {
                destinationContext.insert(candidate)
                recordsByID[candidate.id] = candidate
                result.inserted += 1
            }
        }

        save(destinationContext, result: &result)
        return result
    }

    private static func legacyDeviceID(
        deviceModel: String?,
        osVersion: String?
    ) -> String {
        StableIdentityKey.make(
            "legacy-device",
            deviceModel ?? "unknown-model",
            osVersion ?? "unknown-os"
        )
    }

    private static func recordCheckpoint(
        phase: String,
        result: StoreSplitMigrationPhaseResult,
        cursor: String? = nil,
        completed: Bool = true,
        error: String? = nil,
        context: ModelContext
    ) {
        let checkpointID = "v\(migrationVersion).\(phase)"
        let descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(
            predicate: #Predicate { $0.id == checkpointID }
        )
        let checkpoint = (try? context.fetch(descriptor).first)
            ?? StoreSplitMigrationCheckpoint(
                id: checkpointID,
                migrationVersion: migrationVersion,
                phase: phase,
                startedAt: .now
            )

        if checkpoint.modelContext == nil {
            context.insert(checkpoint)
        }
        checkpoint.cursor = cursor
        checkpoint.completedAt = completed ? .now : nil
        checkpoint.scannedCount = result.scanned
        checkpoint.insertedCount = result.inserted
        checkpoint.updatedCount = result.updated
        checkpoint.skippedCount = result.skipped
        checkpoint.failedCount = result.failed
        checkpoint.lastError = error
        checkpoint.updatedAt = .now
        try? context.save()
    }

    private static func resumeProgress(
        phase: String,
        context: ModelContext
    ) -> (offset: Int, result: StoreSplitMigrationPhaseResult) {
        let checkpointID = "v\(migrationVersion).\(phase)"
        let descriptor = FetchDescriptor<StoreSplitMigrationCheckpoint>(
            predicate: #Predicate { $0.id == checkpointID }
        )
        guard let checkpoint = try? context.fetch(descriptor).first,
              checkpoint.completedAt == nil,
              let cursor = checkpoint.cursor,
              let offset = Int(cursor) else {
            return (0, StoreSplitMigrationPhaseResult())
        }
        return (
            max(0, offset),
            StoreSplitMigrationPhaseResult(
                scanned: checkpoint.scannedCount,
                inserted: checkpoint.insertedCount,
                updated: checkpoint.updatedCount,
                skipped: checkpoint.skippedCount,
                failed: checkpoint.failedCount
            )
        )
    }

    private static func failedItemKeys(from context: ModelContext) -> [String] {
        let checkpoints = (try? context.fetch(FetchDescriptor<StoreSplitMigrationCheckpoint>())) ?? []
        return Array(
            checkpoints
                .filter { $0.failedCount > 0 }
                .map { "\($0.phase):\($0.lastError ?? "failed=\($0.failedCount)")" }
                .prefix(maximumFailedItemKeys)
        )
    }

    private static func save(
        _ context: ModelContext,
        result: inout StoreSplitMigrationPhaseResult
    ) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            result.failed += 1
            CrashBreadcrumbs.shared.record(
                "store_split_migration_save_failed",
                details: error.localizedDescription
            )
        }
    }

    private static func latestDate(_ dates: Date?...) -> Date? {
        dates.compactMap { $0 }.max()
    }
}
