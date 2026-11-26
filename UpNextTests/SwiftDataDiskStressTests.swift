import SwiftData
import XCTest
@testable import UpNext

#if os(iOS)

/// Disk-backed query/crash stress coverage for #291 and #348.
///
/// Every fixture is written with one container, closed, and read through a
/// freshly opened container on the same SQLite file so the queries run against
/// persisted rows rather than registered in-memory objects. Expected results
/// are computed by walking unfiltered fetches in memory, never by the
/// predicates under test.
///
/// The 10,000-episode case is opt-in: run with
/// `TEST_RUNNER_SWIFTDATA_STRESS_10K=1 xcodebuild … test`.
final class SwiftDataDiskStressTests: XCTestCase {
    private static let selectedFeed = URL(string: "https://example.com/stress/selected.xml")!
    private static let otherFeed = URL(string: "https://example.com/stress/other.xml")!
    private static let duplicateURL = URL(string: "https://example.com/stress/s/dup.mp3")!

    private static func selectedURL(_ index: Int) -> URL {
        URL(string: "https://example.com/stress/s/ep-\(index).mp3")!
    }

    func testReopenedSQLiteQueriesMatchFixtureTruthAtScale() async throws {
        var counts = [0, 1, 100, 1_000]
        if ProcessInfo.processInfo.environment["SWIFTDATA_STRESS_10K"] == "1" {
            counts.append(10_000)
        }
        for count in counts {
            try await verifyReopenedFixture(episodeCount: count)
        }
    }

    // MARK: - Scaled fixture

    private func verifyReopenedFixture(episodeCount count: Int) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftDataDiskStress-\(count)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Stress.sqlite")

        try writeFixture(episodeCount: count, storeURL: storeURL)

        let container = try Self.makeContainer(storeURL: storeURL)
        let reader = ModelContext(container)
        let label = "count=\(count)"

        // Fixture truth from unfiltered fetches.
        let podcasts = try reader.fetch(FetchDescriptor<Podcast>())
        let selected = try XCTUnwrap(podcasts.first { $0.feed == Self.selectedFeed }, label)
        let selectedID = selected.persistentModelID
        let allEpisodes = try reader.fetch(FetchDescriptor<Episode>())
        let allLines = try reader.fetch(FetchDescriptor<TranscriptLineAndTime>())
        let selectedEpisodes = allEpisodes.filter { $0.podcast?.persistentModelID == selectedID }
        XCTAssertEqual(selectedEpisodes.count, count, label)
        let episodesByID = Dictionary(uniqueKeysWithValues: allEpisodes.map { ($0.persistentModelID, $0) })

        // Filter actor: membership, existence and sort order.
        let filter = PodcastEpisodeFilterActor(modelContainer: container)
        let newest = try await filter.episodeIDs(podcastID: selectedID, request: Self.request(.newestFirst))
        XCTAssertEqual(Set(newest.episodeIDs), Set(selectedEpisodes.map(\.persistentModelID)), label)
        XCTAssertEqual(newest.episodeIDs.count, count, label)
        XCTAssertEqual(newest.podcastHasEpisodes, count > 0, label)
        XCTAssertEqual(newest.episodeURLs, newest.episodeIDs.map { episodesByID[$0]?.url }, label)
        let newestDates = newest.episodeIDs.map { episodesByID[$0]?.publishDate ?? .distantPast }
        XCTAssertEqual(newestDates, newestDates.sorted(by: >), "\(label): newest-first order")

        let oldest = try await filter.episodeIDs(podcastID: selectedID, request: Self.request(.oldestFirst))
        let oldestDates = oldest.episodeIDs.map { episodesByID[$0]?.publishDate ?? .distantFuture }
        XCTAssertEqual(oldestDates, oldestDates.sorted(), "\(label): oldest-first order")

        let titleAZ = try await filter.episodeIDs(podcastID: selectedID, request: Self.request(.titleAZ))
        let titles = titleAZ.episodeIDs.compactMap { episodesByID[$0]?.title }
        XCTAssertEqual(
            titles,
            titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            "\(label): title order"
        )

        // Visible pages resolve to exactly the actor's IDs, in order.
        for range in [0..<min(80, count), min(80, count)..<min(160, count)] where range.isEmpty == false {
            let page = try reader.episodes(
                forPageIDs: Array(newest.episodeIDs[range]),
                urls: Array(newest.episodeURLs[range])
            )
            XCTAssertEqual(page.map(\.persistentModelID), Array(newest.episodeIDs[range]), "\(label) page \(range)")
        }

