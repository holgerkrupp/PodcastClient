import Foundation
import XCTest
@testable import UpNext

final class LivePodcastDiscoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testNoLiveItemsProducesNoEntries() {
        let podcast = podcast(title: "Show", subscribed: true)

        XCTAssertTrue(entries(for: [(podcast, [])]).isEmpty)
    }

    func testUpcomingAndEndedItemsAreExcluded() {
        let podcast = podcast(title: "Show", subscribed: true)
        let items = [
            item(id: "upcoming", status: .pending, start: now.addingTimeInterval(60)),
            item(id: "ended", status: .ended, start: now.addingTimeInterval(-120))
        ]

        XCTAssertTrue(entries(for: [(podcast, items)]).isEmpty)
    }

    func testOneLiveItemProducesOneEntry() {
        let podcast = podcast(title: "Show", subscribed: true)

        XCTAssertEqual(
            entries(for: [(podcast, [item(id: "live", status: .live)])]).map(\.item.id),
            ["live"]
        )
    }

    func testMultipleLiveItemsAndMixedStatesOnlyIncludeLiveSubscribedItems() {
        let first = podcast(title: "First", subscribed: true)
        let second = podcast(title: "Second", subscribed: true)
        let unsubscribed = podcast(title: "Unsubscribed", subscribed: false)
        let items = [
            item(id: "first-live", status: .live, start: now.addingTimeInterval(30)),
            item(id: "first-upcoming", status: .pending, start: now.addingTimeInterval(60)),
            item(id: "second-live", status: .live, start: now),
            item(id: "unsubscribed-live", status: .live)
        ]

        let result = entries(for: [
            (first, Array(items[0...1])),
            (second, [items[2]]),
            (unsubscribed, [items[3]])
        ])

        XCTAssertEqual(result.map(\.item.id), ["second-live", "first-live"])
    }

    func testDisabledFeatureProducesNoEntries() {
        let podcast = podcast(title: "Show", subscribed: true)

        XCTAssertTrue(
            LivePodcastDiscovery.entries(
                from: [(podcast: podcast, items: [item(id: "live", status: .live)])],
                isEnabled: false
            ).isEmpty
        )
    }

    func testLiveToEndedTransitionRemovesEntry() {
        let podcast = podcast(title: "Show", subscribed: true)
        let live = item(id: "event", status: .live)

        XCTAssertEqual(entries(for: [(podcast, [live])]).count, 1)
        XCTAssertTrue(entries(for: [(podcast, [item(id: live.id, status: .ended)])]).isEmpty)
    }

    private func entries(
        for candidates: [(Podcast, [PodcastLiveItem])]
    ) -> [LivePodcastEntry] {
        LivePodcastDiscovery.entries(
            from: candidates.map { (podcast: $0.0, items: $0.1) },
            isEnabled: true
        )
    }

    private func podcast(title: String, subscribed: Bool) -> Podcast {
        let podcast = Podcast(feed: URL(string: "https://example.com/\(title).xml")!)
        podcast.title = title
        podcast.metaData?.isSubscribed = subscribed
        return podcast
    }

    private func item(
        id: String,
        status: PodcastLiveItem.Status,
        start: Date? = nil
    ) -> PodcastLiveItem {
        PodcastLiveItem(
            id: id,
            guid: id,
            title: id,
            status: status,
            start: start,
            end: nil,
            summary: nil,
            artworkURL: nil,
            link: nil,
            streamSources: [],
            chat: [],
            contentLinks: []
        )
    }
}
