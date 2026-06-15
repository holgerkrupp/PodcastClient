import Foundation
import SwiftData

struct StoreSplitAIContentImportResult: Sendable {
    var transcriptsApplied = 0
    var chaptersApplied = 0
    var skipped = 0
    var failed = 0
}

actor StoreSplitAIContentImporter {
    private let legacyContext: ModelContext
    private let userStateContext: ModelContext
    private let cacheContext: ModelContext

    private init(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer
    ) {
        legacyContext = ModelContext(legacyContainer)
        userStateContext = ModelContext(userStateContainer)
        cacheContext = ModelContext(cacheContainer)
        legacyContext.autosaveEnabled = false
        userStateContext.autosaveEnabled = false
        cacheContext.autosaveEnabled = false
    }

    nonisolated static func apply(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer
    ) async -> StoreSplitAIContentImportResult {
        await Task.detached(priority: .utility) {
            let importer = StoreSplitAIContentImporter(
                legacyContainer: legacyContainer,
                userStateContainer: userStateContainer,
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

        let transcripts = ((try? userStateContext.fetch(FetchDescriptor<AITranscriptSync>())) ?? [])
            .reduce(into: [String: AITranscriptSync]()) { result, transcript in
                guard let existing = result[transcript.id],
                      existing.updatedAt >= transcript.updatedAt else {
                    result[transcript.id] = transcript
                    return
                }
            }
        let chapterSets = ((try? userStateContext.fetch(FetchDescriptor<AIChapterSetSync>())) ?? [])
            .reduce(into: [String: AIChapterSetSync]()) { result, chapterSet in
                guard let existing = result[chapterSet.id],
                      existing.updatedAt >= chapterSet.updatedAt else {
                    result[chapterSet.id] = chapterSet
                    return
                }
            }

        for transcript in transcripts.values {
            guard let episode = episode(
                feedURL: transcript.feedURL,
                episodeID: transcript.episodeID
            ) else {
                result.skipped += 1
                continue
            }
            apply(
                transcript: transcript,
                to: episode,
                latestLocalTranscriptionDateByURL: latestLocalTranscriptionDateByURL,
                receiptsByID: &receiptsByID,
                result: &result
            )
        }
        saveChanges(result: &result)

        for chapterSet in chapterSets.values {
            guard let episode = episode(
                feedURL: chapterSet.feedURL,
                episodeID: chapterSet.episodeID
            ) else {
                result.skipped += 1
                continue
            }
            apply(
                chapterSet: chapterSet,
                to: episode,
                receiptsByID: &receiptsByID,
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
        var descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.feed == url }
        )
        descriptor.fetchLimit = 2
        return ((try? legacyContext.fetch(descriptor)) ?? [])
            .flatMap { $0.episodes ?? [] }
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
        let revisionChunks = (try? userStateContext.fetch(descriptor)) ?? []
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
            episode.transcriptLines = values.map {
                let line = TranscriptLineAndTime(
                    speaker: $0.speaker,
                    text: $0.text,
                    startTime: $0.startTime,
                    endTime: $0.endTime
                )
                line.episode = episode
                return line
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
                    chapter.progress = existing.progress
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
