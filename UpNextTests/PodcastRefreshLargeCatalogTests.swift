import Foundation
import SwiftData
import XCTest
@testable import UpNext

/// Opt-in large back-catalog measurements for issue #432. They print timings
/// for 10/1k/5k-episode feeds on an on-disk store and compare the two ways of
/// collecting a podcast's known episode identities. Simulator numbers only
/// show scaling; physical-device baselines are tracked separately.
final class PodcastRefreshLargeCatalogTests: XCTestCase {
    private func makeDiskContainer() throws -> ModelContainer {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PodcastRefreshLargeCatalog-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(
            url: directory.appending(path: "Library.sqlite"),
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            Episode.self,
            EpisodeMetaData.self,
            Playlist.self,
            PlaylistEntry.self,
            Marker.self,
            Bookmark.self,
            RateSegment.self,
            PlaySession.self,
            ListeningStat.self,
            PlaySessionSummary.self,
            TranscriptionRecord.self,
            configurations: configuration
        )
    }

    private func fixtureBaseURL() async throws -> String {
        guard ProcessInfo.processInfo.environment["PODCAST_REFRESH_PERFORMANCE"] == "1" else {
            throw XCTSkip("Set PODCAST_REFRESH_PERFORMANCE=1 for large-catalog measurements")
        }
        let baseURL = ProcessInfo.processInfo.environment["PODCAST_REFRESH_FIXTURE_BASE"]
            ?? "http://127.0.0.1:8787"
        var request = URLRequest(url: URL(string: baseURL + "/fast/0")!)
        request.timeoutInterval = 1
        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("Start Scripts/podcast-refresh-fixture-server.py first")
        }
        return baseURL
    }

    private func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    func testLargeCatalogRefreshAndIdentityLookupScaling() async throws {
        let baseURL = try await fixtureBaseURL()
        for episodeCount in [10, 1_000, 5_000] {
            let container = try makeDiskContainer()
            let feed = URL(string: "\(baseURL)/fast/90?run=\(UUID().uuidString)&episodes=\(episodeCount)")!
            let setup = ModelContext(container)
            setup.insert(Podcast(feed: feed))
            try setup.save()
            let worker = PodcastModelActor(modelContainer: container)

            var start = ContinuousClock.now
            _ = try await worker.updatePodcastWithSummary(feed, policy: .manualSingle, silent: true)
            let initialImport = milliseconds(start)

            let readContext = ModelContext(container)
            XCTAssertEqual(try readContext.fetchCount(FetchDescriptor<Episode>()), episodeCount)

            // Every parsed episode is known: the import is trimmed to nothing,
            // so this is GET + parse + known-identity collection.
            start = ContinuousClock.now
            _ = try await worker.updatePodcastWithSummary(feed, policy: .manualSingle, silent: true)
            let knownRefresh = milliseconds(start)

            // Untrimmed import: every parsed item goes through the bounded
            // GUID/URL lookup and matches an existing row.
            start = ContinuousClock.now
            let bootstrapped = try await worker.bootstrapPodcast(feed, maximumEpisodes: episodeCount)
            let fullMatchImport = milliseconds(start)
            XCTAssertTrue(bootstrapped)
            XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Episode>()), episodeCount)

            // Compare the two identity-collection shapes on fresh contexts.
            let podcastID = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Podcast>()).first)
                .persistentModelID
            start = ContinuousClock.now
            let relationshipContext = ModelContext(container)
            let podcast = try XCTUnwrap(relationshipContext.model(for: podcastID) as? Podcast)
            var relationshipIdentities = Set<String>()
            for episode in podcast.episodes ?? [] {
                if let guid = episode.guid { relationshipIdentities.insert(guid) }
                if let url = episode.url?.absoluteString { relationshipIdentities.insert(url) }
                if let link = episode.link?.absoluteString { relationshipIdentities.insert(link) }
            }
            let relationshipTraversal = milliseconds(start)

            start = ContinuousClock.now
            let fetchContext = ModelContext(container)
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { episode in
                    episode.podcast?.persistentModelID == podcastID
                }
            )
            descriptor.propertiesToFetch = [\.guid, \.url, \.link]
            var fetchedIdentities = Set<String>()
            for episode in try fetchContext.fetch(descriptor) {
                if let guid = episode.guid { fetchedIdentities.insert(guid) }
                if let url = episode.url?.absoluteString { fetchedIdentities.insert(url) }
                if let link = episode.link?.absoluteString { fetchedIdentities.insert(link) }
            }
            let scopedFetch = milliseconds(start)
            XCTAssertEqual(fetchedIdentities, relationshipIdentities)

            // Same import when the feed provides itunes:duration: no remote
            // MP3 duration read per new episode.
            let timedContainer = try makeDiskContainer()
            let timedFeed = URL(
                string: "\(baseURL)/fast/91?run=\(UUID().uuidString)&episodes=\(episodeCount)&durations=1"
            )!
            let timedSetup = ModelContext(timedContainer)
            timedSetup.insert(Podcast(feed: timedFeed))
            try timedSetup.save()
            start = ContinuousClock.now
            _ = try await PodcastModelActor(modelContainer: timedContainer)
                .updatePodcastWithSummary(timedFeed, policy: .manualSingle, silent: true)
            let initialImportWithDurations = milliseconds(start)

            print(String(
                format: "PodcastRefreshLargeCatalog episodes=%d initial_import_ms=%.1f "
                    + "initial_import_with_feed_durations_ms=%.1f "
                    + "known_refresh_ms=%.1f full_match_import_ms=%.1f "
                    + "identity_relationship_ms=%.1f identity_fetch_ms=%.1f",
                episodeCount,
                initialImport,
                initialImportWithDurations,
                knownRefresh,
                fullMatchImport,
                relationshipTraversal,
                scopedFetch
            ))
        }
    }
}
