import Foundation
import SwiftData

/// Copies the small cache-only local ledgers into the durable local library.
/// The cache remains intact as a recovery source. Rows are upserted by stable
/// identity and each page is saved independently, so an interrupted pass can
/// safely resume on the next launch.
enum StoreSplitCacheLocalDataMigration {
    private static let completedKey = "storeSplit.cacheLocalDataMigration.v1"
    private static let pageSize = 200

    static var isComplete: Bool {
        let defaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
        return defaults.bool(forKey: completedKey)
    }

    @discardableResult
    static func migrateIfNeeded(
        cache: ModelContainer?,
        library: ModelContainer,
        defaults: UserDefaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    ) -> Bool {
        guard let cache else { return false }
        guard defaults.bool(forKey: completedKey) == false else { return true }

        do {
            try migrateMissingEpisodeReferences(from: cache, to: library)
            try migrateTranscriptAlignments(from: cache, to: library)
            try migrateTranscriptJobs(from: cache, to: library)
            try migrateTranscriptionRecords(from: cache, to: library)
            guard try migrateLocalDetails(from: cache, to: library) else { return false }
            defaults.set(true, forKey: completedKey)
            CrashBreadcrumbs.shared.record("cache_local_data_migration_completed")
            return true
        } catch {
            CrashBreadcrumbs.shared.record("cache_local_data_migration_deferred")
            return false
        }
    }

    private static func migrateTranscriptionRecords(
        from cache: ModelContainer,
        to library: ModelContainer
    ) throws {
        let source = ModelContext(cache)
        let destination = ModelContext(library)
        var offset = 0
        while true {
            var page = FetchDescriptor<CachedTranscriptionRecord>(
                sortBy: [SortDescriptor(\.id)]
            )
            page.fetchOffset = offset
            page.fetchLimit = pageSize
            let rows = try source.fetch(page)
            guard rows.isEmpty == false else { break }
            for row in rows {
                guard let id = UUID(uuidString: row.id), let episodeURL = row.episodeURL else {
                    continue
                }
                var descriptor = FetchDescriptor<TranscriptionRecord>(
                    predicate: #Predicate { $0.id == id }
                )
                descriptor.fetchLimit = 1
                if try destination.fetch(descriptor).first != nil { continue }
                let record = TranscriptionRecord(
                    episodeURL: episodeURL,
                    episodeTitle: row.episodeTitle,
                    podcastTitle: row.podcastTitle,
                    localeIdentifier: row.localeIdentifier,
                    startedAt: row.startedAt,
                    finishedAt: row.finishedAt,
                    audioDuration: row.audioDuration
                )
                record.id = id
                record.transcriptionDuration = row.transcriptionDuration
                destination.insert(record)
            }
            try destination.save()
            offset += rows.count
            if rows.count < pageSize { break }
        }
    }

    /// Local settings and bookmark details have canonical fields on the
    /// corresponding SharedDatabase models. Existing canonical values win;
    /// cache rows are retired only after the library save succeeds.
    private static func migrateLocalDetails(
        from cache: ModelContainer,
        to library: ModelContainer
    ) throws -> Bool {
        let source = ModelContext(cache)
        var allResolved = true
        var lastSettingsID: String?
        while true {
            var page: FetchDescriptor<CachedPodcastLocalSettings>
            if let lastSettingsID {
                page = FetchDescriptor(
                    predicate: #Predicate { $0.id > lastSettingsID },
                    sortBy: [SortDescriptor(\.id)]
                )
            } else {
                page = FetchDescriptor(sortBy: [SortDescriptor(\.id)])
            }
            page.fetchLimit = pageSize
            let rows = try source.fetch(page)
            guard rows.isEmpty == false else { break }
            for row in rows {
                lastSettingsID = row.id
                guard let payload = try? JSONDecoder().decode(PodcastLocalSettingsPayload.self, from: row.payload),
                      try applyLocalSettings(payload, feedKey: row.feedURL, to: library) else {
                    allResolved = false
                    continue
                }
                source.delete(row)
            }
            try source.save()
            if rows.count < pageSize { break }
        }

        var lastBookmarkID: String?
        while true {
            var page: FetchDescriptor<CachedBookmarkDetail>
            if let lastBookmarkID {
                page = FetchDescriptor(
                    predicate: #Predicate { $0.id > lastBookmarkID },
                    sortBy: [SortDescriptor(\.id)]
                )
            } else {
                page = FetchDescriptor(sortBy: [SortDescriptor(\.id)])
            }
            page.fetchLimit = pageSize
            let rows = try source.fetch(page)
            guard rows.isEmpty == false else { break }
            for row in rows {
                lastBookmarkID = row.id
                guard try applyBookmarkDetail(row, to: library) else {
                    allResolved = false
                    continue
                }
                source.delete(row)
            }
            try source.save()
            if rows.count < pageSize { break }
        }
        return allResolved
    }

