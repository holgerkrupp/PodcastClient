import Foundation
import XCTest
@testable import UpNext

private actor CatalogLoadCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

final class PodcastDiscoveryCatalogCacheTests: XCTestCase {
    func testConcurrentRequestsShareOnePublicCatalogLoad() async {
        let key = "test:\(UUID().uuidString)"
        let counter = CatalogLoadCounter()
        let feed = PodcastFeed(url: URL(string: "https://public.example/feed.xml")!, title: "Public")

        async let first = PodcastDiscoveryCatalogCache.shared.feeds(for: key, ttl: 60) {
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(40))
            return [feed]
        }
        async let second = PodcastDiscoveryCatalogCache.shared.feeds(for: key, ttl: 60) {
            await counter.increment()
            return [feed]
        }

        let results = await (first, second)
        let loadCount = await counter.count
        XCTAssertEqual(results.0.map(\.url), [feed.url])
        XCTAssertEqual(results.1.map(\.url), [feed.url])
        XCTAssertEqual(loadCount, 1)
    }

    func testExpiredAndEmptyResponsesAreLoadedAgain() async {
        let key = "test:\(UUID().uuidString)"
        let counter = CatalogLoadCounter()
        let feed = PodcastFeed(url: URL(string: "https://public.example/feed.xml")!, title: "Public")

        _ = await PodcastDiscoveryCatalogCache.shared.feeds(for: key, ttl: 0.01) {
            await counter.increment()
            return [feed]
        }
        try? await Task.sleep(for: .milliseconds(30))
        _ = await PodcastDiscoveryCatalogCache.shared.feeds(for: key, ttl: 60) {
            await counter.increment()
            return []
        }
        _ = await PodcastDiscoveryCatalogCache.shared.feeds(for: key, ttl: 60) {
            await counter.increment()
            return [feed]
        }

        let loadCount = await counter.count
        XCTAssertEqual(loadCount, 3)
    }
}