        // URL lookup: deduplicated input, every episode sharing a URL
        // (including other podcasts and the podcast-less episode), none twice.
        var lookupURLs = Array(newest.episodeURLs.prefix(80).compactMap { $0 })
        lookupURLs += [Self.selectedURL(1), Self.duplicateURL, URL(string: "https://example.com/stress/missing.mp3")!]
        if let first = lookupURLs.first { lookupURLs.append(first) }
        let lookupSet = Set(lookupURLs)
        let expectedURLMatches = Set(allEpisodes.compactMap { episode in
            episode.url.map(lookupSet.contains) == true ? episode.persistentModelID : nil
        })
        let urlMatches = try reader.episodes(forURLs: lookupURLs)
        XCTAssertEqual(Set(urlMatches.map(\.persistentModelID)), expectedURLMatches, label)
        XCTAssertEqual(urlMatches.count, expectedURLMatches.count, "\(label): no duplicate models")
        XCTAssertTrue(try reader.episodes(forURLs: []).isEmpty)

        // Transcript scope: only the selected podcast's lines, never the
        // orphan line, the podcast-less episode or the other podcast.
        let query = "needle"
        let expectedLines = allLines
            .filter { line in
                line.episode?.podcast?.persistentModelID == selectedID
                    && (line.text.localizedStandardContains(query)
                        || line.speaker?.localizedStandardContains(query) == true)
            }
            .sorted { $0.startTime < $1.startTime }
        let search = TranscriptSearchActor(modelContainer: container)
        let scope = TranscriptSearchScope.podcast(selected.stablePodcastIdentityKey)
        let hasTranscripts = try await search.hasSearchableTranscripts(in: scope)
        XCTAssertEqual(hasTranscripts, count > 0, label)
        let libraryHasTranscripts = try await search.hasSearchableTranscripts(in: .library)
        XCTAssertTrue(libraryHasTranscripts, label)

        let firstResults = try await search.search(TranscriptSearchQuery(text: query, scope: scope, limit: 80))
        XCTAssertEqual(firstResults.totalMatches, expectedLines.count, label)
        XCTAssertEqual(
            Self.passageIDs(firstResults),
            Set(expectedLines.prefix(80).map(\.id.uuidString)),
            label
        )
        let offsetResults = try await search.search(
            TranscriptSearchQuery(text: query, scope: scope, limit: 3, offset: 1)
        )
        XCTAssertEqual(
            Self.passageIDs(offsetResults),
            Set(expectedLines.dropFirst(1).prefix(3).map(\.id.uuidString)),
            "\(label): offset page"
        )

