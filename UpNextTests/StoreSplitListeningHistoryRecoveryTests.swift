import SwiftData
import XCTest
@testable import UpNext

/// The one-off recovery of listening history that exists only in the split
/// stores. It writes into the same store the Statistics screen reads, so the
/// property that matters is that it cannot inflate the numbers.
@MainActor
final class StoreSplitListeningHistoryRecoveryTests: XCTestCase {
    private let feed = URL(string: "https://example.com/history.xml")!

    func testRecoveryRestoresSessionsThatOnlyExistInUserState() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let episode = try seedLibrary(in: legacy)
        seedHistory(in: userState, for: episode, sessions: 3)

        let result = await StoreSplitUserStateImporter.applyListeningHistoryOnly(
            legacyContainer: legacy,
            userStateContainer: userState
        )
        XCTAssertEqual(result.failed, 0)

        let context = ModelContext(legacy)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlaySession>()), 3)
    }

    func testRunningRecoveryTwiceDoesNotInflateStatistics() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let episode = try seedLibrary(in: legacy)
        seedHistory(in: userState, for: episode, sessions: 3)

        _ = await StoreSplitUserStateImporter.applyListeningHistoryOnly(
            legacyContainer: legacy,
            userStateContainer: userState
        )
        let afterFirst = try totalListenedSeconds(in: legacy)

        _ = await StoreSplitUserStateImporter.applyListeningHistoryOnly(
            legacyContainer: legacy,
            userStateContainer: userState
        )
        let afterSecond = try totalListenedSeconds(in: legacy)

        let context = ModelContext(legacy)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PlaySession>()), 3)
        XCTAssertEqual(afterFirst, afterSecond, accuracy: 0.001)
    }

    /// The common case on a real device: the session was recorded live into the
    /// library store *and* published to UserState. Recovery must recognise the
    /// local row rather than adding a second copy of the same listening.
    func testRecoveryDoesNotDuplicateSessionsAlreadyInTheLibraryStore() async throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let userState = try ModelContainerManager.makeUserStateContainer(isStoredInMemoryOnly: true)
        let episode = try seedLibrary(in: legacy)

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = startedAt.addingTimeInterval(600)
        let liveSession = PlaySession(
            id: UUID(),
            episode: episode,
            sourceDeviceID: "phone",
            sourceDeviceName: "iPhone",
            appVersion: "1.0",
            startTime: startedAt,
            endTime: endedAt,
            startPosition: 0,
            endPosition: 600
        )
        legacy.mainContext.insert(liveSession)
        try legacy.mainContext.save()

        let identity = episode.stableEpisodeIdentity
        userState.mainContext.insert(ListeningHistorySync(
            id: ListeningHistoryIdentity.make(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                startedAt: startedAt,
                endedAt: endedAt,
                startPosition: 0,
                endPosition: 600
            ),
            feedURL: identity.feedURL,
            episodeID: identity.episodeID,
            sourceDeviceID: "phone",
            startedAt: startedAt,
            endedAt: endedAt,
            startPosition: 0,
            endPosition: 600,
            listenedSeconds: 600
        ))
        try userState.mainContext.save()

        _ = await StoreSplitUserStateImporter.applyListeningHistoryOnly(
            legacyContainer: legacy,
            userStateContainer: userState
        )

        let context = ModelContext(legacy)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<PlaySession>()),
            1,
            "the live session and its published copy are the same listening"
        )
        XCTAssertEqual(try totalListenedSeconds(in: legacy), 600, accuracy: 0.001)
    }

    // MARK: - Helpers

    private func seedLibrary(in container: ModelContainer) throws -> Episode {
        let podcast = Podcast(feed: feed)
        podcast.title = "History Podcast"
        let episode = Episode(
            guid: "history-1",
            title: "Episode",
            url: URL(string: "https://example.com/history-1.mp3")!,
            podcast: podcast
        )
        podcast.episodes = [episode]
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        return episode
    }

    private func seedHistory(
        in container: ModelContainer,
        for episode: Episode,
        sessions: Int
    ) {
        let identity = episode.stableEpisodeIdentity
        for index in 0..<sessions {
            let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
                .addingTimeInterval(Double(index) * 7_200)
            let endedAt = startedAt.addingTimeInterval(900)
            container.mainContext.insert(ListeningHistorySync(
                id: ListeningHistoryIdentity.make(
                    feedURL: identity.feedURL,
                    episodeID: identity.episodeID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    startPosition: 0,
                    endPosition: 900
                ),
                feedURL: identity.feedURL,
                episodeID: identity.episodeID,
                sourceDeviceID: "in-memory-era-device",
                startedAt: startedAt,
                endedAt: endedAt,
                startPosition: 0,
                endPosition: 900,
                listenedSeconds: 900
            ))
        }
        try? container.mainContext.save()
    }

    private func totalListenedSeconds(in container: ModelContainer) throws -> Double {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<PlaySession>()).reduce(0) { total, session in
            guard let start = session.startTime, let end = session.endTime else {
                return total
            }
            return total + end.timeIntervalSince(start)
        }
    }
}
