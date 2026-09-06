import SwiftData
import XCTest
@testable import UpNext

/// Covers the cost side of the user-state import.
///
/// Every phase of the importer pages its source table and resolves each page's
/// rows to local episodes. Rows that cannot be resolved — state synced from
/// another device for an episode this device never fetched — fall through to a
/// last-resort scan that pages the whole feed.
///
/// That scan ran once per page of synced state, because nothing remembered that
/// the feed had already been walked: the identity miss cache stored misses as a
/// `nil` value in a dictionary whose value type was itself optional (which
/// removes the key rather than recording it), and each page brought fresh
/// unresolvable identities for the same feed anyway. On a real library that is
/// pages × feeds × episodes of row materialisation, and it pinned the CPU until
/// iOS killed the backgrounded process for exceeding its 80%-of-60-seconds
/// limit.
final class StoreSplitUserStateResolutionCacheTests: XCTestCase {
    private let feedURL = URL(string: "https://example.com/resolution-cache")!

    /// Enough synced state rows to span several pages of the importer's
    /// 200-row source paging, all of them unresolvable.
    private let unresolvableStateCount = 900

    @MainActor
    func testUnresolvableEpisodeStatesScanTheFeedOnlyOnce() async throws {
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)

        // A real, subscribed podcast: the feed resolves to a local Podcast, so
        // the last-resort scan is reachable. Its episodes are not the ones the
        // synced state rows name.
        let podcast = Podcast(feed: feedURL)
        var episodes: [Episode] = []
        for index in 0..<40 {
            let episode = Episode(
                guid: "local-episode-\(index)",
                title: "Local \(index)",
                url: URL(string: "https://example.com/local-\(index).mp3")!,
                podcast: podcast
            )
            episodes.append(episode)
            runtime.mainContext.insert(episode)
        }
        podcast.episodes = episodes
        runtime.mainContext.insert(podcast)
        try runtime.mainContext.save()

        let now = Date()
        for index in 0..<unresolvableStateCount {
            userState.mainContext.insert(EpisodeStateSync(
                feedURL: feedURL.absoluteString,
                episodeID: "guid:absent-episode-\(index)",
                playPosition: 30,
                maxPlayPosition: 30,
                lastPlayedAt: now,
                updatedAt: now
            ))
        }
        try userState.mainContext.save()

        StoreSplitUserStateImporter.debugFeedScanCount = 0
        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: runtime,
            userStateContainer: userState,
            projectListeningHistoryToLegacy: false
        )

        // One feed, one scan. Before the fix this was one scan per page of
        // `EpisodeStateSync` — five here, and hundreds on a real library.
        XCTAssertEqual(StoreSplitUserStateImporter.debugFeedScanCount, 1)
    }

    /// Caching a feed as fully scanned must not cost the import any resolution
    /// it would otherwise have made: a hit and a miss on the same page still
    /// project correctly.
    @MainActor
    func testResolvableStateStillProjectsWithTheNegativeCacheInPlace() async throws {
        let runtime = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)

        let podcast = Podcast(feed: feedURL)
        let episode = Episode(
            guid: "resolvable-episode",
            title: "Resolvable",
            url: URL(string: "https://example.com/resolvable.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        runtime.mainContext.insert(podcast)
        runtime.mainContext.insert(episode)
        try runtime.mainContext.save()

        let now = Date()
        let identity = episode.stableEpisodeIdentity
        userState.mainContext.insert(EpisodeStateSync(
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            playPosition: 420,
            maxPlayPosition: 420,
            lastPlayedAt: now,
            updatedAt: now
        ))
        // A miss alongside the hit, so the negative cache is exercised on the
        // same page that resolves something.
        userState.mainContext.insert(EpisodeStateSync(
            feedURL: feedURL.absoluteString,
            episodeID: "guid:absent-episode",
            playPosition: 10,
            maxPlayPosition: 10,
            lastPlayedAt: now,
            updatedAt: now
        ))
        try userState.mainContext.save()

        _ = await StoreSplitUserStateImporter.apply(
            legacyContainer: runtime,
            userStateContainer: userState,
            projectListeningHistoryToLegacy: false
        )

        let context = ModelContext(runtime)
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.guid == "resolvable-episode" }
        )
        descriptor.fetchLimit = 1
        let projected = try XCTUnwrap(context.fetch(descriptor).first)
        XCTAssertEqual(projected.metaData?.playPosition, 420)
    }
}
