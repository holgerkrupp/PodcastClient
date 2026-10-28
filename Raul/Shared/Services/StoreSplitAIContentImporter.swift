import Foundation
import SwiftData

struct StoreSplitAIContentImportResult: Sendable {
    var transcriptsApplied = 0
    var chaptersApplied = 0
    var skipped = 0
    var failed = 0
}

actor StoreSplitAIContentImporter {
    private let legacyContainer: ModelContainer
    private let cacheContainer: ModelContainer
    private let cacheContext: ModelContext

    private init(
        legacyContainer: ModelContainer,
        cacheContainer: ModelContainer
    ) {
        self.legacyContainer = legacyContainer
        self.cacheContainer = cacheContainer
        cacheContext = ModelContext(cacheContainer)
        cacheContext.autosaveEnabled = false
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
        let receipts: [AppliedAIContentRevision]
        do {
            receipts = try cacheContext.fetch(FetchDescriptor<AppliedAIContentRevision>())
        } catch {
            result.failed += 1
            recordFetchFailure("receipts", error: error)
            return result
        }
        var receiptsByID = receipts
            .reduce(into: [String: AppliedAIContentRevision]()) { $0[$1.id] = $1 }

        let transcriptRecords: [AITranscriptSync]
        do {
            transcriptRecords = try cacheContext.fetch(FetchDescriptor<AITranscriptSync>())
        } catch {
            result.failed += 1
            recordFetchFailure("transcripts", error: error)
            return result
        }
        let transcripts = transcriptRecords
            .reduce(into: [String: AITranscriptSync]()) { result, transcript in
                guard let existing = result[transcript.id],
                      existing.updatedAt >= transcript.updatedAt else {
                    result[transcript.id] = transcript
                    return
                }
            }
        let chapterRecords: [AIChapterSetSync]
        do {
            chapterRecords = try cacheContext.fetch(FetchDescriptor<AIChapterSetSync>())
        } catch {
            result.failed += 1
            recordFetchFailure("chapter_sets", error: error)
            return result
        }
        let chapterSets = chapterRecords
            .reduce(into: [String: AIChapterSetSync]()) { result, chapterSet in
                guard let existing = result[chapterSet.id],
                      existing.updatedAt >= chapterSet.updatedAt else {
                    result[chapterSet.id] = chapterSet
                    return
                }
            }

        let transcriptAppliedAtStart = result.transcriptsApplied
        for transcript in transcripts.values {
            autoreleasepool {
                let failuresBeforeEpisodeLookup = result.failed
                guard ensureCachedEpisode(
                    feedURL: transcript.feedURL,
                    episodeID: transcript.episodeID,
                    result: &result
                ) else {
                    if result.failed == failuresBeforeEpisodeLookup {
                        result.skipped += 1
                    }
                    return
                }
                if applyTranscriptDirectlyToCache(
                    transcript,
                    receiptsByID: &receiptsByID,
                    result: &result
                ) {
                    return
                }
                result.skipped += 1
            }
        }
        guard saveChanges(
            result: &result,
            transcriptChanges: result.transcriptsApplied - transcriptAppliedAtStart
        ) else { return result }

        let chaptersAppliedAtStart = result.chaptersApplied
        for chapterSet in chapterSets.values {
            autoreleasepool {
                let failuresBeforeEpisodeLookup = result.failed
                guard ensureCachedEpisode(
                    feedURL: chapterSet.feedURL,
                    episodeID: chapterSet.episodeID,
                    result: &result
                ) else {
                    if result.failed == failuresBeforeEpisodeLookup {
                        result.skipped += 1
                    }
                    return
                }
                if applyChapterSetDirectlyToCache(
                    chapterSet,
                    receiptsByID: &receiptsByID,
                    result: &result
                ) {
                    return
                }
                result.skipped += 1
            }
        }
        guard saveChanges(
            result: &result,
            chapterChanges: result.chaptersApplied - chaptersAppliedAtStart
        ) else { return result }

        CrashBreadcrumbs.shared.record(
            "store_split_ai_content_import_completed",
            details: "transcripts=\(result.transcriptsApplied),chapters=\(result.chaptersApplied),skipped=\(result.skipped),failed=\(result.failed)"
        )
        return result
    }

    /// Cache-only final path. If an older cache projection has not reached this
    /// feed yet, refresh its feed-derived rows into PodcastCache first; never
    /// materialize AI content back into the durable library graph.
    private func ensureCachedEpisode(
        feedURL: String,
        episodeID: String,
        result: inout StoreSplitAIContentImportResult
    ) -> Bool {
        let cacheEpisodeID = StableIdentityKey.make(feedURL, episodeID)
        var descriptor = FetchDescriptor<CachedEpisode>(
            predicate: #Predicate { $0.id == cacheEpisodeID }
        )
        descriptor.fetchLimit = 1
        do {
            if try cacheContext.fetch(descriptor).first != nil {
                return true
            }
        } catch {
            result.failed += 1
            recordFetchFailure("cached_episode", error: error)
            return false
        }
        guard let feed = URL(string: feedURL) else {
            result.failed += 1
            CrashBreadcrumbs.shared.record(
                "store_split_ai_content_feed_url_invalid"
            )
            return false
        }
        guard StoreSplitFeedCacheWriter.projectFeed(
            feedURL: feed,
            legacyContainer: legacyContainer,
            cacheContainer: cacheContainer
        ).completed else {
            result.failed += 1
            CrashBreadcrumbs.shared.record(
                "store_split_ai_content_feed_projection_incomplete"
            )
            return false
        }
        do {
            return try cacheContext.fetch(descriptor).first != nil
        } catch {
            result.failed += 1
            recordFetchFailure("cached_episode_after_projection", error: error)
            return false
        }
    }

    private func applyTranscriptDirectlyToCache(
        _ transcript: AITranscriptSync,
        receiptsByID: inout [String: AppliedAIContentRevision],
        result: inout StoreSplitAIContentImportResult
    ) -> Bool {
        let cacheEpisodeID = StableIdentityKey.make(
            transcript.feedURL,
            transcript.episodeID
        )
        var episodeDescriptor = FetchDescriptor<CachedEpisode>(
            predicate: #Predicate { $0.id == cacheEpisodeID }
        )
        episodeDescriptor.fetchLimit = 1
        do {
            guard try cacheContext.fetch(episodeDescriptor).first != nil else {
                result.skipped += 1
                return false
            }
        } catch {
            result.failed += 1
            recordFetchFailure("transcript_episode", error: error)
            return true
        }

        let receipt = receipt(for: transcript.id, receiptsByID: &receiptsByID)
        let feedURL = transcript.feedURL
        let episodeID = cacheEpisodeID
        let linesDescriptor = FetchDescriptor<CachedTranscriptLine>(
            predicate: #Predicate {
                $0.feedURL == feedURL && $0.episodeID == episodeID
            }
        )
        let existingLines: [CachedTranscriptLine]
        do {
            existingLines = try cacheContext.fetch(linesDescriptor)
        } catch {
            result.failed += 1
            recordFetchFailure("transcript_lines", error: error)
            return true
        }
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
        let chunks: [AITranscriptChunkSync]
        do {
            chunks = try cacheContext.fetch(chunkDescriptor)
        } catch {
            result.failed += 1
            recordFetchFailure("transcript_chunks", error: error)
            return true
        }
        guard chunks.count == transcript.chunkCount,
              chunks.indices.allSatisfy({ index in
                  chunks[index].chunkIndex == index
                      && chunks[index].contentHash
                      == AIContentSyncCodec.sha256Hex(Data(chunks[index].payloadJSON.utf8))
              }) else {
            result.failed += 1
            CrashBreadcrumbs.shared.record(
                "store_split_ai_transcript_chunks_incomplete",
                details: "chunks=\(chunks.count),expected=\(transcript.chunkCount)"
            )
            return true
        }

        let publisherLines = existingLines.filter {
            $0.sourceRawValue == CachedTranscriptSource.publisher.rawValue
                || $0.sourceRawValue == CachedTranscriptSource.unknown.rawValue
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
        do {
            if let localGeneratedAt = try cacheContext.fetch(transcriptionDescriptor).first?.finishedAt,
               localGeneratedAt > transcript.generatedAt {
                result.skipped += 1
                return true
            }
        } catch {
            result.failed += 1
            recordFetchFailure("local_transcription", error: error)
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
        let cacheEpisodeID = StableIdentityKey.make(
            chapterSet.feedURL,
            chapterSet.episodeID
        )
        var episodeDescriptor = FetchDescriptor<CachedEpisode>(
            predicate: #Predicate { $0.id == cacheEpisodeID }
        )
        episodeDescriptor.fetchLimit = 1
        do {
            guard try cacheContext.fetch(episodeDescriptor).first != nil else {
                result.skipped += 1
                return false
            }
        } catch {
            result.failed += 1
            recordFetchFailure("chapter_episode", error: error)
            return true
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
            let episodeID = cacheEpisodeID
            let descriptor = FetchDescriptor<CachedChapter>(
                predicate: #Predicate { $0.episodeID == episodeID }
            )
            let current = try cacheContext.fetch(descriptor)
            let currentAI = current.filter {
                $0.typeRawValue == MarkerType.ai.rawValue
                    || $0.typeRawValue == "advertisement"
            }
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
                        analysisVariantID: value.analysisVariantID,
                        progress: previous?.progress,
                        typeRawValue: value.typeRawValue == "advertisement"
                            ? MarkerType.ai.rawValue
                            : (value.typeRawValue ?? MarkerType.ai.rawValue),
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

    private func saveChanges(
        result: inout StoreSplitAIContentImportResult,
        transcriptChanges: Int = 0,
        chapterChanges: Int = 0
    ) -> Bool {
        do {
            if cacheContext.hasChanges {
                try cacheContext.save()
            }
            return true
        } catch {
            // Receipts and materialized rows must commit together. Rolling back
            // makes the same revision eligible for a later retry.
            cacheContext.rollback()
            result.failed += 1
            result.transcriptsApplied = max(0, result.transcriptsApplied - transcriptChanges)
            result.chaptersApplied = max(0, result.chaptersApplied - chapterChanges)
            CrashBreadcrumbs.shared.record(
                "store_split_ai_content_save_failed",
                details: "error_type=\(String(describing: type(of: error)))"
            )
            return false
        }
    }

    private func recordFetchFailure(_ stage: String, error: Error) {
        CrashBreadcrumbs.shared.record(
            "store_split_ai_content_fetch_failed",
            details: "stage=\(stage),error_type=\(String(describing: type(of: error)))"
        )
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
