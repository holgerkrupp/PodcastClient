import SwiftData
import XCTest
@testable import UpNext

/// The retired entity, redeclared here so the upgrade can still be exercised.
///
/// SwiftData names the Core Data entity after the type, so a store written with
/// this class is byte-for-byte the store an older build wrote. Keeping the
/// declaration in the test target rather than the app is what lets the app ship
/// without the model while the upgrade path stays under test.
@Model
final class ListeningSummarySync {
    var id: String = ""
    var feedURL: String = ""
    var periodKind: String = ""
    var periodStart: Date = Date.distantPast
    var sourceDeviceID: String?
    var sourceDeviceName: String?
    var sourceDeviceModel: String?
    var podcastName: String?
    var totalSeconds: Double = 0
    var silenceGapTimeSavedSeconds: Double = 0
    var playbackRateTimeSavedSeconds: Double = 0
    var activeHourCount: Int = 0
    var updatedAt: Date = Date.distantPast

    init(
        id: String,
        feedURL: String,
        periodKind: String,
        periodStart: Date,
        sourceDeviceID: String?,
        totalSeconds: Double
    ) {
        self.id = id
        self.feedURL = feedURL
        self.periodKind = periodKind
        self.periodStart = periodStart
        self.sourceDeviceID = sourceDeviceID
        self.totalSeconds = totalSeconds
        self.updatedAt = .now
    }
}

/// Upgrading an existing install across the removal of `ListeningSummarySync`.
///
/// Removing an entity from a store that already has it is a schema change, and
/// the failure mode is not a wrong number — it is `ModelContainer.init` throwing
/// at launch, which leaves the app with no UserState store at all. These tests
/// run against a real on-disk store in a temporary directory, never a user's.
final class StoreSplitUserStateSchemaUpgradeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    /// The store opens, and everything that is not the retired entity survives.
    func testUpgradingAcrossTheRemovalKeepsEveryOtherRecord() throws {
        let url = directory.appendingPathComponent("UserState.sqlite")
        try writeStoreWithRetiredEntity(at: url)

        let upgraded = try openWithShippingSchema(at: url)
        let context = ModelContext(upgraded)

        XCTAssertEqual(try context.fetch(FetchDescriptor<SubscriptionSync>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<EpisodeStateSync>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PlaylistSync>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PlaylistEntrySync>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<QueueEntrySync>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BookmarkSync>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<PodcastPreferenceSync>()).count, 1)

        let history = try context.fetch(FetchDescriptor<ListeningHistorySync>())
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(
            history.first?.listenedSeconds, 600,
            "session rows are the only listening data that survives the removal, so they must survive it intact"
        )
    }

    /// The upgraded store still works: it accepts the new entity and writes.
    func testUpgradedStoreAcceptsTheBaselineEntity() throws {
        let url = directory.appendingPathComponent("UserState.sqlite")
        try writeStoreWithRetiredEntity(at: url)

        let upgraded = try openWithShippingSchema(at: url)
        let context = ModelContext(upgraded)
        context.insert(ListeningBaselineSync(
            feedURL: "https://example.com/feed.xml",
            totalSeconds: 1_200
        ))
        try context.save()

        let reopened = ModelContext(try openWithShippingSchema(at: url))
        XCTAssertEqual(
            try reopened.fetch(FetchDescriptor<ListeningBaselineSync>()).first?.totalSeconds,
            1_200
        )
    }

    /// Reopening is not a one-shot migration that only works once.
    func testUpgradeIsRepeatable() throws {
        let url = directory.appendingPathComponent("UserState.sqlite")
        try writeStoreWithRetiredEntity(at: url)

        for _ in 0..<3 {
            let context = ModelContext(try openWithShippingSchema(at: url))
            XCTAssertEqual(try context.fetch(FetchDescriptor<SubscriptionSync>()).count, 1)
        }
    }

    // MARK: - Helpers

    private func writeStoreWithRetiredEntity(at url: URL) throws {
        let schema = Schema([
            SubscriptionSync.self,
            EpisodeStateSync.self,
            QueueEntrySync.self,
            PlaylistSync.self,
            PlaylistEntrySync.self,
            BookmarkSync.self,
            PodcastPreferenceSync.self,
            ListeningSummarySync.self,
            ListeningHistorySync.self
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                "UserState",
                schema: schema,
                url: url,
                cloudKitDatabase: .none
            )
        )
        let context = ModelContext(container)
        let feed = "https://example.com/feed.xml"
        context.insert(SubscriptionSync(feedURL: feed))
        context.insert(EpisodeStateSync(feedURL: feed, episodeID: "episode-1"))
        context.insert(PlaylistSync(
            id: "playlist-1",
            title: "Up Next",
            symbolName: "list.bullet",
            sortIndex: 0,
            kindRawValue: "manual"
        ))
        context.insert(PlaylistEntrySync(
            playlistID: "playlist-1",
            feedURL: feed,
            episodeID: "episode-1",
            sortIndex: 0
        ))
        context.insert(QueueEntrySync(feedURL: feed, episodeID: "episode-1", sortIndex: 0))
        context.insert(BookmarkSync(feedURL: feed, episodeID: "episode-1", time: 12))
        context.insert(PodcastPreferenceSync(feedURL: feed))
        context.insert(ListeningHistorySync(
            id: "session-1",
            feedURL: feed,
            episodeID: "episode-1",
            sourceDeviceID: "device-a",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_600),
            listenedSeconds: 600
        ))
        // Several of these, because the removal has to cope with a populated
        // table rather than an empty one.
        for year in 2020...2024 {
            context.insert(ListeningSummarySync(
                id: "summary-\(year)",
                feedURL: feed,
                periodKind: PlaySessionSummaryPeriod.year.rawValue,
                periodStart: Date(timeIntervalSince1970: TimeInterval(year) * 31_536_000),
                sourceDeviceID: "device-a",
                totalSeconds: 3_600
            ))
        }
        try context.save()
    }

    /// The schema the app ships, declared the way `makeUserStateContainer` does.
    private func openWithShippingSchema(at url: URL) throws -> ModelContainer {
        let schema = Schema([
            SubscriptionSync.self,
            EpisodeStateSync.self,
            QueueEntrySync.self,
            PlaylistSync.self,
            PlaylistEntrySync.self,
            BookmarkSync.self,
            PodcastPreferenceSync.self,
            ListeningBaselineSync.self,
            ListeningHistorySync.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                "UserState",
                schema: schema,
                url: url,
                cloudKitDatabase: .none
            )
        )
    }
}
