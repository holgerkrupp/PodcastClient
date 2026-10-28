import SwiftData
import XCTest
@testable import UpNext

final class StoreSplitAIContentImporterRetryTests: XCTestCase {
    @MainActor
    func testInvalidTranscriptRevisionDoesNotBlockRetryAfterManifestRepair() async throws {
        let legacyContainer = try ModelContainerManager.makeLegacyContainer(
            isStoredInMemoryOnly: true
        )
        let cacheContainer = try ModelContainerManager.makeCacheContainer(
            isStoredInMemoryOnly: true
        )
        let podcast = Podcast(feed: URL(string: "https://example.com/retry-ai.xml")!)
        let episode = Episode(
            guid: "retry-ai-episode",
            title: "Retry AI Episode",
            url: URL(string: "https://example.com/retry-ai.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        legacyContainer.mainContext.insert(podcast)
        try legacyContainer.mainContext.save()

        let identity = episode.stableEpisodeIdentity
        let encoded = try AIContentSyncCodec.encodeTranscript([
            AITranscriptLineValue(
                speaker: "Host",
                text: "Recovered on retry",
                startTime: 12,
                endTime: 18
            )
        ])
        let manifest = AITranscriptSync(
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            revisionID: encoded.revisionID,
            localeIdentifier: "en",
            chunkCount: encoded.chunks.count,
            lineCount: encoded.lineCount,
            contentHash: "temporarily-invalid",
            generatedAt: Date(timeIntervalSince1970: 2_000)
        )
        cacheContainer.mainContext.insert(manifest)
        for (index, payload) in encoded.chunks.enumerated() {
            cacheContainer.mainContext.insert(
                AITranscriptChunkSync(
                    transcriptID: identity.key,
                    revisionID: encoded.revisionID,
                    chunkIndex: index,
                    payloadJSON: payload,
                    contentHash: AIContentSyncCodec.sha256Hex(Data(payload.utf8))
                )
            )
        }
        try cacheContainer.mainContext.save()

        let firstAttempt = await StoreSplitAIContentImporter.apply(
            legacyContainer: legacyContainer,
            cacheContainer: cacheContainer
        )
        XCTAssertEqual(firstAttempt.transcriptsApplied, 0)
        XCTAssertEqual(firstAttempt.failed, 1)
        XCTAssertTrue(
            try ModelContext(cacheContainer).fetch(FetchDescriptor<CachedTranscriptLine>()).isEmpty
        )

        manifest.contentHash = encoded.contentHash
        try cacheContainer.mainContext.save()

        let retry = await StoreSplitAIContentImporter.apply(
            legacyContainer: legacyContainer,
            cacheContainer: cacheContainer
        )
        XCTAssertEqual(retry.transcriptsApplied, 1)
        XCTAssertEqual(retry.failed, 0)
        let lines = try ModelContext(cacheContainer).fetch(
            FetchDescriptor<CachedTranscriptLine>()
        ).filter { $0.episodeID == identity.key }
        XCTAssertEqual(lines.map(\.text), ["Recovered on retry"])
    }
}