        if let firstSelected = selectedEpisodes.first(where: { $0.guid == "s-0" }) {
            let episodeScope = TranscriptSearchScope.episode(firstSelected.stableEpisodeIdentity.key)
            let episodeResults = try await search.search(TranscriptSearchQuery(text: query, scope: episodeScope))
            let expectedEpisodeLines = expectedLines.filter {
                $0.episode?.persistentModelID == firstSelected.persistentModelID
            }
            XCTAssertEqual(episodeResults.totalMatches, expectedEpisodeLines.count, label)
            XCTAssertEqual(episodeResults.totalMatches, 2, label)
        }
    }

    private func writeFixture(episodeCount count: Int, storeURL: URL) throws {
        let container = try Self.makeContainer(storeURL: storeURL)
        let writer = ModelContext(container)
        let selected = Podcast(feed: Self.selectedFeed)
        let other = Podcast(feed: Self.otherFeed)
        writer.insert(selected)
        writer.insert(other)

        for index in 0..<count {
            let episode = Episode(
                guid: "s-\(index)",
                title: "Episode \(index)",
                publishDate: index % 5 == 4 ? nil : Date(timeIntervalSince1970: 1_000_000 + Double(index) * 3_600),
                url: index % 7 == 3 ? Self.duplicateURL : Self.selectedURL(index),
                podcast: selected
            )
            if index % 10 == 9 { episode.url = nil }
            writer.insert(episode)
            if index % 25 == 0 {
                let base = Double(index) * 10
                for (text, speaker, offset) in [
                    ("needle \(index)", nil, 1.0),
                    ("plain line", nil, 2.0),
                    ("spoken line", "Needle Host", 3.0),
                ] as [(String, String?, Double)] {
                    let line = TranscriptLineAndTime(speaker: speaker, text: text, startTime: base + offset)
                    line.episode = episode
                    writer.insert(line)
                }
            }
            if index.isMultiple(of: 1_000) { try writer.save() }
        }

        // Other podcast shares some URLs with the selected one.
        for index in 0..<20 {
            let episode = Episode(
                guid: "o-\(index)",
                title: "Other \(index)",
                url: index < 5 ? Self.selectedURL(index) : URL(string: "https://example.com/stress/o/\(index).mp3")!,
                podcast: other
            )
            if index == 5 { episode.url = Self.duplicateURL }
            writer.insert(episode)
            if index == 0 {
                let line = TranscriptLineAndTime(text: "needle elsewhere", startTime: 0.5)
                line.episode = episode
                writer.insert(line)
            }
        }

        // Episode with no podcast, sharing a selected URL, with a transcript.
        let podcastless = Episode(guid: "orphan-episode", title: "No podcast", url: Self.selectedURL(1))
        writer.insert(podcastless)
        let podcastlessLine = TranscriptLineAndTime(text: "needle without podcast", startTime: 0.25)
        podcastlessLine.episode = podcastless
        writer.insert(podcastlessLine)

        // Transcript line with no episode at all.
        writer.insert(TranscriptLineAndTime(text: "needle orphan line", startTime: 0.1))
        try writer.save()
    }

    // MARK: - Overlapping contexts

    /// Deterministically interleaves queue insert/reorder/remove/snapshot on
    /// one context with episode delete/refresh on another, while the filter
    /// and transcript actors and a stale visible page read the same SQLite
    /// file. Each step asserts exact results rather than merely "no crash".
    func testOverlappingQueueAndRefreshContextsStayConsistent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftDataOverlap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Overlap.sqlite")

        let playlistID: UUID
        do {
            let writer = ModelContext(try Self.makeContainer(storeURL: storeURL))
            let podcast = Podcast(feed: Self.selectedFeed)
            writer.insert(podcast)
            var episodes: [Episode] = []
            for index in 0..<30 {
                let episode = Episode(
                    guid: "s-\(index)",
                    title: "Episode \(index)",
                    publishDate: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 3_600),
                    url: Self.selectedURL(index),
                    podcast: podcast
                )
                writer.insert(episode)
                let line = TranscriptLineAndTime(text: "needle \(index)", startTime: Double(index))
                line.episode = episode
                writer.insert(line)
                episodes.append(episode)
            }
            let queue = Playlist()
            queue.title = "Overlap queue"
            writer.insert(queue)
            for (order, episode) in episodes.prefix(10).enumerated() {
                let entry = PlaylistEntry(episode: episode, order: order)
                entry.playlist = queue
                writer.insert(entry)
            }
            try writer.save()
            playlistID = queue.id
        }

        let container = try Self.makeContainer(storeURL: storeURL)
        let queueContext = ModelContext(container)
        let refreshContext = ModelContext(container)
        let filter = PodcastEpisodeFilterActor(modelContainer: container)
        let search = TranscriptSearchActor(modelContainer: container)

        func podcastID(in context: ModelContext) throws -> PersistentIdentifier {
            let feed = Self.selectedFeed
            return try XCTUnwrap(context.fetch(FetchDescriptor<Podcast>(
                predicate: #Predicate { $0.feed == feed }
            )).first).persistentModelID
        }
        func episode(guid: String, in context: ModelContext) throws -> Episode? {
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        }
        let selectedID = try podcastID(in: refreshContext)
        let scope = TranscriptSearchScope.podcast(PodcastFeedIdentity.normalizedFeedURLString(Self.selectedFeed))

        // Load every queue entry once so the queue context holds registered
        // (soon stale) objects, as a long-lived UI context would.
        _ = try queueContext.fetch(FetchDescriptor<PlaylistEntry>())

        for iteration in 0..<40 {
            let label = "iteration=\(iteration)"
            // A visible page computed before the other context's writes.
            let stale = try await filter.episodeIDs(podcastID: selectedID, request: Self.request(.newestFirst))

            // Refresh context: delete one episode, insert a new one with a
            // transcript, rename another.
            var deletedIDs = Set<PersistentIdentifier>()
            if let victim = try episode(guid: "s-\(iteration % 30)", in: refreshContext) {
                deletedIDs.insert(victim.persistentModelID)
                refreshContext.delete(victim)
            }
            let podcast = try XCTUnwrap(refreshContext.fetch(FetchDescriptor<Podcast>(
                predicate: #Predicate { $0.persistentModelID == selectedID }
            )).first)
            let added = Episode(
                guid: "n-\(iteration)",
                title: "New \(iteration)",
                publishDate: Date(timeIntervalSince1970: 2_000_000 + Double(iteration)),
                url: URL(string: "https://example.com/stress/n/\(iteration).mp3")!,
                podcast: podcast
            )
            refreshContext.insert(added)
            let addedLine = TranscriptLineAndTime(text: "needle new \(iteration)", startTime: 100 + Double(iteration))
            addedLine.episode = added
            refreshContext.insert(addedLine)
            try episode(guid: "n-\(max(0, iteration - 1))", in: refreshContext)?.title = "Renamed \(iteration)"
            try refreshContext.save()

            // Queue context: insert, reorder, remove, snapshot.
            let entries = try queueContext.fetch(FetchDescriptor<PlaylistEntry>(
                predicate: #Predicate { $0.playlist?.id == playlistID }
            ))
            let queue = try XCTUnwrap(queueContext.fetch(FetchDescriptor<Playlist>(
                predicate: #Predicate { $0.id == playlistID }
            )).first)
            if let candidate = try episode(guid: "n-\(iteration)", in: queueContext) {
                let entry = PlaylistEntry(episode: candidate, order: entries.count)
                entry.playlist = queue
                queueContext.insert(entry)
            } else {
                XCTFail("\(label): new episode should be visible to the queue context")
            }
            let ordered = entries.sorted { $0.order < $1.order }
            for (index, entry) in ordered.enumerated() {
                entry.order = ordered.count - index
            }
            if iteration.isMultiple(of: 3), let first = ordered.first {
                queueContext.delete(first)
            }
            try queueContext.save()
            let snapshot = try XCTUnwrap(
                StoreSplitPlaylistSnapshotBuilder.build(playlistID: playlistID, in: queueContext),
                label
            )

            // Truth from a fresh context.
            let truthContext = ModelContext(container)
            let liveEpisodes = try truthContext.fetch(FetchDescriptor<Episode>())
            let liveKeys = Set(liveEpisodes.map(\.stableEpisodeIdentity.key))
            let liveEntries = try truthContext.fetch(FetchDescriptor<PlaylistEntry>()).filter {
                $0.playlist?.id == playlistID && $0.episode != nil
            }
            XCTAssertTrue(
                snapshot.entries.allSatisfy { liveKeys.contains($0.identity.key) },
                "\(label): snapshot references a deleted episode"
            )
            XCTAssertEqual(
                Set(snapshot.entries.map(\.identity.key)),
                Set(liveEntries.compactMap { $0.episode?.stableEpisodeIdentity.key }),
                label
            )

            // The stale page skips rows deleted by the other context.
            let range = 0..<min(80, stale.episodeIDs.count)
            let page = try queueContext.episodes(
                forPageIDs: Array(stale.episodeIDs[range]),
                urls: Array(stale.episodeURLs[range])
            )
            XCTAssertEqual(
                page.map(\.persistentModelID),
                stale.episodeIDs[range].filter { deletedIDs.contains($0) == false },
                label
            )

            // Fresh filter and transcript results match the new truth.
            let fresh = try await filter.episodeIDs(podcastID: selectedID, request: Self.request(.newestFirst))
            let expectedIDs = Set(liveEpisodes.compactMap {
                $0.podcast?.persistentModelID == selectedID ? $0.persistentModelID : nil
            })
            XCTAssertEqual(Set(fresh.episodeIDs), expectedIDs, label)
            let expectedLineCount = try truthContext.fetch(FetchDescriptor<TranscriptLineAndTime>()).filter {
                $0.episode?.podcast?.persistentModelID == selectedID
            }.count
            let results = try await search.search(TranscriptSearchQuery(text: "needle", scope: scope))
            XCTAssertEqual(results.totalMatches, expectedLineCount, label)
        }
    }

    // MARK: - Helpers

    private static func makeContainer(storeURL: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Podcast.self, PodcastMetaData.self, Episode.self, EpisodeMetaData.self,
            TranscriptLineAndTime.self, Playlist.self, PlaylistEntry.self,
            configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        )
    }

    private static func request(_ sort: PodcastEpisodeListSort) -> PodcastEpisodeFilterRequest {
        PodcastEpisodeFilterRequest(
            query: "", searchInTitle: true, searchInAuthor: false,
            searchInDescription: false, searchInTranscript: false,
            hidePlayedAndArchived: false, sort: sort
        )
    }

    private static func passageIDs(_ snapshot: TranscriptSearchSnapshot) -> Set<String> {
        Set(snapshot.groups.flatMap { $0.episodes.flatMap { $0.passages.map(\.id) } })
    }
}

#endif
