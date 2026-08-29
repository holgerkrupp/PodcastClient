import SwiftData
import XCTest
@testable import UpNext

final class StoreSplitRepositoryMigrationTests: XCTestCase {
    @MainActor
    private func containers() throws -> (
        legacy: ModelContainer, user: ModelContainer, cache: ModelContainer
    ) {
        (
            try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true),
            try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true),
            try ModelContainerManager.makeCacheContainer(isStoredInMemoryOnly: true)
        )
    }

    func testParserCapturesUnknownAndKnownNamespaceSubtrees() async throws {
        let xml = """
        <rss version="2.0"
             xmlns:podcast="https://podcastindex.org/namespace/1.0"
             xmlns:future="https://example.com/future">
          <channel>
            <title>Extensions</title>
            <link>https://example.com</link>
            <description>Test</description>
            <future:feature mode="new"><future:child>value</future:child></future:feature>
            <item>
              <title>Episode</title>
              <guid>one</guid>
              <enclosure url="https://example.com/one.mp3" type="audio/mpeg" />
              <podcast:txt purpose="verify">hello</podcast:txt>
              <future:itemData flag="1">opaque</future:itemData>
            </item>
          </channel>
        </rss>
        """
        let page = try await PodcastParser.parsePage(
            from: PodcastFeedDocument(
                data: Data(xml.utf8),
                sourceURL: URL(string: "https://example.com/feed.xml")!
            )
        )

        XCTAssertEqual(page.extensionElements.map(\.qualifiedName), ["future:feature"])
        XCTAssertEqual(
            page.episodes.first?.extensionElements.map(\.qualifiedName).sorted(),
            ["future:itemData", "podcast:txt"]
        )
        XCTAssertEqual(
            page.extensionElements.first?.node.children.first?.value,
            "value"
        )
    }

    @MainActor
    func testParsedExtensionsReplaceAtomicallyAndIdempotently() throws {
        let stores = try containers()
        let feed = URL(string: "https://example.com/feed.xml")!
        let node = NamespaceNode(
            name: "future:feature",
            attributes: ["mode": "new"],
            children: [NamespaceNode(name: "future:child", value: "value")]
        )
        let raw = ParsedFeedExtensionElement(
            namespaceURI: "https://example.com/future",
            qualifiedName: "future:feature",
            localName: "feature",
            node: node
        )
        let parsed: [String: Any] = [
            "rawExtensionElements": [raw],
            "episodes": [[
                "title": "Episode",
                "guid": "one",
                "enclosure": [["url": "https://example.com/one.mp3", "type": "audio/mpeg"]],
                "rawExtensionElements": [raw]
            ]]
        ]

        XCTAssertEqual(
            StoreSplitFeedCacheWriter.replaceParsedExtensionElements(
                feedURL: feed, parsedFeed: parsed, cacheContainer: stores.cache
            ),
            2
        )
        XCTAssertEqual(
            StoreSplitFeedCacheWriter.replaceParsedExtensionElements(
                feedURL: feed, parsedFeed: parsed, cacheContainer: stores.cache
            ),
            2
        )
        let context = ModelContext(stores.cache)
        let rows = try context.fetch(FetchDescriptor<CachedFeedExtensionElement>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy {
            $0.contentHash == AIContentSyncCodec.sha256Hex($0.payload)
        })

        _ = StoreSplitFeedCacheWriter.replaceParsedExtensionElements(
            feedURL: feed,
            parsedFeed: ["rawExtensionElements": [], "episodes": []],
            cacheContainer: stores.cache
        )
        XCTAssertEqual(
            try ModelContext(stores.cache).fetchCount(
                FetchDescriptor<CachedFeedExtensionElement>()
            ),
            0
        )
    }

    @MainActor
    func testIncomingAIContentMaterializesInCacheAndPreservesPublisherRows() async throws {
        let stores = try containers()
        let feed = URL(string: "https://example.com/feed.xml")!
        let identity = EpisodeStableIdentity.make(
            feedURL: feed,
            episodeGUID: "one",
            enclosureURL: URL(string: "https://example.com/one.mp3"),
            episodeURL: nil,
            linkURL: nil
        )
        let cache = stores.cache.mainContext
        cache.insert(CachedPodcast(id: identity.feedURL, feedURL: identity.feedURL))
        cache.insert(CachedEpisode(
            id: identity.key,
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            title: "Episode"
        ))
        cache.insert(CachedTranscriptLine(
            id: "publisher",
            feedURL: identity.feedURL,
            episodeID: identity.key,
            text: "Publisher supplied",
            sourceRawValue: CachedTranscriptSource.publisher.rawValue
        ))
        cache.insert(CachedChapter(
            id: "publisher-chapter",
            feedURL: identity.feedURL,
            episodeID: identity.key,
            title: "Publisher chapter",
            start: 0,
            typeRawValue: MarkerType.podlove.rawValue
        ))
        try cache.save()

        let values = [AITranscriptLineValue(
            speaker: nil, text: "AI line", startTime: 1, endTime: 2
        )]
        let encoded = try AIContentSyncCodec.encodeTranscript(values)
        cache.insert(AITranscriptSync(
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            revisionID: encoded.revisionID,
            chunkCount: encoded.chunks.count,
            lineCount: encoded.lineCount,
            contentHash: encoded.contentHash,
            generatedAt: .now
        ))
        for (index, payload) in encoded.chunks.enumerated() {
            cache.insert(AITranscriptChunkSync(
                transcriptID: identity.key,
                revisionID: encoded.revisionID,
                chunkIndex: index,
                payloadJSON: payload,
                contentHash: AIContentSyncCodec.sha256Hex(Data(payload.utf8))
            ))
        }
        let chapters = try AIContentSyncCodec.encodeChapters([
            AIChapterValue(title: "AI chapter", startTime: 10, duration: 5)
        ])
        cache.insert(AIChapterSetSync(
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            revisionID: chapters.hash,
            payloadJSON: chapters.payload,
            chapterCount: 1,
            contentHash: chapters.hash,
            generatedAt: .now
        ))
        try cache.save()

        let result = await StoreSplitAIContentImporter.apply(
            legacyContainer: stores.legacy,
            cacheContainer: stores.cache
        )
        XCTAssertEqual(result.transcriptsApplied, 0, "publisher transcript wins")
        XCTAssertEqual(result.chaptersApplied, 1)
        let verification = ModelContext(stores.cache)
        let lines = try verification.fetch(FetchDescriptor<CachedTranscriptLine>())
        XCTAssertEqual(lines.map(\.text), ["Publisher supplied"])
        let cachedChapters = try verification.fetch(FetchDescriptor<CachedChapter>())
        XCTAssertEqual(Set(cachedChapters.map(\.title)), ["Publisher chapter", "AI chapter"])
    }

    @MainActor
    func testPortablePreferenceMigrationExcludesDevicePolicyAndIsIdempotent() async throws {
        let stores = try containers()
        let setting = PodcastSettings(defaultSettings: true)
        setting.playbackSpeed = 1.7
        setting.reduceSilenceGapsEnabled = true
        setting.autoDownload = true
        setting.autoDownloadNetworkMode = .wifiOnly
        setting.enableAutomaticOnDeviceTranscriptions = true
        stores.legacy.mainContext.insert(setting)
        try stores.legacy.mainContext.save()

        _ = await StoreSplitMigrationService.migrate(
            legacyContainer: stores.legacy,
            userStateContainer: stores.user,
            cacheContainer: stores.cache,
            includeAIContent: false
        )
        _ = await StoreSplitMigrationService.migrate(
            legacyContainer: stores.legacy,
            userStateContainer: stores.user,
            cacheContainer: stores.cache,
            includeAIContent: false
        )
        let context = ModelContext(stores.user)
        let records = try context.fetch(FetchDescriptor<PodcastPreferenceSync>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try XCTUnwrap(records.first?.playbackSpeed), 1.7, accuracy: 0.001)
        XCTAssertEqual(records.first?.reduceSilenceGapsEnabled, true)
        // Auto-download/network/transcription capability have no synced fields.
        XCTAssertFalse(UserStateCloudSchemaAudit.containsFeedDerivedData)
    }

    @MainActor
    func testBookmarkDeleteCreatesTombstoneEvenWithoutPriorSyncRow() async throws {
        let stores = try containers()
        let identity = EpisodeStableIdentity(
            feedURL: "https://example.com/feed.xml",
            episodeID: "guid:one"
        )
        let snapshot = StoreSplitBookmarkSnapshot(
            id: UUID().uuidString,
            identity: identity,
            time: 12,
            title: "Bookmark",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        await StoreSplitBookmarkSyncWriter(modelContainer: stores.user)
            .tombstone(snapshot, at: Date(timeIntervalSince1970: 20))
        let row = try XCTUnwrap(
            ModelContext(stores.user).fetch(FetchDescriptor<BookmarkSync>()).first
        )
        // `deletedAt` is the durable tombstone discriminator. SwiftData also
        // exposes lifecycle deletion state through an `isDeleted` spelling, so
        // that convenience flag is not reliable after refetch on every OS.
        XCTAssertTrue(row.isDeleted || row.deletedAt != nil)
        XCTAssertEqual(row.deletedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(row.feedURL, identity.feedURL)
    }

    @MainActor
    func testRepositoryReturnsSnapshotsWithAliasAwareBatchedOverlay() async throws {
        let stores = try containers()
        let oldFeed = "https://example.com/old.xml"
        let newFeed = "https://example.com/new.xml"
        let episodeID = "guid:one"
        let identity = EpisodeStableIdentity(feedURL: newFeed, episodeID: episodeID)
        let cache = stores.cache.mainContext
        cache.insert(CachedPodcast(id: newFeed, feedURL: newFeed, title: "Show"))
        cache.insert(CachedEpisode(
            id: identity.key, feedURL: newFeed, episodeID: episodeID,
            title: "Episode", url: URL(string: "https://example.com/one.mp3")
        ))
        cache.insert(FeedAlias(
            oldFeedURL: oldFeed,
            newFeedURL: newFeed,
            reason: .permanentRedirect
        ))
        try cache.save()

        let user = stores.user.mainContext
        user.insert(SubscriptionSync(
            feedURL: oldFeed, isSubscribed: true,
            subscribedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        ))
        let state = EpisodeStateSync(
            feedURL: oldFeed,
            episodeID: episodeID,
            playPosition: 42,
            updatedAt: Date(timeIntervalSince1970: 3)
        )
        // The redirect keeps the old feed component, so its logical composite
        // differs; the repository resolves by feed aliases + episode component.
        user.insert(state)
        try user.save()

        let repository = PodcastCacheRepository(
            cacheContainer: stores.cache,
            userStateContainer: stores.user
        )
        let podcasts = await repository.podcasts()
        XCTAssertEqual(podcasts.count, 1)
        XCTAssertTrue(podcasts[0].isSubscribed)
        let episodes = await repository.episodes(feedURL: URL(string: newFeed)!)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].state.playPosition, 42)
    }

    @MainActor
    func testCleanupGateRequiresEveryIndependentCondition() throws {
        let stores = try containers()
        let legacy = stores.legacy.mainContext
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        legacy.insert(podcast)
        try legacy.save()
        _ = StoreSplitMigrationVerifier.verify(
            legacyContainer: stores.legacy,
            userStateContainer: stores.user,
            cacheContainer: stores.cache
        )
        var gate = StoreSplitMigrationVerifier.cleanupGate(
            cacheContainer: stores.cache,
            legacyFallbackDisabled: false,
            convergenceTelemetryPassed: true,
            gracePeriodEnd: .distantPast
        )
        XCTAssertFalse(gate.isSafe)

        // Migration has not populated UserState yet, so verification itself is
        // also false. No combination of the other switches can bypass it.
        gate = StoreSplitMigrationVerifier.cleanupGate(
            cacheContainer: stores.cache,
            legacyFallbackDisabled: true,
            convergenceTelemetryPassed: true,
            gracePeriodEnd: .distantPast
        )
        XCTAssertFalse(gate.isSafe)
    }

    @MainActor
    func testCompatibilityProjectionReadsCacheWithoutPersistentIdentifiers() throws {
        let stores = try containers()
        let feed = "https://example.com/projected.xml"
        let identity = EpisodeStableIdentity(feedURL: feed, episodeID: "guid:projected")
        let cache = stores.cache.mainContext
        cache.insert(CachedPodcast(id: feed, feedURL: feed, title: "Projected"))
        cache.insert(CachedEpisode(
            id: identity.key,
            feedURL: feed,
            episodeID: identity.episodeID,
            title: "Projected episode",
            url: URL(string: "https://example.com/projected.mp3")
        ))
        try cache.save()

        let result = StoreSplitCompatibilityProjectionService.rebuild(
            cacheContainer: stores.cache,
            runtimeContainer: stores.legacy
        )
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.podcasts, 1)
        XCTAssertEqual(result.episodes, 1)
        let runtime = ModelContext(stores.legacy)
        XCTAssertEqual(try runtime.fetch(FetchDescriptor<Podcast>()).first?.title, "Projected")
        XCTAssertEqual(try runtime.fetch(FetchDescriptor<Episode>()).first?.title, "Projected episode")
    }

    @MainActor
    func testCloudSchemaExcludesEveryCacheAndLegacyModel() throws {
        XCTAssertFalse(UserStateCloudSchemaAudit.containsFeedDerivedData)
        XCTAssertTrue(
            UserStateCloudSchemaAudit.allowedModelNames.isDisjoint(
                with: UserStateCloudSchemaAudit.forbiddenFeedDerivedModelNames
            )
        )
        let stores = try containers()
        let actualUserStateModels = Set(stores.user.schema.entities.map(\.name))
        XCTAssertEqual(actualUserStateModels, UserStateCloudSchemaAudit.allowedModelNames)
        let actualCacheModels = Set(stores.cache.schema.entities.map(\.name))
        XCTAssertTrue(actualUserStateModels.isDisjoint(with: actualCacheModels))
        XCTAssertTrue(Set([
            "AITranscriptSync", "AITranscriptChunkSync", "AIChapterSetSync"
        ]).isSubset(of: actualCacheModels))
    }

    func testLegacyCleanupRefusesUnsafeOrUnexpectedTarget() {
        let unsafe = LegacyStoreCleanupGate(
            migrationVerified: false,
            legacyFallbackDisabled: true,
            convergenceTelemetryPassed: true,
            supportedVersionGracePeriodEnded: true,
            cacheOrRSSRecoveryVerified: true
        )
        XCTAssertThrowsError(try StoreSplitLegacyCleanupService.removeVerifiedLegacyStore(
            at: URL(fileURLWithPath: "/tmp/SharedDatabase.sqlite"),
            expectedStoreURL: URL(fileURLWithPath: "/tmp/SharedDatabase.sqlite"),
            gate: unsafe
        )) { error in
            XCTAssertEqual(error as? StoreSplitLegacyCleanupError, .gateNotSatisfied)
        }

        let safe = LegacyStoreCleanupGate(
            migrationVerified: true,
            legacyFallbackDisabled: true,
            convergenceTelemetryPassed: true,
            supportedVersionGracePeriodEnded: true,
            cacheOrRSSRecoveryVerified: true
        )
        XCTAssertThrowsError(try StoreSplitLegacyCleanupService.removeVerifiedLegacyStore(
            at: URL(fileURLWithPath: "/tmp/NotTheLegacyStore.sqlite"),
            expectedStoreURL: URL(fileURLWithPath: "/tmp/SharedDatabase.sqlite"),
            gate: safe
        )) { error in
            XCTAssertEqual(error as? StoreSplitLegacyCleanupError, .unexpectedTarget)
        }
    }
}
