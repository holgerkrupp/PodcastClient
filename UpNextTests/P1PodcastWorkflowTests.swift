import XCTest
@testable import UpNext

final class P1PodcastWorkflowTests: XCTestCase {
    func testSmartShuffleBalancesUnequalPodcastGroupsAndPreservesRelativeOrder() {
        let result = SmartShuffleOrdering.interleavedIndices(
            groupKeys: ["a", "a", "a", "a", "b", "b", "c"]
        )

        XCTAssertEqual(result, [0, 4, 6, 1, 5, 2, 3])
    }

    func testSmartShufflePinsNowPlayingWithoutDroppingEntries() {
        let result = SmartShuffleOrdering.interleavedIndices(
            groupKeys: ["a", "a", "a", "b", "b"],
            pinnedIndex: 0
        )

        XCTAssertEqual(result, [0, 1, 3, 2, 4])
        XCTAssertEqual(Set(result), Set([0, 1, 2, 3, 4]))
    }

    func testSmartPlaylistSupportsEveryStringComparatorAndMatchMode() {
        let episode = Episode(
            title: "Café at Dawn",
            url: URL(string: "https://example.com/episode.mp3")!
        )
        let comparators: [(SmartPlaylistComparator, String)] = [
            (.contains, "afe"),
            (.equals, "cafe at dawn"),
            (.startsWith, "cafe"),
            (.endsWith, "dawn")
        ]

        for (comparator, query) in comparators {
            let rule = SmartPlaylistRule(field: .episodeTitle, comparator: comparator, query: query)
            XCTAssertTrue(SmartPlaylistEngine.matches(episode, filter: SmartPlaylistFilter(rules: [rule])))
        }

        let matching = SmartPlaylistRule(field: .episodeTitle, query: "cafe")
        let notMatching = SmartPlaylistRule(field: .episodeTitle, query: "other")
        XCTAssertFalse(SmartPlaylistEngine.matches(
            episode,
            filter: SmartPlaylistFilter(matchMode: .all, rules: [matching, notMatching])
        ))
        XCTAssertTrue(SmartPlaylistEngine.matches(
            episode,
            filter: SmartPlaylistFilter(matchMode: .any, rules: [matching, notMatching])
        ))
    }

    func testSmartPlaylistTypedDurationLanguageAndStatusRules() throws {
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        podcast.language = "de-DE"
        let episode = Episode(title: "Walk", publishDate: .now, url: URL(string: "https://example.com/walk.mp3")!, podcast: podcast, duration: 25 * 60)
        let filters = [
            SmartPlaylistFilter(rules: [SmartPlaylistRule(field: .language, query: "de")]),
            SmartPlaylistFilter(rules: [SmartPlaylistRule(field: .duration, comparator: .lessThan, query: "30")]),
            SmartPlaylistFilter(rules: [SmartPlaylistRule(field: .status, query: "Unplayed")])
        ]
        XCTAssertTrue(filters.allSatisfy { SmartPlaylistEngine.matches(episode, filter: $0) })
        XCTAssertFalse(SmartPlaylistEngine.matches(episode, filter: SmartPlaylistFilter(rules: [SmartPlaylistRule(field: .duration, comparator: .lessThan, query: "20")])))

        let legacy = Data(#"{"matchMode":"all","requireDownloaded":false,"includeArchived":false,"rules":[{"id":"00000000-0000-0000-0000-000000000001","field":"episodeTitle","comparator":"contains","query":"walk"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(SmartPlaylistFilter.self, from: legacy)
        XCTAssertTrue(SmartPlaylistEngine.matches(episode, filter: decoded))
    }

    func testSmartPlaylistCategoryRulesSupportNestedRSSCategories() {
        var tags = PodcastNamespaceOptionalTags()
        tags.append(NamespaceNode(name: "itunes:category", attributes: ["text": "Technology"], children: [
            NamespaceNode(name: "itunes:category", attributes: ["text": "Tech News"])
        ]))
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        podcast.optionalTags = tags
        let episode = Episode(title: "Update", url: URL(string: "https://example.com/update.mp3")!, podcast: podcast)
        XCTAssertTrue(SmartPlaylistEngine.matches(episode, filter: SmartPlaylistFilter(rules: [SmartPlaylistRule(field: .category, query: "Tech News")])))
        XCTAssertFalse(SmartPlaylistEngine.matches(episode, filter: SmartPlaylistFilter(rules: [SmartPlaylistRule(field: .category, query: "Tech")])))
    }

    func testSmartShuffleHandlesEmptySinglePodcastAndLargeLists() {
        XCTAssertEqual(SmartShuffleOrdering.interleavedIndices(groupKeys: []), [])
        XCTAssertEqual(SmartShuffleOrdering.interleavedIndices(groupKeys: ["a", "a"]), [0, 1])

        let keys = (0..<1_200).map { "podcast-\($0 % 17)" }
        let order = SmartShuffleOrdering.interleavedIndices(groupKeys: keys)
        XCTAssertEqual(order.count, keys.count)
        XCTAssertEqual(Set(order), Set(keys.indices))
    }

    func testAutomaticDownloadFilterUsesCaseAndDiacriticInsensitiveKeywords() {
        let filter = AutoDownloadEpisodeFilter(includedKeywords: ["cafe"], excludedKeywords: ["spoiler"])

        XCTAssertTrue(filter.allows(title: "CAFÉ chat", duration: nil, publishDate: nil, type: nil))
        XCTAssertFalse(filter.allows(title: "Café spoiler", duration: nil, publishDate: nil, type: nil))
        XCTAssertFalse(filter.allows(title: "A different show", duration: nil, publishDate: nil, type: nil))
    }

    func testAutomaticDownloadFilterPassesMissingMetadataAndChecksKnownValues() {
        let filter = AutoDownloadEpisodeFilter(
            minimumDurationSeconds: 600,
            maximumDurationSeconds: 3_600,
            maximumPublicationAgeDays: 30,
            episodeTypes: ["full"]
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        XCTAssertTrue(filter.allows(title: "Episode", duration: nil, publishDate: nil, type: nil, now: now))
        XCTAssertFalse(filter.allows(title: "Episode", duration: 300, publishDate: nil, type: .full, now: now))
        XCTAssertFalse(filter.allows(title: "Episode", duration: 900, publishDate: now.addingTimeInterval(-40 * 86_400), type: .full, now: now))
        XCTAssertFalse(filter.allows(title: "Episode", duration: 900, publishDate: now, type: .bonus, now: now))
    }

    func testPortableSettingsSnapshotIncludesAutomaticDownloadRules() {
        let settings = PodcastSettings(defaultSettings: true)
        settings.autoDownloadFilter = AutoDownloadEpisodeFilter(excludedKeywords: ["spoiler"])

        let snapshot = PortablePodcastPreferenceSnapshot.make(settings: settings, feedURL: nil)

        XCTAssertEqual(
            snapshot.autoDownloadFilterJSON.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(AutoDownloadEpisodeFilter.self, from: $0) },
            AutoDownloadEpisodeFilter(excludedKeywords: ["spoiler"])
        )
    }
}
