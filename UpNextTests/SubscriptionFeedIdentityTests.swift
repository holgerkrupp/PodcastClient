import XCTest
import SwiftData
@testable import UpNext

/// #441: subscription identity across URL variants, replaced private-feed URLs,
/// HTTP redirects and feeds that are gone. A subscription is never lost and
/// never duplicated.
final class SubscriptionFeedIdentityTests: XCTestCase {
    private func makeContainers() throws -> (library: ModelContainer, userState: ModelContainer) {
        (
            try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true),
            try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        )
    }

    @MainActor
    private func importSubscriptions(
        _ containers: (library: ModelContainer, userState: ModelContainer),
        credentialStore: any PodcastCredentialStore = InMemoryPodcastCredentialStore()
    ) async -> StoreSplitUserStateImportResult {
        await StoreSplitUserStateImporter.apply(
            legacyContainer: containers.library,
            userStateContainer: containers.userState,
            credentialStore: credentialStore,
            changedStreams: [.subscriptions],
            cursorSuiteName: nil
        )
    }

    private func podcasts(in container: ModelContainer) throws -> [Podcast] {
        try ModelContext(container).fetch(FetchDescriptor<Podcast>())
    }

    // MARK: - Duplicate records for one normalized identity

    @MainActor
    func testNewestOfTwoURLVariantRecordsDecidesSubscription() async throws {
        // The two spellings sort to different dedup keys but share comparison
        // keys, so both reach the one local podcast in the same pass.
        for newestIsSubscribed in [false, true] {
            let containers = try makeContainers()
            let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
            podcast.metaData = PodcastMetaData()
            containers.library.mainContext.insert(podcast)
            try containers.library.mainContext.save()

            let older = Date(timeIntervalSince1970: 1_000)
            let newer = Date(timeIntervalSince1970: 2_000)
            containers.userState.mainContext.insert(SubscriptionSync(
                feedURL: "https://example.com/feed.xml",
                isSubscribed: newestIsSubscribed,
                unsubscribedAt: newestIsSubscribed ? nil : newer,
                updatedAt: newer
            ))
            containers.userState.mainContext.insert(SubscriptionSync(
                feedURL: "https://example.com/Feed.xml",
                isSubscribed: !newestIsSubscribed,
                unsubscribedAt: newestIsSubscribed ? older : nil,
                updatedAt: older
            ))
            try containers.userState.mainContext.save()

            let result = await importSubscriptions(containers)

            XCTAssertEqual(result.failed, 0)
            let stored = try podcasts(in: containers.library)
            XCTAssertEqual(stored.count, 1, "URL variants must not create a second podcast")
            XCTAssertEqual(
                stored.first?.metaData?.isSubscribed,
                newestIsSubscribed,
                "the newest record wins regardless of iteration order"
            )
        }
    }

    // MARK: - Replaced private-feed URL

    private let oldPrivateFeed = URL(string: "https://example.com/premium/old-token/feed.xml")!
    private let newPrivateFeed = URL(string: "https://example.com/premium/new-token/feed.xml")!
    private let sharedProfileID = "podcast-access-replaced-url-fixture"

    @MainActor
    private func insertPrivateRecords(
        into container: ModelContainer,
        oldUpdatedAt: Date,
        newUpdatedAt: Date,
        newIsSubscribed: Bool = true
    ) throws {
        container.mainContext.insert(SubscriptionSync(
            feedURL: PodcastFeedIdentity.normalizedFeedURLString(oldPrivateFeed),
            accessProfileID: sharedProfileID,
            accessKindRawValue: PodcastAccessKind.privateURL.rawValue,
            isSubscribed: true,
            updatedAt: oldUpdatedAt
        ))
        container.mainContext.insert(SubscriptionSync(
            feedURL: PodcastFeedIdentity.normalizedFeedURLString(newPrivateFeed),
            accessProfileID: sharedProfileID,
            accessKindRawValue: PodcastAccessKind.privateURL.rawValue,
            isSubscribed: newIsSubscribed,
            unsubscribedAt: newIsSubscribed ? nil : newUpdatedAt,
            updatedAt: newUpdatedAt
        ))
        try container.mainContext.save()
    }

    @MainActor
    private func insertPrivatePodcast(feed: URL, into container: ModelContainer) throws {
        let podcast = Podcast(feed: feed)
        let metadata = PodcastMetaData()
        metadata.accessProfileID = sharedProfileID
        metadata.accessKindRawValue = PodcastAccessKind.privateURL.rawValue
        podcast.metaData = metadata
        container.mainContext.insert(podcast)
        try container.mainContext.save()
    }

    @MainActor
    func testDeviceWithOldURLMapsReplacedURLToItsPodcast() async throws {
        let containers = try makeContainers()
        try insertPrivatePodcast(feed: oldPrivateFeed, into: containers.library)
        try insertPrivateRecords(
            into: containers.userState,
            oldUpdatedAt: Date(timeIntervalSince1970: 1_000),
            newUpdatedAt: Date(timeIntervalSince1970: 2_000)
        )

        let result = await importSubscriptions(containers)

        XCTAssertEqual(result.failed, 0)
        let stored = try podcasts(in: containers.library)
        XCTAssertEqual(stored.count, 1, "the new URL must not become a second subscription")
        XCTAssertEqual(stored.first?.feed, oldPrivateFeed)
        XCTAssertEqual(stored.first?.metaData?.isSubscribed, true)
    }

    @MainActor
    func testDeviceThatSwitchedURLDoesNotRestoreTheOldURL() async throws {
        let containers = try makeContainers()
        try insertPrivatePodcast(feed: newPrivateFeed, into: containers.library)
        // The old URL's record is newer here: linking stamps it with the profile.
        try insertPrivateRecords(
            into: containers.userState,
            oldUpdatedAt: Date(timeIntervalSince1970: 3_000),
            newUpdatedAt: Date(timeIntervalSince1970: 2_000)
        )

        _ = await importSubscriptions(containers)

        let stored = try podcasts(in: containers.library)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.feed, newPrivateFeed)
        XCTAssertEqual(stored.first?.metaData?.isSubscribed, true)
    }

    @MainActor
    func testUnsubscribeUnderReplacedURLWinsOverOlderOldURLRecord() async throws {
        let containers = try makeContainers()
        try insertPrivatePodcast(feed: oldPrivateFeed, into: containers.library)
        try insertPrivateRecords(
            into: containers.userState,
            oldUpdatedAt: Date(timeIntervalSince1970: 1_000),
            newUpdatedAt: Date(timeIntervalSince1970: 2_000),
            newIsSubscribed: false
        )

        _ = await importSubscriptions(containers)

        let stored = try podcasts(in: containers.library)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.metaData?.isSubscribed, false)
    }

    @MainActor
    func testNewDeviceCreatesOnePodcastForBothURLsOfAReplacedFeed() async throws {
        let containers = try makeContainers()
        let now = Date()
        try insertPrivateRecords(
            into: containers.userState,
            oldUpdatedAt: now,
            newUpdatedAt: now.addingTimeInterval(1)
        )

        let result = await importSubscriptions(containers)

        let stored = try podcasts(in: containers.library)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.feed, newPrivateFeed, "the newest record creates the stub")
        XCTAssertEqual(stored.first?.metaData?.credentialState, .missing)
        XCTAssertEqual(result.feedsAwaitingCredentials.count, 1, "one podcast waits for credentials once")
    }

    // MARK: - Writer

    func testLinkingPreviousURLStampsProfileWithoutChangingSubscription() async throws {
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let previous = URL(string: "https://example.com/public/feed.xml")!
        let tombstoned = URL(string: "https://example.com/tombstoned/feed.xml")!
        let context = ModelContext(userState)
        context.insert(SubscriptionSync(
            feedURL: PodcastFeedIdentity.normalizedFeedURLString(previous),
            isSubscribed: true,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        context.insert(SubscriptionSync(
            feedURL: PodcastFeedIdentity.normalizedFeedURLString(tombstoned),
            isSubscribed: false,
            unsubscribedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        try context.save()
        let profile = PodcastAccessProfile(
            id: sharedProfileID,
            kind: .privateURL,
            resourceURL: newPrivateFeed
        )
        let writer = StoreSplitSubscriptionSyncWriter(modelContainer: userState)

        let linked = try await writer.linkPreviousFeedURL(previous, to: profile)
        let linkedAgain = try await writer.linkPreviousFeedURL(previous, to: profile)
        let tombstoneLinked = try await writer.linkPreviousFeedURL(tombstoned, to: profile)
        let missingLinked = try await writer.linkPreviousFeedURL(oldPrivateFeed, to: profile)

        XCTAssertTrue(linked)
        XCTAssertFalse(linkedAgain)
        XCTAssertFalse(tombstoneLinked, "a tombstone must not become the newest record")
        XCTAssertFalse(missingLinked)
        let rows = try ModelContext(userState).fetch(FetchDescriptor<SubscriptionSync>())
        XCTAssertEqual(rows.count, 2, "linking never creates a record for the old URL")
        let previousRow = try XCTUnwrap(rows.first { $0.feedURL.contains("public") })
        XCTAssertEqual(previousRow.accessProfileID, sharedProfileID)
        XCTAssertTrue(previousRow.isSubscribed)
        XCTAssertNil(previousRow.unsubscribedAt)
        XCTAssertNil(rows.first { $0.feedURL.contains("tombstoned") }?.accessProfileID)
    }

    // MARK: - Fixture server: redirects and gone feeds

    private func fixtureBaseURL() async throws -> String {
        let baseURL = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_BASE"]
            ?? "http://127.0.0.1:8787"
        guard let probe = URL(string: baseURL + "/fast/0") else {
            throw XCTSkip("Invalid fixture server URL")
        }
        do {
            var request = URLRequest(url: probe)
            request.timeoutInterval = 1
            _ = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("Start Scripts/podcast-refresh-fixture-server.py")
        }
        return baseURL
    }

    func testFixtureRedirectsNeverRewriteTheStoredFeedURL() async throws {
        let baseURL = try await fixtureBaseURL()
        for (index, status) in [301, 302, 307, 308].enumerated() {
            let feed = try XCTUnwrap(URL(
                string: baseURL + "/redirect-\(status)/\(90 + index)?run=\(UUID().uuidString)"
            ))
            let container = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
            let context = ModelContext(container)
            let podcast = Podcast(feed: feed)
            podcast.metaData = PodcastMetaData()
            context.insert(podcast)
            try context.save()
            let worker = PodcastModelActor(modelContainer: container)

            let first = try await worker.updatePodcastWithSummary(
                feed, policy: .manualSingle, silent: true, resolveExistingMissingDurations: false
            )
            // The second refresh verifies redirected content against the
            // episodes the first one imported.
            _ = try await worker.updatePodcastWithSummary(
                feed, policy: .manualSingle, silent: true, resolveExistingMissingDurations: false
            )

            XCTAssertTrue(first.didUpdateFeed, "HTTP \(status)")
            let stored = try ModelContext(container).fetch(FetchDescriptor<Podcast>())
            XCTAssertEqual(stored.count, 1, "HTTP \(status)")
            XCTAssertEqual(stored.first?.feed, feed, "HTTP \(status) must keep the subscribed URL")
            XCTAssertEqual(stored.first?.metaData?.isSubscribed, true, "HTTP \(status)")
            XCTAssertFalse(stored.first?.episodes?.isEmpty ?? true, "HTTP \(status)")
            XCTAssertNil(stored.first?.metaData?.lastFeedFailureStatusCode, "HTTP \(status)")
        }
    }

    func testFixtureGoneOrMissingFeedKeepsSubscriptionWithFailureStatus() async throws {
        let baseURL = try await fixtureBaseURL()
        for (profile, status) in [("gone", 410), ("missing", 404)] {
            let feed = try XCTUnwrap(URL(string: baseURL + "/\(profile)/1?run=\(UUID().uuidString)"))
            let container = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
            let context = ModelContext(container)
            let podcast = Podcast(feed: feed)
            podcast.metaData = PodcastMetaData()
            context.insert(podcast)
            try context.save()
            let worker = PodcastModelActor(modelContainer: container)

            do {
                _ = try await worker.updatePodcastWithSummary(
                    feed, policy: .manualSingle, silent: true, resolveExistingMissingDurations: false
                )
                XCTFail("HTTP \(status) should fail the refresh")
            } catch {}

            let stored = try ModelContext(container).fetch(FetchDescriptor<Podcast>())
            XCTAssertEqual(stored.count, 1, "HTTP \(status) must not delete the podcast")
            XCTAssertEqual(stored.first?.feed, feed)
            XCTAssertEqual(stored.first?.metaData?.isSubscribed, true, "HTTP \(status) must not unsubscribe")
            XCTAssertEqual(stored.first?.metaData?.lastFeedFailureStatusCode, status)
            XCTAssertGreaterThanOrEqual(stored.first?.metaData?.consecutiveFeedFailureCount ?? 0, 1)
        }
    }
}
