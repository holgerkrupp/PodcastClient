import Foundation
import XCTest
@testable import UpNext

final class ShownoteLinkHistoryTests: XCTestCase {
    func testHistoryIsOptInByDefault() async throws {
        let (store, _) = try makeStore()
        let source = ShownoteLinkHistorySource(
            episodeURL: URL(string: "https://pod.example/episode")!,
            episodeTitle: "Fixture episode"
        )

        await store.record(
            destination: URL(string: "https://example.com/article")!,
            title: "Article",
            source: source
        )

        let configuration = await store.configuration()
        let entries = await store.entries()
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertTrue(entries.isEmpty)
    }

    func testSanitizesTrackingAndRejectsSensitiveOrNonHTTPURLs() {
        let safe = ShownoteLinkHistoryURLPolicy.sanitize(
            URL(string: "https://example.com/article?utm_source=notes&id=42")!
        )
        XCTAssertEqual(safe?.absoluteString, "https://example.com/article?id=42")

        XCTAssertNil(ShownoteLinkHistoryURLPolicy.sanitize(
            URL(string: "https://example.com/article?X-Amz-Signature=secret")!
        ))
        XCTAssertNil(ShownoteLinkHistoryURLPolicy.sanitize(
            URL(string: "https://example.com/article#private-fragment")!
        ))
        XCTAssertNil(ShownoteLinkHistoryURLPolicy.sanitize(
            URL(string: "mailto:person@example.com")!
        ))
    }

    func testRepeatedSafeOpenDeduplicatesAndUpdatesSnapshot() async throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_000))
        let (store, _) = try makeStore(clock: clock)
        await store.setRetention(.ninetyDays)
        let source = ShownoteLinkHistorySource(
            episodeURL: URL(string: "https://pod.example/episode")!,
            episodeTitle: "Fixture episode"
        )
        let destination = URL(string: "https://example.com/article?utm_campaign=fixture")!

        await store.record(destination: destination, title: "First title", source: source)
        clock.date.addTimeInterval(60)
        await store.record(destination: destination, title: "Updated title", source: source)

        let entries = await store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "Updated title")
        XCTAssertEqual(entries.first?.destination.absoluteString, "https://example.com/article")
        XCTAssertEqual(entries.first?.openedAt, clock.date)
    }

    func testExpiredEntriesArePrunedOnRead() async throws {
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_000))
        let (store, _) = try makeStore(clock: clock)
        await store.setRetention(.sevenDays)
        let source = ShownoteLinkHistorySource(
            episodeURL: URL(string: "https://pod.example/episode")!,
            episodeTitle: "Fixture episode"
        )

        await store.record(
            destination: URL(string: "https://example.com/article")!,
            title: "Article",
            source: source
        )
        clock.date.addTimeInterval(8 * 24 * 60 * 60)

        let entries = await store.entries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testDisableAndClearRemoveQueuedHistory() async throws {
        let (store, _) = try makeStore()
        await store.setRetention(.thirtyDays)
        let source = ShownoteLinkHistorySource(
            episodeURL: URL(string: "https://pod.example/episode")!,
            episodeTitle: "Fixture episode"
        )

        await store.record(
            destination: URL(string: "https://example.com/article")!,
            title: "Article",
            source: source
        )
        await store.setEnabled(false)
        await store.record(
            destination: URL(string: "https://example.com/second")!,
            title: "Second article",
            source: source
        )

        let entries = await store.entries()
        let configuration = await store.configuration()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertFalse(ShownoteLinkHistoryOpenPolicy.shouldRecord(successfullyOpened: false))
        XCTAssertTrue(ShownoteLinkHistoryOpenPolicy.shouldRecord(successfullyOpened: true))
    }

    private func makeStore(
        clock: TestClock = TestClock(date: Date(timeIntervalSince1970: 1_000))
    ) throws -> (ShownoteLinkHistoryStore, UserDefaults) {
        let suite = "ShownoteLinkHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // The store gets its own instance of the same suite so the returned
        // defaults are not sent into the actor's isolation region.
        let storeDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (ShownoteLinkHistoryStore(defaults: storeDefaults, now: { clock.date }), defaults)
    }
}

private final class TestClock: @unchecked Sendable {
    var date: Date

    init(date: Date) {
        self.date = date
    }
}
