import Foundation
import SwiftData

struct StoreSplitAIContentImportResult: Sendable {
    var transcriptsApplied = 0
    var chaptersApplied = 0
    var skipped = 0
    var failed = 0
}

actor StoreSplitAIContentImporter {
    /// How many episodes to apply before flushing and recycling the legacy
    /// context. Each applied episode faults a full `Episode` row (including its
    /// heavy `content`/`desc` text) and builds new transcript-line/chapter
    /// objects, so without recycling the whole table would accumulate in one
    /// context and blow the jetsam budget.
    private static let recycleBatchSize = 50

    private let legacyContainer: ModelContainer
    private var legacyContext: ModelContext
    private let cacheContext: ModelContext

    private init(
        legacyContainer: ModelContainer,
        cacheContainer: ModelContainer
    ) {
        self.legacyContainer = legacyContainer
        legacyContext = ModelContext(legacyContainer)
        cacheContext = ModelContext(cacheContainer)
        legacyContext.autosaveEnabled = false
        cacheContext.autosaveEnabled = false
    }

    /// Persists pending work and replaces the legacy context with a fresh one so
    /// the faulted `Episode` graph from the processed batch can be released.
    /// `cacheContext` is kept so local revision lookups and inserted receipts
    /// retain their identity across batches.
    private func recycleLegacyContextIfNeeded(
        processedSinceRecycle: inout Int,
        result: inout StoreSplitAIContentImportResult
    ) {
        guard processedSinceRecycle >= Self.recycleBatchSize else { return }
        saveChanges(result: &result)
        legacyContext = ModelContext(legacyContainer)
        legacyContext.autosaveEnabled = false
        processedSinceRecycle = 0
    }

    nonisolated static func apply(
        legacyContainer: ModelContainer,
        cacheContainer: ModelContainer
    ) async -> StoreSplitAIContentImportResult {
        await Task.detached(priority: .utility) {
            let importer = StoreSplitAIContentImporter(
                legacyContainer: legacyContainer,
                cacheContainer: cacheContainer
            )
            return await importer.run()
        }.value
    }

    private func run() -> StoreSplitAIContentImportResult {
        var result = StoreSplitAIContentImportResult()
        var receiptsByID = ((try? cacheContext.fetch(FetchDescriptor<AppliedAIContentRevision>())) ?? [])
            .reduce(into: [String: AppliedAIContentRevision]()) { $0[$1.id] = $1 }
        let transcriptionRecords = (try? legacyContext.fetch(FetchDescriptor<TranscriptionRecord>())) ?? []
        let latestLocalTranscriptionDateByURL = transcriptionRecords.reduce(
            into: [URL: Date]()
        ) { dates, record in
            guard let episodeURL = record.episodeURL else { return }
            dates[episodeURL] = max(dates[episodeURL] ?? .distantPast, record.finishedAt)
        }

        let transcripts = ((try? cacheContext.fetch(FetchDescriptor<AITranscriptSync>())) ?? [])
            .reduce(into: [String: AITranscriptSync]()) { result, transcript in
                guard let existing = result[transcript.id],
                      existing.updatedAt >= transcript.updatedAt else {
                    result[transcript.id] = transcript
                    return
                }
            }
        let chapterSets = ((try? cacheContext.fetch(FetchDescriptor<AIChapterSetSync>())) ?? [])
            .reduce(into: [String: AIChapterSetSync]()) { result, chapterSet in
                guard let existing = result[chapterSet.id],
                      existing.updatedAt >= chapterSet.updatedAt else {
                    result[chapterSet.id] = chapterSet
                    return
                }
            }

        var processedSinceRecycle = 0
        for transcript in transcripts.values {
            autoreleasepool {
                if applyTranscriptDirectlyToCache(
                    transcript,
                    receiptsByID: &receiptsByID,
                    result: &result
                ) {
                    return
                }
                guard let episode = episode(
                    feedURL: transcript.feedURL,
                    episodeID: transcript.episodeID
                ) else {
                    result.skipped += 1
                    return
                }
                apply(
                    transcript: transcript,
                    to: episode,
                    latestLocalTranscriptionDateByURL: latestLocalTranscriptionDateByURL,
                    receiptsByID: &receiptsByID,
                    result: &result
                )
            }
            processedSinceRecycle += 1
            recycleLegacyContextIfNeeded(
                processedSinceRecycle: &processedSinceRecycle,
                result: &result
            )
        }
        saveChanges(result: &result)
        legacyContext = ModelContext(legacyContainer)
        legacyContext.autosaveEnabled = false

        processedSinceRecycle = 0
        for chapterSet in chapterSets.values {
            autoreleasepool {
                if applyChapterSetDirectlyToCache(
                    chapterSet,
                    receiptsByID: &receiptsByID,
                    result: &result
                ) {
                    return
                }
                guard let episode = episode(
                    feedURL: chapterSet.feedURL,
                    episodeID: chapterSet.episodeID
                ) else {
                    result.skipped += 1
                    return
                }
                apply(
                    chapterSet: chapterSet,
                    to: episode,
                    receiptsByID: &receiptsByID,
                    result: &result
                )
            }
            processedSinceRecycle += 1
            recycleLegacyContextIfNeeded(
                processedSinceRecycle: &processedSinceRecycle,
                result: &result
            )
        }
        saveChanges(result: &result)

        CrashBreadcrumbs.shared.record(
            "store_split_ai_content_import_completed",
            details: "transcripts=\(result.transcriptsApplied),chapters=\(result.chaptersApplied),skipped=\(result.skipped),failed=\(result.failed)"
        )
        return result
    }

    /// Cache-first final path. Legacy materialization below is retained only for
    /// a migration fallback when the feed has not reached PodcastCache yet.
    private func applyTranscriptDirectlyToCache(
        _ transcript: AITranscriptSync,
        receiptsByID: inout [String: AppliedAIContentRevision],
        result: inout StoreSplitAIContentImportResult
    ) -> Bool {
        let cacheEpisodeID = transcript.id
        var episodeDescriptor = FetchDescriptor<CachedEpisode>(
            predicate: #Predicate { $0.id == cacheEpisodeID }
        )
        episodeDescriptor.fetchLimit = 1
        guard (try? cacheContext.fetch(episodeDescriptor).first) != nil else {
            return false
        }

        let receipt = receipt(for: transcript.id, receiptsByID: &receiptsByID)
        let feedURL = transcript.feedURL
        let episodeID = transcript.id
        let linesDescriptor = FetchDescriptor<CachedTranscriptLine>(
            predicate: #Predicate {
                $0.feedURL == feedURL && $0.episodeID == episodeID
            }
        )
        let existingLines = (try? cacheContext.fetch(linesDescriptor)) ?? []
        let generatedLines = existingLines.filter {
            $0.sourceRawValue == CachedTranscriptSource.ai.rawValue
                || $0.sourceRawValue == CachedTranscriptSource.localAI.rawValue
        }

        if transcript.deletedAt != nil {
            guard receipt.transcriptRevisionID != nil || generatedLines.isEmpty == false else {
                result.skipped += 1
                return true
            }
            generatedLines.forEach(cacheContext.delete)
            receipt.transcriptRevisionID = transcript.revisionID
            receipt.updatedAt = .now
            result.transcriptsApplied += 1
            return true
        }
        guard receipt.transcriptRevisionID != transcript.revisionID else {
            result.skipped += 1
            return true
        }

        let transcriptID = transcript.id
        let revisionID = transcript.revisionID
        let chunkDescriptor = FetchDescriptor<AITranscriptChunkSync>(
            predicate: #Predicate {
                $0.transcriptID == transcriptID && $0.revisionID == revisionID
            },
            sortBy: [SortDescriptor(\AITranscriptChunkSync.chunkIndex)]
        )
        let chunks = (try? cacheContext.fetch(chunkDescriptor)) ?? []
        guard chunks.count == transcript.chunkCount,
              chunks.indices.allSatisfy({ index in
                  chunks[index].chunkIndex == index
                      && chunks[index].contentHash
                      == AIContentSyncCodec.sha256Hex(Data(chunks[index].payloadJSON.utf8))
              }) else {
            result.skipped += 1
            return true
        }

        let publisherLines = existingLines.filter {
            $0.sourceRawValue == CachedTranscriptSource.publisher.rawValue
        }
        if publisherLines.isEmpty == false,
           receipt.transcriptRevisionID == nil,
           generatedLines.isEmpty {
            result.skipped += 1
            return true
        }

        let transcriptionDescriptor = FetchDescriptor<CachedTranscriptionRecord>(
            predicate: #Predicate { $0.episodeID == episodeID },
            sortBy: [SortDescriptor(\CachedTranscriptionRecord.finishedAt, order: .reverse)]
        )
        if let localGeneratedAt = try? cacheContext.fetch(transcriptionDescriptor).first?.finishedAt,
           localGeneratedAt > transcript.generatedAt {
            result.skipped += 1
            return true
        }

        do {
            let values = try AIContentSyncCodec.decodeTranscript(
                chunks: chunks.map(\.payloadJSON),
                expectedLineCount: transcript.lineCount,
                expectedContentHash: transcript.contentHash
            )
            generatedLines.forEach(cacheContext.delete)
            for (ordinal, value) in values.enumerated() {
                cacheContext.insert(
                    CachedTranscriptLine(
                        id: StableIdentityKey.make(
                            transcript.id,
                            transcript.revisionID,
                            String(ordinal)
                        ),
                        feedURL: transcript.feedURL,
                        episodeID: transcript.id,
                        speaker: value.speaker,
                        text: value.text,
                        startTime: value.startTime,
                        endTime: value.endTime,
                        ordinal: ordinal,
                        sourceRawValue: CachedTranscriptSource.ai.rawValue,
                        revisionID: transcript.revisionID,
                        updatedAt: transcript.updatedAt
                    )
                )
            }
            receipt.transcriptRevisionID = transcript.revisionID
            receipt.updatedAt = .now
            result.transcriptsApplied += 1
        } catch {
            result.failed += 1
        }
        return true
    }

    private func applyChapterSetDirectlyToCache(
        _ chapterSet: AIChapterSetSync,
        receiptsByID: inout [String: AppliedAIContentRevision],
        result: inout StoreSplitAIContentImportResult
    ) -> Bool {
        let cacheEpisodeID = chapterSet.id
        var episodeDescriptor = FetchDescriptor<CachedEpisode>(
            predicate: #Predicate { $0.id == cacheEpisodeID }
        )
        episodeDescriptor.fetchLimit = 1
        guard (try? cacheContext.fetch(episodeDescriptor).first) != nil else {
            return false
        }

        let receipt = receipt(for: chapterSet.id, receiptsByID: &receiptsByID)
        guard receipt.chapterRevisionID != chapterSet.revisionID else {
            result.skipped += 1
            return true
        }
        do {
            let values = try AIContentSyncCodec.decodeChapters(
                payloadJSON: chapterSet.payloadJSON,
                expectedContentHash: chapterSet.contentHash
            )
            guard values.count == chapterSet.chapterCount else {
                result.failed += 1
                return true
            }
            let episodeID = chapterSet.id
            let descriptor = FetchDescriptor<CachedChapter>(
                predicate: #Predicate { $0.episodeID == episodeID }
            )
            let current = (try? cacheContext.fetch(descriptor)) ?? []
            let currentAI = current.filter { $0.typeRawValue == MarkerType.ai.rawValue }
            let previousByKey = Dictionary(
                currentAI.map {
                    (chapterKey(title: $0.title, start: $0.start ?? 0), $0)
                },
                uniquingKeysWith: { first, _ in first }
            )
            currentAI.forEach(cacheContext.delete)
            for (ordinal, value) in values.enumerated() {
                let previous = previousByKey[
                    chapterKey(title: value.title, start: value.startTime)
                ]
                cacheContext.insert(
                    CachedChapter(
                        id: StableIdentityKey.make(
                            chapterSet.id,
                            chapterSet.revisionID,
                            String(ordinal)
                        ),
                        feedURL: chapterSet.feedURL,
                        episodeID: chapterSet.id,
                        title: value.title,
                        start: value.startTime,
                        duration: value.duration,
                        progress: previous?.progress,
                        typeRawValue: MarkerType.ai.rawValue,
                        shouldPlay: previous?.shouldPlay ?? true,
                        ordinal: ordinal,
                        updatedAt: chapterSet.updatedAt
                    )
                )
            }
            receipt.chapterRevisionID = chapterSet.revisionID
            receipt.updatedAt = .now
            result.chaptersApplied += 1
        } catch {
            result.failed += 1
        }
        return true
    }

    private func episode(feedURL: String, episodeID: String) -> Episode? {
        let candidates: [Episode]

        if episodeID.hasPrefix("guid:") {
            let guid = String(episodeID.dropFirst("guid:".count))
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.guid == guid }
            )
            descriptor.fetchLimit = 20
            candidates = (try? legacyContext.fetch(descriptor)) ?? []
        } else if episodeID.hasPrefix("enclosure:") || episodeID.hasPrefix("episode:") {
            let prefix = episodeID.hasPrefix("enclosure:") ? "enclosure:" : "episode:"
            guard let url = URL(string: String(episodeID.dropFirst(prefix.count))) else {
                return nil
            }
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.url == url }
            )
            descriptor.fetchLimit = 20
            candidates = (try? legacyContext.fetch(descriptor)) ?? []
        } else if episodeID.hasPrefix("link:") {
            guard let url = URL(string: String(episodeID.dropFirst("link:".count))) else {
                return nil
            }
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.link == url }
            )
            descriptor.fetchLimit = 20
            candidates = (try? legacyContext.fetch(descriptor)) ?? []
        } else {
            candidates = episodesForHashFallback(feedURL: feedURL)
        }

        return candidates.first {
            let identity = $0.stableEpisodeIdentity
            return identity.feedURL == feedURL && identity.episodeID == episodeID
        }
    }

    private func episodesForHashFallback(feedURL: String) -> [Episode] {
        guard let url = URL(string: feedURL) else { return [] }
        // Fetch the feed's episodes directly rather than walking
        // `podcast.episodes`: the relationship getter faults every episode onto
        // the live Podcast object and pins them for the importer's lifetime.
        // This transient array is released by the caller after matching.
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.podcast?.feed == url }
        )
        return (try? legacyContext.fetch(descriptor)) ?? []
    }

    private func apply(
        transcript: AITranscriptSync,
        to episode: Episode,
        latestLocalTranscriptionDateByURL: [URL: Date],
        receiptsByID: inout [String: AppliedAIContentRevision],
        result: inout StoreSplitAIContentImportResult
    ) {
        let receipt = receipt(for: transcript.id, receiptsByID: &receiptsByID)
        let hasLocalAITranscription = episode.url.flatMap {
            latestLocalTranscriptionDateByURL[$0]
        } != nil
        if transcript.deletedAt != nil {
            if receipt.transcriptRevisionID != nil || hasLocalAITranscription {
                episode.transcriptLines = nil
                episode.refresh.toggle()
                receipt.transcriptRevisionID = transcript.revisionID
                receipt.updatedAt = .now
                result.transcriptsApplied += 1
            } else {
                result.skipped += 1
            }
            return
        }
        guard receipt.transcriptRevisionID != transcript.revisionID else {
            result.skipped += 1
            return
        }

        let transcriptID = transcript.id
        let revisionID = transcript.revisionID
        let descriptor = FetchDescriptor<AITranscriptChunkSync>(
            predicate: #Predicate<AITranscriptChunkSync> {
                $0.transcriptID == transcriptID && $0.revisionID == revisionID
            },
            sortBy: [SortDescriptor(\AITranscriptChunkSync.chunkIndex)]
        )
        let revisionChunks = (try? cacheContext.fetch(descriptor)) ?? []
        guard revisionChunks.count == transcript.chunkCount,
              revisionChunks.indices.allSatisfy({
                  revisionChunks[$0].chunkIndex == $0
                      && revisionChunks[$0].contentHash
                      == AIContentSyncCodec.sha256Hex(
                          Data(revisionChunks[$0].payloadJSON.utf8)
                      )
              }) else {
            result.skipped += 1
            return
        }

        let hasPublisherTranscript = episode.transcriptLines?.isEmpty == false
            && hasLocalAITranscription == false
            && receipt.transcriptRevisionID == nil
        if hasPublisherTranscript {
            result.skipped += 1
            return
        }
        if let episodeURL = episode.url,
           let localGeneratedAt = latestLocalTranscriptionDateByURL[episodeURL],
           localGeneratedAt > transcript.generatedAt {
            result.skipped += 1
            return
        }

        do {
            let values = try AIContentSyncCodec.decodeTranscript(
                chunks: revisionChunks.map(\.payloadJSON),
                expectedLineCount: transcript.lineCount,
                expectedContentHash: transcript.contentHash
            )
            // Assign the relationship once. Setting `line.episode` for every line
            // makes SwiftData repeatedly reconcile the growing inverse collection,
            // producing quadratic Core Data object-ID URL allocations.
            episode.transcriptLines = values.map {
                TranscriptLineAndTime(
                    speaker: $0.speaker,
                    text: $0.text,
                    startTime: $0.startTime,
                    endTime: $0.endTime
                )
            }
            episode.refresh.toggle()
            receipt.transcriptRevisionID = transcript.revisionID
            receipt.updatedAt = .now
            result.transcriptsApplied += 1
        } catch {
            result.failed += 1
        }
    }

    private func apply(
        chapterSet: AIChapterSetSync,
        to episode: Episode,
        receiptsByID: inout [String: AppliedAIContentRevision],
        result: inout StoreSplitAIContentImportResult
    ) {
        let receipt = receipt(for: chapterSet.id, receiptsByID: &receiptsByID)
        guard receipt.chapterRevisionID != chapterSet.revisionID else {
            result.skipped += 1
            return
        }

        do {
            let values = try AIContentSyncCodec.decodeChapters(
                payloadJSON: chapterSet.payloadJSON,
                expectedContentHash: chapterSet.contentHash
            )
            guard values.count == chapterSet.chapterCount else {
                result.failed += 1
                return
            }

            let existingAIChapters = (episode.chapters ?? []).filter { $0.type == .ai }
            let existingByKey = existingAIChapters.reduce(
                into: [String: Marker]()
            ) { markers, chapter in
                markers[chapterKey(title: chapter.title, start: chapter.start ?? 0)] = chapter
            }
            let newChapters = values.map { value -> Marker in
                let chapter = Marker(
                    start: value.startTime,
                    title: value.title,
                    type: .ai,
                    duration: value.duration
                )
                chapter.episode = episode
                if let existing = existingByKey[
                    chapterKey(title: value.title, start: value.startTime)
                ] {
                    chapter.shouldPlay = existing.shouldPlay
                    chapter.progress = episode.hasPlaybackHistory ? existing.progress : 0
                }
                return chapter
            }
            episode.chapters?.removeAll { $0.type == .ai }
            if episode.chapters == nil {
                episode.chapters = []
            }
            episode.chapters?.append(contentsOf: newChapters)
            episode.chapters?.sort { ($0.start ?? 0) < ($1.start ?? 0) }
            episode.refresh.toggle()
            receipt.chapterRevisionID = chapterSet.revisionID
            receipt.updatedAt = .now
            result.chaptersApplied += 1
        } catch {
            result.failed += 1
        }
    }

    private func saveChanges(result: inout StoreSplitAIContentImportResult) {
        do {
            if legacyContext.hasChanges {
                try legacyContext.save()
            }
            if cacheContext.hasChanges {
                try cacheContext.save()
            }
        } catch {
            result.failed += 1
        }
    }

    private func receipt(
        for identityKey: String,
        receiptsByID: inout [String: AppliedAIContentRevision]
    ) -> AppliedAIContentRevision {
        if let receipt = receiptsByID[identityKey] {
            return receipt
        }
        let receipt = AppliedAIContentRevision(episodeIdentityKey: identityKey)
        cacheContext.insert(receipt)
        receiptsByID[identityKey] = receipt
        return receipt
    }

    private func chapterKey(title: String, start: Double) -> String {
        StableIdentityKey.make(
            String(Int((start * 100).rounded())),
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }
}
