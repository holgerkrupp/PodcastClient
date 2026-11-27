import Foundation
import SwiftData

/// Materializes device-local AI transcript and chapter staging rows into the
/// durable library before PodcastCache can become a staging-only store. Cache
/// rows are deliberately retained as a recovery source.
enum StoreSplitCacheAIContentMigration {
    private static let completedKey = "storeSplit.cacheAIContentMigration.v1"

    static var isComplete: Bool {
        let defaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
        return defaults.bool(forKey: completedKey)
    }

    /// Records completion when this install has no PodcastCache.sqlite at all
    /// (a fresh install, or one whose historical file is gone): there is no
    /// source row to copy, and a missing obsolete file must not keep startup
    /// trying to open, and thereby create, an empty cache.
    static func markCompleteBecauseSourceIsAbsent(
        defaults: UserDefaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    ) {
        defaults.set(true, forKey: completedKey)
    }

    /// Copies validated AI content into the library. A missing target episode
    /// or an unreadable/incomplete staging revision leaves the completion flag
    /// unset so startup can retry after promotion has restored the episode.
    /// An invalid revision is skipped, not fatal: the valid rows of the same
    /// pass are still saved.
    ///
    /// `mayAbandonUnresolvedRows`: the library is complete, so rows still
    /// unresolved after `StoreCacheMigrationGiveUp.maximumUnresolvedPasses`
    /// launches without progress are given up on (count recorded, rows kept
    /// in the cache file) and the migration is recorded complete.
    static func migrate(
        cache: ModelContainer,
        library: ModelContainer,
        dropUnmatchedRows: Bool = false,
        mayAbandonUnresolvedRows: Bool = false,
        defaults: UserDefaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    ) -> Bool {
        guard defaults.bool(forKey: completedKey) == false else { return true }

        let cacheContext = ModelContext(cache)
        let libraryContext = ModelContext(library)
        cacheContext.autosaveEnabled = false
        libraryContext.autosaveEnabled = false

        do {
            var unmatchedRows = 0
            var invalidRows = 0
            let transcriptRows = try cacheContext.fetch(FetchDescriptor<AITranscriptSync>())
            let chapterRows = try cacheContext.fetch(FetchDescriptor<AIChapterSetSync>())
            let transcripts = newest(transcriptRows, id: \.id, date: \.updatedAt)
            let chapterSets = newest(chapterRows, id: \.id, date: \.updatedAt)
            let episodes = try libraryContext.fetch(FetchDescriptor<Episode>())
            let episodesByIdentity = Dictionary(
                episodes.map { ($0.stableEpisodeIdentity.key, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            for transcript in transcripts {
                guard let episode = episodesByIdentity[
                    StableIdentityKey.make(transcript.feedURL, transcript.episodeID)
                ] else {
                    if dropUnmatchedRows {
                        // The authoritative library is complete for this pass.
                        // An orphaned cache revision is stale staging data and
                        // must not hold promotion open or recreate a deleted
                        // episode.
                        continue
                    }
                    unmatchedRows += 1
                    continue
                }
                let values: [AITranscriptLineValue]
                if transcript.deletedAt == nil {
                    let transcriptID = transcript.id
                    let revisionID = transcript.revisionID
                    let descriptor = FetchDescriptor<AITranscriptChunkSync>(
                        predicate: #Predicate {
                            $0.transcriptID == transcriptID && $0.revisionID == revisionID
                        },
                        sortBy: [SortDescriptor(\.chunkIndex)]
                    )
                    let chunks = try cacheContext.fetch(descriptor)
                    guard chunks.count == transcript.chunkCount,
                          chunks.indices.allSatisfy({ index in
                              chunks[index].chunkIndex == index
                                  && chunks[index].contentHash
                                  == AIContentSyncCodec.sha256Hex(Data(chunks[index].payloadJSON.utf8))
                          }) else {
                        invalidRows += 1
                        skip("transcript_chunks_invalid")
                        continue
                    }
                    do {
                        values = try AIContentSyncCodec.decodeTranscript(
                            chunks: chunks.map(\.payloadJSON),
                            expectedLineCount: transcript.lineCount,
                            expectedContentHash: transcript.contentHash
                        )
                    } catch {
                        invalidRows += 1
                        skip("transcript_decode_failed")
                        continue
                    }
                } else {
                    values = []
                }
                try applyTranscript(values, manifest: transcript, to: episode, in: libraryContext)
            }

            for chapterSet in chapterSets {
                guard let episode = episodesByIdentity[
                    StableIdentityKey.make(chapterSet.feedURL, chapterSet.episodeID)
                ] else {
                    if dropUnmatchedRows { continue }
                    unmatchedRows += 1
                    continue
                }
                guard let values = try? AIContentSyncCodec.decodeChapters(
                    payloadJSON: chapterSet.payloadJSON,
                    expectedContentHash: chapterSet.contentHash
                ) else {
                    invalidRows += 1
                    skip("chapter_decode_failed")
                    continue
                }
                guard values.count == chapterSet.chapterCount else {
                    invalidRows += 1
                    skip("chapter_count_invalid")
                    continue
                }
                try applyChapters(
                    values,
                    manifest: chapterSet,
                    cacheContext: cacheContext,
                    to: episode,
                    in: libraryContext
                )
            }

            // Older releases materialized device-local AI output directly in
            // CachedTranscriptLine/CachedChapter without a revision manifest.
            // Those rows still carry unique transcript text and chapter
            // playback progress, so recover them when no manifest handled the
            // episode. Canonical content always wins on retries.
            let legacyUnmatchedRows = try migrateLegacyMaterializedAIContent(
                cacheContext: cacheContext,
                libraryContext: libraryContext,
                episodesByIdentity: episodesByIdentity,
                manifestedTranscriptKeys: Set(transcripts.map {
                    StableIdentityKey.make($0.feedURL, $0.episodeID)
                }),
                manifestedChapterKeys: Set(chapterSets.map {
                    StableIdentityKey.make($0.feedURL, $0.episodeID)
                })
            )
            if dropUnmatchedRows == false { unmatchedRows += legacyUnmatchedRows }

            if libraryContext.hasChanges { try libraryContext.save() }
            if unmatchedRows > 0 || invalidRows > 0 {
                _ = fail(invalidRows > 0 ? "rows_invalid" : "episodes_pending")
                guard StoreCacheMigrationGiveUp.recordUnresolvedPass(
                    .aiContent,
                    unresolvedRows: unmatchedRows + invalidRows,
                    mayAbandon: mayAbandonUnresolvedRows,
                    defaults: defaults
                ) else { return false }
                defaults.set(true, forKey: completedKey)
                return true
            }
            StoreCacheMigrationGiveUp.clearAttempts(.aiContent, defaults: defaults)
            defaults.set(true, forKey: completedKey)
            CrashBreadcrumbs.shared.record("cache_ai_content_migration_completed")
            return true
        } catch {
            libraryContext.rollback()
            CrashBreadcrumbs.shared.record(
                "cache_ai_content_migration_deferred",
                details: "error_type=\(String(describing: type(of: error)))"
            )
            return false
        }
    }

    private static func migrateLegacyMaterializedAIContent(
        cacheContext: ModelContext,
        libraryContext: ModelContext,
        episodesByIdentity: [String: Episode],
        manifestedTranscriptKeys: Set<String>,
        manifestedChapterKeys: Set<String>
    ) throws -> Int {
        var unmatchedGroups = 0
        let transcriptRows = try cacheContext.fetch(
            FetchDescriptor<CachedTranscriptLine>(sortBy: [SortDescriptor(\.ordinal)])
        ).filter {
            $0.sourceRawValue == CachedTranscriptSource.ai.rawValue
                || $0.sourceRawValue == CachedTranscriptSource.localAI.rawValue
        }
        let transcriptGroups = Dictionary(grouping: transcriptRows, by: \.episodeID)
        for (key, rows) in transcriptGroups where manifestedTranscriptKeys.contains(key) == false {
            guard let episode = episodesByIdentity[key] else {
                unmatchedGroups += 1
                continue
            }
            let current = episode.transcriptLines ?? []
            guard current.contains(where: {
                $0.transcriptSource == .ai || $0.transcriptSource == .localAI
            }) == false else { continue }
            let migrated = rows.sorted { $0.ordinal < $1.ordinal }.map { row in
                let line = TranscriptLineAndTime(
                    id: UUID(uuidString: row.sourceUUID ?? row.id) ?? UUID(),
                    speaker: row.speaker,
                    text: row.text,
                    startTime: row.startTime,
                    endTime: row.endTime,
                    source: CachedTranscriptSource(rawValue: row.sourceRawValue)
                )
                line.episode = episode
                libraryContext.insert(line)
                return line
            }
            episode.transcriptLines = current + migrated
        }

        let chapterRows = try cacheContext.fetch(
            FetchDescriptor<CachedChapter>(sortBy: [SortDescriptor(\.ordinal)])
        ).filter { $0.typeRawValue == MarkerType.ai.rawValue }
        let chapterGroups = Dictionary(grouping: chapterRows, by: \.episodeID)
        for (key, rows) in chapterGroups where manifestedChapterKeys.contains(key) == false {
            guard let episode = episodesByIdentity[key] else {
                unmatchedGroups += 1
                continue
            }
            let current = episode.chapters ?? []
            guard current.contains(where: { $0.type == .ai }) == false else { continue }
            let migrated = rows.sorted { $0.ordinal < $1.ordinal }.map { row in
                let marker = Marker(
                    start: row.start ?? 0,
                    title: row.title,
                    type: .ai,
                    imageData: row.imageData,
                    duration: row.duration
                )
                marker.uuid = UUID(uuidString: row.sourceUUID ?? row.id) ?? UUID()
                marker.link = row.link
                marker.image = row.imageURL
                marker.endTime = row.endTime
                marker.creationtime = row.creationTime
                marker.analysisVariantID = row.analysisVariantID
                marker.progress = row.progress ?? 0
                marker.shouldPlay = row.shouldPlay
                marker.episode = episode
                libraryContext.insert(marker)
                return marker
            }
            episode.chapters = current + migrated
        }
        return unmatchedGroups
    }

    private static func newest<Row, Key: Hashable & Comparable>(
        _ rows: [Row],
        id: KeyPath<Row, Key>,
        date: KeyPath<Row, Date>
    ) -> [Row] {
        var latest: [Key: Row] = [:]
        for row in rows {
            let key = row[keyPath: id]
            if let existing = latest[key], existing[keyPath: date] >= row[keyPath: date] { continue }
            latest[key] = row
        }
        return latest.values.sorted { $0[keyPath: id] < $1[keyPath: id] }
    }

    private static func applyTranscript(
        _ values: [AITranscriptLineValue],
        manifest: AITranscriptSync,
        to episode: Episode,
        in context: ModelContext
    ) throws {
        let existing = episode.transcriptLines ?? []
        let generated = existing.filter {
            $0.transcriptSource == .ai || $0.transcriptSource == .localAI
        }
        let publisherLinesExist = existing.contains {
            $0.transcriptSource == .publisher || $0.transcriptSource == .unknown || $0.transcriptSource == nil
        }
        let latestLocalTranscript = try latestTranscription(for: episode, in: context)

        if let deletedAt = manifest.deletedAt {
            guard generated.isEmpty == false else { return }
            guard latestLocalTranscript.map({ $0.finishedAt <= deletedAt }) ?? true else { return }
            generated.forEach(context.delete)
            episode.transcriptLines = existing.filter { line in
                generated.contains { $0.persistentModelID == line.persistentModelID } == false
            }
            return
        }

        if let latestLocalTranscript, latestLocalTranscript.finishedAt > manifest.generatedAt { return }
        if generated.isEmpty == false {
            // Existing canonical AI lines carry no revision timestamp. Preserve
            // them when they differ; equality makes retries naturally idempotent.
            if transcriptLines(generated) == values { return }
            return
        }
        // A publisher transcript is authoritative when no canonical AI content
        // has previously been materialized.
        guard publisherLinesExist == false else { return }

        let newLines = values.map {
            TranscriptLineAndTime(
                speaker: $0.speaker,
                text: $0.text,
                startTime: $0.startTime,
                endTime: $0.endTime,
                source: .ai
            )
        }
        newLines.forEach(context.insert)
        episode.transcriptLines = existing + newLines
    }

    private static func transcriptLines(_ lines: [TranscriptLineAndTime]) -> [AITranscriptLineValue] {
        lines.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.text < $1.text
        }.map {
            AITranscriptLineValue(
                speaker: $0.speaker,
                text: $0.text,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
    }

    private static func latestTranscription(
        for episode: Episode,
        in context: ModelContext
    ) throws -> TranscriptionRecord? {
        guard let episodeURL = episode.url else { return nil }
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate { $0.episodeURL == episodeURL },
            sortBy: [SortDescriptor(\.finishedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).first
    }

    private static func applyChapters(
        _ values: [AIChapterValue],
        manifest: AIChapterSetSync,
        cacheContext: ModelContext,
        to episode: Episode,
        in context: ModelContext
    ) throws {
        let existing = episode.chapters ?? []
        let generated = existing.filter { $0.type == .ai }
        let cacheEpisodeID = StableIdentityKey.make(manifest.feedURL, manifest.episodeID)
        let cachedChapters = try cacheContext.fetch(
            FetchDescriptor<CachedChapter>(predicate: #Predicate { $0.episodeID == cacheEpisodeID })
        ).filter {
            $0.typeRawValue == MarkerType.ai.rawValue || $0.typeRawValue == "advertisement"
        }
        let cachedByKey = Dictionary(
            cachedChapters.map { (chapterKey(title: $0.title, start: $0.start ?? 0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previousByKey = Dictionary(
            generated.map { (chapterKey(title: $0.title, start: $0.start ?? 0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let desiredKeys = values.map { chapterKey(title: $0.title, start: $0.startTime) }
        let existingKeys = generated.map { chapterKey(title: $0.title, start: $0.start ?? 0) }

        if generated.isEmpty == false {
            // Preserve canonical chapter output if it differs. Markers do not
            // record the source revision time, so replacement could erase newer
            // generated content or user chapter progress.
            guard Set(desiredKeys) == Set(existingKeys) else { return }
            for (key, value) in zip(desiredKeys, values) {
                guard let marker = previousByKey[key] else { continue }
                marker.duration = value.duration
                marker.endTime = value.duration.map { value.startTime + $0 }
                marker.analysisVariantID = value.analysisVariantID
                if let raw = value.typeRawValue, let type = MarkerType(rawValue: raw) {
                    marker.type = type
                }
            }
            return
        }

        let markers = values.map { value -> Marker in
            let marker = Marker(
                start: value.startTime,
                title: value.title,
                type: value.typeRawValue.flatMap(MarkerType.init(rawValue:)) ?? .ai,
                duration: value.duration
            )
            marker.creationtime = manifest.generatedAt
            marker.analysisVariantID = value.analysisVariantID
            let key = chapterKey(title: value.title, start: value.startTime)
            let previousMarker = previousByKey[key]
            let previousCacheRow = cachedByKey[key]
            marker.progress = previousMarker?.progress ?? previousCacheRow?.progress ?? 0
            marker.shouldPlay = previousMarker?.shouldPlay ?? previousCacheRow?.shouldPlay ?? true
            marker.episode = episode
            context.insert(marker)
            return marker
        }
        episode.chapters = existing + markers
    }

    private static func chapterKey(title: String, start: Double) -> String {
        StableIdentityKey.make(
            String(Int((start * 100).rounded())),
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private static func skip(_ stage: String) {
        CrashBreadcrumbs.shared.record("cache_ai_content_migration_row_skipped", details: "stage=\(stage)")
    }

    private static func fail(_ stage: String) -> Bool {
        CrashBreadcrumbs.shared.record("cache_ai_content_migration_deferred", details: "stage=\(stage)")
        return false
    }
}
