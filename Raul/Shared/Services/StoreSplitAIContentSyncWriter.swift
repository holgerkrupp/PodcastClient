import Foundation
import SwiftData

@ModelActor
actor StoreSplitAIContentSyncWriter {
    func writeTranscript(
        identity: EpisodeStableIdentity,
        lines: [AITranscriptLineValue],
        localeIdentifier: String?,
        generatedAt: Date
    ) {
        do {
            let encoded = try AIContentSyncCodec.encodeTranscript(lines)
            let transcriptID = identity.key
            let now = Date()

            for (index, payload) in encoded.chunks.enumerated() {
                let chunkID = StableIdentityKey.make(
                    transcriptID,
                    encoded.revisionID,
                    String(index)
                )
                let descriptor = FetchDescriptor<AITranscriptChunkSync>(
                    predicate: #Predicate<AITranscriptChunkSync> { $0.id == chunkID }
                )
                let chunkHash = AIContentSyncCodec.sha256Hex(Data(payload.utf8))

                if let chunk = try modelContext.fetch(descriptor).first {
                    if chunk.contentHash != chunkHash || chunk.payloadJSON != payload {
                        chunk.payloadJSON = payload
                        chunk.contentHash = chunkHash
                        chunk.updatedAt = now
                    }
                } else {
                    modelContext.insert(
                        AITranscriptChunkSync(
                            transcriptID: transcriptID,
                            revisionID: encoded.revisionID,
                            chunkIndex: index,
                            payloadJSON: payload,
                            contentHash: chunkHash,
                            updatedAt: now
                        )
                    )
                }
            }

            let descriptor = FetchDescriptor<AITranscriptSync>(
                predicate: #Predicate<AITranscriptSync> { $0.id == transcriptID }
            )
            let sourceDeviceID = ListeningDeviceIdentity.current().id
            if let transcript = try modelContext.fetch(descriptor).first {
                guard generatedAt >= transcript.generatedAt else { return }
                transcript.feedURL = identity.feedURL
                transcript.episodeID = identity.episodeID
                transcript.revisionID = encoded.revisionID
                transcript.localeIdentifier = localeIdentifier
                transcript.chunkCount = encoded.chunks.count
                transcript.lineCount = encoded.lineCount
                transcript.contentHash = encoded.contentHash
                transcript.generatedAt = generatedAt
                transcript.deletedAt = nil
                transcript.updatedAt = now
                transcript.sourceDeviceID = sourceDeviceID
            } else {
                modelContext.insert(
                    AITranscriptSync(
                        feedURL: identity.feedURL,
                        episodeID: identity.episodeID,
                        revisionID: encoded.revisionID,
                        localeIdentifier: localeIdentifier,
                        chunkCount: encoded.chunks.count,
                        lineCount: encoded.lineCount,
                        contentHash: encoded.contentHash,
                        generatedAt: generatedAt,
                        deletedAt: nil,
                        updatedAt: now,
                        sourceDeviceID: sourceDeviceID
                    )
                )
            }

            try modelContext.save()
        } catch {
            CrashBreadcrumbs.shared.record(
                "store_split_ai_transcript_write_failed",
                details: error.localizedDescription
            )
        }
    }

    func tombstoneTranscripts(
        identities: [EpisodeStableIdentity],
        at date: Date = .now
    ) {
        let sourceDeviceID = ListeningDeviceIdentity.current().id

        for identity in identities {
            let transcriptID = identity.key
            let descriptor = FetchDescriptor<AITranscriptSync>(
                predicate: #Predicate<AITranscriptSync> { $0.id == transcriptID }
            )
            if let transcript = try? modelContext.fetch(descriptor).first {
                guard date >= transcript.updatedAt else { continue }
                transcript.deletedAt = date
                transcript.updatedAt = date
                transcript.sourceDeviceID = sourceDeviceID
            } else {
                modelContext.insert(
                    AITranscriptSync(
                        feedURL: identity.feedURL,
                        episodeID: identity.episodeID,
                        revisionID: StableIdentityKey.make(
                            "deleted",
                            String(date.timeIntervalSince1970)
                        ),
                        chunkCount: 0,
                        lineCount: 0,
                        contentHash: "",
                        generatedAt: .distantPast,
                        deletedAt: date,
                        updatedAt: date,
                        sourceDeviceID: sourceDeviceID
                    )
                )
            }
        }

        do {
            try modelContext.save()
        } catch {
            CrashBreadcrumbs.shared.record(
                "store_split_ai_transcript_tombstone_failed",
                details: error.localizedDescription
            )
        }
    }

    func writeChapters(
        identity: EpisodeStableIdentity,
        chapters: [AIChapterValue],
        generatedAt: Date
    ) {
        do {
            let encoded = try AIContentSyncCodec.encodeChapters(chapters)
            let chapterSetID = identity.key
            let now = Date()
            let descriptor = FetchDescriptor<AIChapterSetSync>(
                predicate: #Predicate<AIChapterSetSync> { $0.id == chapterSetID }
            )
            let sourceDeviceID = ListeningDeviceIdentity.current().id

            if let chapterSet = try modelContext.fetch(descriptor).first {
                guard generatedAt >= chapterSet.generatedAt else { return }
                chapterSet.feedURL = identity.feedURL
                chapterSet.episodeID = identity.episodeID
                chapterSet.revisionID = encoded.hash
                chapterSet.payloadJSON = encoded.payload
                chapterSet.chapterCount = chapters.count
                chapterSet.contentHash = encoded.hash
                chapterSet.generatedAt = generatedAt
                chapterSet.updatedAt = now
                chapterSet.sourceDeviceID = sourceDeviceID
            } else {
                modelContext.insert(
                    AIChapterSetSync(
                        feedURL: identity.feedURL,
                        episodeID: identity.episodeID,
                        revisionID: encoded.hash,
                        payloadJSON: encoded.payload,
                        chapterCount: chapters.count,
                        contentHash: encoded.hash,
                        generatedAt: generatedAt,
                        updatedAt: now,
                        sourceDeviceID: sourceDeviceID
                    )
                )
            }

            try modelContext.save()
        } catch {
            CrashBreadcrumbs.shared.record(
                "store_split_ai_chapters_write_failed",
                details: error.localizedDescription
            )
        }
    }
}
