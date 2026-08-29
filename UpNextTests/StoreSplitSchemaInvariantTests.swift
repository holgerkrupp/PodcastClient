import SwiftData
import XCTest
@testable import UpNext

/// Schema-level invariants the store split depends on.
///
/// These assert SwiftData's *observed* behaviour rather than the model
/// declarations, because the declarations are what made the behaviour doubtful:
/// `Playlist.items`/`PlaylistEntry.playlist` and `Podcast.episodes`/
/// `Episode.podcast` are pairs whose inverse is inferred, never written down. The
/// inference is unambiguous only while each relationship has exactly one
/// candidate on the far side, so a later model edit can silently withdraw it.
/// These tests are the alarm for that edit.
final class StoreSplitSchemaInvariantTests: XCTestCase {
    @MainActor
    func testEntrySideWriteIsVisibleFromThePlaylistAndTheEpisode() throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let context = legacy.mainContext
        let (_, episode) = try seedEpisode(in: context)
        let playlist = Playlist()
        context.insert(playlist)
        let entry = PlaylistEntry(episode: episode, order: 0)
        context.insert(entry)
        entry.playlist = playlist
        try context.save()

        XCTAssertEqual(
            playlist.items?.count, 1,
            "writers set entry.playlist; readers use playlist.items — the inferred inverse is what keeps them agreeing"
        )
        XCTAssertEqual(episode.playlist?.count, 1)
    }

    @MainActor
    func testPlaylistSideWriteIsVisibleFromTheEntry() throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let context = legacy.mainContext
        let (_, episode) = try seedEpisode(in: context)
        let playlist = Playlist()
        playlist.title = "Custom"
        context.insert(playlist)
        let entry = PlaylistEntry(episode: episode, order: 0)
        context.insert(entry)
        playlist.items = [entry]
        try context.save()

        XCTAssertEqual(
            entry.playlist?.id, playlist.id,
            "PlaylistModelActor.fetchOrderedEntries queries the entry side; a playlist-side-only write would be invisible to it"
        )
    }

    /// Re-pointing an episode moves it out of the previous owner's array, so
    /// deleting that owner does not cascade into the episode. The cascade rule on
    /// `Podcast.episodes` is only dangerous if the two halves can disagree.
    @MainActor
    func testRepointingAnEpisodeRemovesItFromTheFormerPodcast() throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let context = legacy.mainContext
        let first = Podcast(feed: URL(string: "https://example.com/a")!)
        let second = Podcast(feed: URL(string: "https://example.com/b")!)
        context.insert(first)
        context.insert(second)
        let episode = Episode(
            guid: "cascade-1",
            title: "Cascade",
            url: URL(string: "https://example.com/cascade.mp3")!,
            podcast: first
        )
        context.insert(episode)
        first.episodes = [episode]
        try context.save()

        episode.podcast = second
        second.episodes = [episode]
        try context.save()
        XCTAssertEqual(first.episodes?.count, 0)

        context.delete(first)
        try context.save()

        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Episode>()).count, 1,
            "deleting the former owner must not cascade into an episode that now belongs to another podcast"
        )
    }

    /// Deleting a playlist nullifies its entries instead of removing them, and a
    /// nullified entry is reachable from neither `playlist.items` nor the
    /// `entry.playlist == id` fetch every reader uses. Nothing in the app deletes
    /// such a row afterwards, which is why `LibraryDeduplicationService` reports
    /// orphans rather than silently dropping them. Any deletion site therefore has
    /// to remove the entries itself.
    @MainActor
    func testDeletingAPlaylistStrandsItsEntriesUnlessTheyAreDeletedFirst() throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let context = legacy.mainContext
        let (_, episode) = try seedEpisode(in: context)
        let playlist = Playlist()
        playlist.title = "Custom"
        context.insert(playlist)
        let entry = PlaylistEntry(episode: episode, order: 0)
        context.insert(entry)
        entry.playlist = playlist
        try context.save()

        context.delete(playlist)
        try context.save()

        let stranded = try context.fetch(FetchDescriptor<PlaylistEntry>())
        XCTAssertEqual(stranded.count, 1)
        XCTAssertNil(stranded.first?.playlist)
    }

    /// Deleting an episode leaves its entry in the playlist with no episode. The
    /// row is invisible to every reader that maps through `entry.episode`, but it
    /// still occupies a queue position and still syncs.
    @MainActor
    func testDeletingAnEpisodeLeavesAnEmptyEntryInThePlaylist() throws {
        let legacy = try ModelContainerManager.makeLegacyContainer(isStoredInMemoryOnly: true)
        let context = legacy.mainContext
        let (_, episode) = try seedEpisode(in: context)
        let playlist = Playlist()
        context.insert(playlist)
        let entry = PlaylistEntry(episode: episode, order: 0)
        context.insert(entry)
        entry.playlist = playlist
        try context.save()

        context.delete(episode)
        try context.save()

        XCTAssertEqual(playlist.items?.count, 1)
        XCTAssertNil(playlist.items?.first?.episode)
        XCTAssertTrue(
            playlist.storeSplitSnapshot.entries.isEmpty,
            "an entry with no episode has no stable identity, so it must not be published"
        )
    }

    private func seedEpisode(in context: ModelContext) throws -> (Podcast, Episode) {
        let podcast = Podcast(feed: URL(string: "https://example.com/probe")!)
        context.insert(podcast)
        let episode = Episode(
            guid: "probe-1",
            title: "Probe 1",
            url: URL(string: "https://example.com/probe-1.mp3")!,
            podcast: podcast
        )
        context.insert(episode)
        return (podcast, episode)
    }
}
