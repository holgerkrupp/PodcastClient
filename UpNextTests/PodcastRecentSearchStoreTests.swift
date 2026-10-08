import Foundation
import XCTest
@testable import UpNext

@MainActor
final class PodcastRecentSearchStoreTests: XCTestCase {
    private func makeStore() -> (PodcastRecentSearchStore, UserDefaults, String) {
        let suiteName = "PodcastRecentSearchStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let key = "searches"
        return (PodcastRecentSearchStore(defaults: defaults, storageKey: key), defaults, key)
    }

    func testRecordTrimsAndPersistsTextSearches() {
        let (store, defaults, key) = makeStore()

        store.record("  Accidental Tech Podcast  ")

        XCTAssertEqual(store.searches, ["Accidental Tech Podcast"])
        XCTAssertEqual(defaults.stringArray(forKey: key), ["Accidental Tech Podcast"])
    }

    func testRecordDeduplicatesCaseAndDiacriticInsensitivelyAndMovesQueryToTop() {
        let (store, _, _) = makeStore()
        store.record("Cafe Podcast")
        store.record("Swift News")
        store.record("  café podcast ")

        XCTAssertEqual(store.searches, ["café podcast", "Swift News"])
    }

    func testRecordIgnoresPublicAndPrivateFeedURLs() {
        let (store, _, _) = makeStore()

        store.record("https://example.com/feed.xml")
        store.record("https://example.com/feed.xml?token=private-secret")
        store.record("https://user:password@example.com/private.rss")

        XCTAssertTrue(store.searches.isEmpty)
    }

    func testHistoryIsBoundedToTenSearches() {
        let (store, _, _) = makeStore()

        for index in 1...12 {
            store.record("Podcast \(index)")
        }

        XCTAssertEqual(store.searches.count, 10)
        XCTAssertEqual(store.searches.first, "Podcast 12")
        XCTAssertEqual(store.searches.last, "Podcast 3")
    }

    func testRemoveAndClearUpdatePersistence() {
        let (store, defaults, key) = makeStore()
        store.record("First")
        store.record("Second")

        store.remove(" first ")
        XCTAssertEqual(store.searches, ["Second"])

        store.clear()
        XCTAssertTrue(store.searches.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: key), [])
    }

    func testStoreRestoresHistoryFromLocalPreferences() {
        let (store, defaults, key) = makeStore()
        store.record("German history podcasts")

        let restoredStore = PodcastRecentSearchStore(defaults: defaults, storageKey: key)

        XCTAssertEqual(restoredStore.searches, ["German history podcasts"])
    }
}
