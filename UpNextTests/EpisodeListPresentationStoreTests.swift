import XCTest
import SwiftData
@testable import UpNext

/// #498: list rows read keyed, shared presentation state instead of doing
/// per-row actor lookups or relationship reads.
@MainActor
final class EpisodeDownloadPresentationStoreTests: XCTestCase {
    private let firstURL = URL(string: "https://example.com/one.mp3")!
    private let secondURL = URL(string: "https://example.com/two.mp3")!

    private final class LookupCounter: @unchecked Sendable {
        var count = 0
        var items: [URL: DownloadItem] = [:]
    }

    func testReadingEntriesNeverStartsALookup() async {
        let counter = LookupCounter()
        let store = EpisodeDownloadPresentationStore(
            notificationCenter: NotificationCenter(),
            itemLookup: { url in
                counter.count += 1
                return await MainActor.run { counter.items[url] }
            },
            snapshotLookup: { [] }
        )

        for _ in 0..<50 {
            _ = store.entry(for: firstURL)
            _ = store.entry(for: secondURL)
        }
        await settle()

        XCTAssertEqual(counter.count, 0)
        XCTAssertNil(store.entry(for: firstURL).item)
    }

    func testStartNotificationUpdatesOnlyTheAffectedKey() async {
        let center = NotificationCenter()
        let counter = LookupCounter()
        let item = DownloadItem(url: firstURL)
        item.isDownloading = true
        counter.items[firstURL] = item
        let store = EpisodeDownloadPresentationStore(
            notificationCenter: center,
            itemLookup: { url in
                counter.count += 1
                return await MainActor.run { counter.items[url] }
            },
            snapshotLookup: { [] }
        )
        let first = store.entry(for: firstURL)
        let second = store.entry(for: secondURL)

        center.post(
            name: .episodeDownloadStarted,
            object: nil,
            userInfo: [EpisodeDownloadNotificationKey.episodeURL: firstURL]
        )
        await settle()

        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(first.item === item)
        XCTAssertNil(second.item)
    }

    func testFinishClearsStaleProgress() async {
        let center = NotificationCenter()
        let item = DownloadItem(url: firstURL)
        item.isDownloading = true
        let store = EpisodeDownloadPresentationStore(
            notificationCenter: center,
            itemLookup: { _ in nil },
            snapshotLookup: { [] }
        )
        store.apply(item, for: firstURL)
        let entry = store.entry(for: firstURL)
        XCTAssertTrue(entry.item === item)

        center.post(
            name: .episodeDownloadFinished,
            object: nil,
            userInfo: [EpisodeDownloadNotificationKey.episodeURL: firstURL]
        )
        await settle()
        XCTAssertNil(entry.item)

        // An item that finishes on its own also disappears.
        let retry = DownloadItem(url: firstURL)
        retry.isDownloading = true
        store.apply(retry, for: firstURL)
        XCTAssertTrue(entry.item === retry)
        retry.isFinished = true
        await settle()
        XCTAssertNil(entry.item)
    }

    func testLaunchSnapshotSeedsActiveTransfersOnce() async {
        let item = DownloadItem(url: secondURL)
        item.isPaused = true
        let store = EpisodeDownloadPresentationStore(
            notificationCenter: NotificationCenter(),
            itemLookup: { _ in nil },
            snapshotLookup: { [item] }
        )
        await settle()

        XCTAssertTrue(store.entry(for: secondURL).item === item)
        XCTAssertNil(store.entry(for: firstURL).item)
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        for _ in 0..<10 { await Task.yield() }
    }
}

@MainActor
final class EpisodeReferenceAvailabilityStoreTests: XCTestCase {
    private final class LoaderLog: @unchecked Sendable {
        var batches: [Set<URL>] = []
        var result = EpisodeReferenceAvailability(hasChapters: true, hasTranscript: false, hasBookmarks: true)
    }

    func testMissingEntriesLoadInOneBatchAndCachedEntriesDoNotReload() async throws {
        let container = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let (firstURL, firstID) = try insertEpisode("one", in: container)
        let (secondURL, secondID) = try insertEpisode("two", in: container)
        let log = LoaderLog()
        let store = makeStore(log: log)

        let first = store.entry(for: firstURL)
        let second = store.entry(for: secondURL)
        store.loadIfNeeded(first, episodeID: firstID, container: container)
        store.loadIfNeeded(second, episodeID: secondID, container: container)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(log.batches, [[firstURL, secondURL]])
        XCTAssertEqual(first.availability, log.result)
        XCTAssertEqual(second.availability, log.result)

        // A recycled row with a cached value does not trigger work.
        store.loadIfNeeded(store.entry(for: firstURL), episodeID: firstID, container: container)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(log.batches.count, 1)

        // A change reloads only that episode and keeps the old value visible
        // until the new one arrives.
        log.result = EpisodeReferenceAvailability(hasChapters: false, hasTranscript: true, hasBookmarks: false)
        store.referencesDidChange(for: secondURL)
        XCTAssertNotNil(second.availability)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(log.batches.last, [secondURL])
        XCTAssertEqual(second.availability, log.result)
        XCTAssertEqual(first.availability?.hasChapters, true)
    }

    func testBackgroundLoaderReadsAnEpisodeWithoutReferences() async throws {
        let container = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let (url, id) = try insertEpisode("plain", in: container)

        let result = await EpisodeReferenceAvailabilityLoader(modelContainer: container)
            .availability(for: [url: id])

        XCTAssertEqual(result[url], EpisodeReferenceAvailability())
    }

    private func makeStore(log: LoaderLog) -> EpisodeReferenceAvailabilityStore {
        EpisodeReferenceAvailabilityStore(
            notificationCenter: NotificationCenter(),
            batchDelay: .milliseconds(20),
            loader: { _, requests in
                await MainActor.run {
                    log.batches.append(Set(requests.keys))
                    return requests.mapValues { _ in log.result }
                }
            },
            onReferencesChanged: {}
        )
    }

    private func insertEpisode(_ name: String, in container: ModelContainer) throws -> (URL, PersistentIdentifier) {
        let url = URL(string: "https://example.com/\(name)-\(UUID().uuidString).mp3")!
        let episode = Episode(title: name, publishDate: .now, url: url, duration: 60, author: "Author")
        container.mainContext.insert(episode)
        try container.mainContext.save()
        return (url, episode.persistentModelID)
    }
}

final class QueueProjectionInventoryTests: XCTestCase {
    @MainActor
    func testProjectionUsesTheSuppliedFileInventory() throws {
        let downloadedURL = URL(string: "https://example.com/inventory-downloaded.mp3")!
        let remoteURL = URL(string: "https://example.com/inventory-remote.mp3")!
        let downloaded = Episode(title: "Downloaded", publishDate: .now, url: downloadedURL, duration: 60, author: "Author")
        let remote = Episode(title: "Remote", publishDate: .now, url: remoteURL, duration: 60, author: "Author")
        let localFile = try XCTUnwrap(downloaded.localFile?.standardizedFileURL)

        let projection = QueueProjection(
            episodes: [downloaded, remote],
            downloadedFiles: [localFile]
        )

        XCTAssertEqual(projection.entries.map(\.isDownloaded), [true, false])
        XCTAssertEqual(projection.entries.map(\.orderIndex), [0, 1])
    }
}
