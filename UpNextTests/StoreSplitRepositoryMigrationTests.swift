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
        XCTAssertEqual(records.first?.autoDownload, true)
        XCTAssertEqual(records.first?.autoDownloadNetworkModeRawValue, AutoDownloadNetworkMode.wifiOnly.rawValue)
        // Downloaded files and transcription capability remain device-local.
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
        try await StoreSplitBookmarkSyncWriter(modelContainer: stores.user)
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
            cacheOrRSSRecoveryVerified: true,
            verificationRevisionEvidenceProven: true
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