    private static func applyLocalSettings(
        _ payload: PodcastLocalSettingsPayload,
        feedKey: String?,
        to library: ModelContainer
    ) throws -> Bool {
        let context = ModelContext(library)
        let settings: PodcastSettings
        if let feedKey {
            let feedURL = URL(string: feedKey).map(PodcastFeedIdentity.normalizedFeedURLString)
                .flatMap(URL.init(string:)) ?? URL(string: feedKey)
            guard let feedURL else { return false }
            var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feed == feedURL })
            descriptor.fetchLimit = 1
            guard let podcast = try context.fetch(descriptor).first else { return false }
            if let existing = podcast.settings {
                settings = existing
            } else {
                settings = PodcastSettings(podcast: podcast)
                context.insert(settings)
                podcast.settings = settings
                payload.apply(to: settings)
            }
        } else {
            let globalTitle = PodcastSettings.globalSettingsTitle
            var descriptor = FetchDescriptor<PodcastSettings>(predicate: #Predicate { $0.title == globalTitle })
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                settings = existing
            } else {
                settings = PodcastSettings(defaultSettings: true)
                context.insert(settings)
                payload.apply(to: settings)
                if settings.title == nil { settings.title = PodcastSettings.globalSettingsTitle }
            }
        }
        try context.save()
        return true
    }

    private static func applyBookmarkDetail(
        _ detail: CachedBookmarkDetail,
        to library: ModelContainer
    ) throws -> Bool {
        guard let id = UUID(uuidString: detail.id) else { return false }
        let context = ModelContext(library)
        // Query the Marker root: a Bookmark predicate on inherited `uuid` traps in SwiftData (#420).
        let optionalID: UUID? = id
        let descriptor = FetchDescriptor<Marker>(predicate: #Predicate { $0.uuid == optionalID })
        guard let bookmark = try context.fetch(descriptor).lazy.compactMap({ $0 as? Bookmark }).first else { return false }
        if bookmark.imageData == nil { bookmark.imageData = detail.imageData }
        if bookmark.duration == nil { bookmark.duration = detail.duration }
        if bookmark.endTime == nil { bookmark.endTime = detail.endTime }
        if bookmark.link == nil { bookmark.link = detail.link }
        if bookmark.progress == nil { bookmark.progress = detail.progress }
        try context.save()
        return true
    }

    private static func migrateMissingEpisodeReferences(
        from cache: ModelContainer,
        to library: ModelContainer
    ) throws {
        let source = ModelContext(cache)
        let destination = ModelContext(library)
        var offset = 0
        while true {
            var page = FetchDescriptor<CachedMissingEpisodeReference>(
                sortBy: [SortDescriptor(\.id)]
            )
            page.fetchOffset = offset
            page.fetchLimit = pageSize
            let rows = try source.fetch(page)
            guard rows.isEmpty == false else { break }
            for row in rows {
                let id = row.id
                var existing = FetchDescriptor<CachedMissingEpisodeReference>(
                    predicate: #Predicate { $0.id == id }
                )
                existing.fetchLimit = 1
                if try destination.fetch(existing).first != nil { continue }
                let copied = CachedMissingEpisodeReference(
                    id: row.id,
                    streamRawValue: row.streamRawValue,
                    sourceRecordID: row.sourceRecordID,
                    feedURL: row.feedURL,
                    episodeID: row.episodeID,
                    sourceUpdatedAt: row.sourceUpdatedAt,
                    payloadDigest: row.payloadDigest,
                    generation: row.generation,
                    nextAttemptAt: row.nextAttemptAt
                )
                copied.attemptCount = row.attemptCount
                copied.contentProjectionPending = row.contentProjectionPending
                destination.insert(copied)
            }
            try destination.save()
            offset += rows.count
            if rows.count < pageSize { break }
        }
    }

    private static func migrateTranscriptAlignments(
        from cache: ModelContainer,
        to library: ModelContainer
    ) throws {
        let source = ModelContext(cache)
        let destination = ModelContext(library)
        var offset = 0
        while true {
            var page = FetchDescriptor<CachedTranscriptAlignment>(
                sortBy: [SortDescriptor(\.id)]
            )
            page.fetchOffset = offset
            page.fetchLimit = pageSize
            let rows = try source.fetch(page)
            guard rows.isEmpty == false else { break }
            for row in rows {
                let id = row.id
                var descriptor = FetchDescriptor<CachedTranscriptAlignment>(
                    predicate: #Predicate { $0.id == id }
                )
                descriptor.fetchLimit = 1
                if let existing = try destination.fetch(descriptor).first {
                    guard row.updatedAt > existing.updatedAt else { continue }
                    existing.episodeID = row.episodeID
                    existing.episodeURL = row.episodeURL
                    existing.mediaFingerprint = row.mediaFingerprint
                    existing.transcriptRevision = row.transcriptRevision
                    existing.anchorsJSON = row.anchorsJSON
                    existing.gapsJSON = row.gapsJSON
                    existing.updatedAt = row.updatedAt
                } else {
                    destination.insert(CachedTranscriptAlignment(
                        id: row.id,
                        episodeID: row.episodeID,
                        episodeURL: row.episodeURL,
                        mediaFingerprint: row.mediaFingerprint,
                        transcriptRevision: row.transcriptRevision,
                        anchorsJSON: row.anchorsJSON,
                        gapsJSON: row.gapsJSON,
                        updatedAt: row.updatedAt
                    ))
                }
            }
            try destination.save()
            offset += rows.count
            if rows.count < pageSize { break }
        }
    }

    private static func migrateTranscriptJobs(
        from cache: ModelContainer,
        to library: ModelContainer
    ) throws {
        let source = ModelContext(cache)
        let destination = ModelContext(library)
        var offset = 0
        while true {
            var page = FetchDescriptor<CachedTranscriptSynchronizationJob>(
                sortBy: [SortDescriptor(\.id)]
            )
            page.fetchOffset = offset
            page.fetchLimit = pageSize
            let rows = try source.fetch(page)
            guard rows.isEmpty == false else { break }
            for row in rows {
                let id = row.id
                var descriptor = FetchDescriptor<CachedTranscriptSynchronizationJob>(
                    predicate: #Predicate { $0.id == id }
                )
                descriptor.fetchLimit = 1
                if let existing = try destination.fetch(descriptor).first {
                    if row.enqueuedAt < existing.enqueuedAt {
                        existing.enqueuedAt = row.enqueuedAt
                    }
                    continue
                }
                destination.insert(CachedTranscriptSynchronizationJob(
                    id: row.id,
                    episodeURL: row.episodeURL,
                    enqueuedAt: row.enqueuedAt
                ))
            }
            try destination.save()
            offset += rows.count
            if rows.count < pageSize { break }
        }
    }
}
