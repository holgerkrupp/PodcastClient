import SwiftData
import XCTest
@testable import UpNext

final class AutomaticTranscriptionCandidateProviderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticTranscriptionCandidateProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testCandidatesComeFromEveryPlaylistNotJustUpNext() async throws {
        let fixture = try makeFixture()
        let queued = try makeDownloadedEpisode(title: "Queued", in: fixture)
        let other = try makeDownloadedEpisode(title: "Other", in: fixture)
        try queue(queued, in: fixture.defaultPlaylist, fixture: fixture)
        try queue(other, in: fixture.secondPlaylist, fixture: fixture)

        let provider = AutomaticTranscriptionCandidateProvider(
            modelContainer: fixture.container,
            defaults: fixture.defaults
        )
        let candidates = await provider.candidates()

        XCTAssertEqual(
            candidates.map(\.episodeURL),
            [queued.url, other.url].compactMap { $0 }
        )
        XCTAssertEqual(candidates.map(\.source), [.onDevice, .onDevice])
    }

    func testPublishedTranscriptsAreOfferedBeforeOnDeviceWork() async throws {
        let fixture = try makeFixture()
        let onDevice = try makeDownloadedEpisode(title: "Needs analyzer", in: fixture)
        let published = try makeDownloadedEpisode(title: "Has transcript", in: fixture)
        published.externalFiles = [transcriptFile()]
        try queue(onDevice, in: fixture.defaultPlaylist, fixture: fixture)
        try queue(published, in: fixture.defaultPlaylist, fixture: fixture)

        let provider = AutomaticTranscriptionCandidateProvider(
            modelContainer: fixture.container,
            defaults: fixture.defaults
        )
        let candidates = await provider.candidates()

        XCTAssertEqual(
            candidates.map(\.episodeURL),
            [published.url, onDevice.url].compactMap { $0 }
        )
        XCTAssertEqual(candidates.map(\.source), [.publishedTranscript, .onDevice])
    }

    func testOnDeviceCandidatesAreDroppedWhenTheAnalyzerIsNotAllowed() async throws {
        let fixture = try makeFixture()
        let onDevice = try makeDownloadedEpisode(title: "Needs analyzer", in: fixture)
        let published = try makeDownloadedEpisode(title: "Has transcript", in: fixture)
        published.externalFiles = [transcriptFile()]
        try queue(onDevice, in: fixture.defaultPlaylist, fixture: fixture)
        try queue(published, in: fixture.defaultPlaylist, fixture: fixture)

        let provider = AutomaticTranscriptionCandidateProvider(
            modelContainer: fixture.container,
            defaults: fixture.defaults
        )
        let candidates = await provider.candidates(allowOnDeviceFallback: false)

        XCTAssertEqual(candidates.map(\.episodeURL), [published.url].compactMap { $0 })
    }

    func testEpisodesOfPodcastsThatPublishTranscriptsAreNeverTranscribedOnDevice() async throws {
        let fixture = try makeFixture()
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        fixture.context.insert(podcast)

        let withTranscript = try makeDownloadedEpisode(title: "Published", in: fixture)
        withTranscript.externalFiles = [transcriptFile()]
        withTranscript.podcast = podcast

        let withoutTranscript = try makeDownloadedEpisode(title: "Not published yet", in: fixture)
        withoutTranscript.podcast = podcast

        try queue(withoutTranscript, in: fixture.defaultPlaylist, fixture: fixture)

        let provider = AutomaticTranscriptionCandidateProvider(
            modelContainer: fixture.container,
            defaults: fixture.defaults
        )
        let candidates = await provider.candidates()

        XCTAssertTrue(candidates.isEmpty)
    }

    func testEpisodesWithATranscriptAreNotCandidates() async throws {
        let fixture = try makeFixture()
        let transcribed = try makeDownloadedEpisode(title: "Transcribed", in: fixture)
        let line = TranscriptLineAndTime(text: "Hello", startTime: 0)
        fixture.context.insert(line)
        transcribed.transcriptLines = [line]
        try queue(transcribed, in: fixture.defaultPlaylist, fixture: fixture)

        let provider = AutomaticTranscriptionCandidateProvider(
            modelContainer: fixture.container,
            defaults: fixture.defaults
        )
        let candidates = await provider.candidates()

        XCTAssertTrue(candidates.isEmpty)
    }

    func testEpisodesThatAreNotDownloadedAreNotOnDeviceCandidates() async throws {
        let fixture = try makeFixture()
        let notDownloaded = Episode(
            guid: "not-downloaded",
            title: "Not downloaded",
            url: URL(string: "https://example.com/not-downloaded.mp3")!
        )
        fixture.context.insert(notDownloaded)
        try queue(notDownloaded, in: fixture.defaultPlaylist, fixture: fixture)

        let provider = AutomaticTranscriptionCandidateProvider(
            modelContainer: fixture.container,
            defaults: fixture.defaults
        )
        let candidates = await provider.candidates()

        XCTAssertTrue(candidates.isEmpty)
    }

    func testSelectedPlaylistIsScannedFirst() async throws {
        let fixture = try makeFixture()
        let queued = try makeDownloadedEpisode(title: "Queued", in: fixture)
        let other = try makeDownloadedEpisode(title: "Other", in: fixture)
        try queue(queued, in: fixture.defaultPlaylist, fixture: fixture)
        try queue(other, in: fixture.secondPlaylist, fixture: fixture)
        fixture.defaults.set(
            fixture.secondPlaylist.id.uuidString,
            forKey: PlaylistPreferenceKeys.selectedPlaylistID
        )

        let provider = AutomaticTranscriptionCandidateProvider(
            modelContainer: fixture.container,
            defaults: fixture.defaults
        )
        let candidates = await provider.candidates()

        XCTAssertEqual(
            candidates.map(\.episodeURL),
            [other.url, queued.url].compactMap { $0 }
        )
    }

    func testExcludedEpisodesAreSkipped() async throws {
        let fixture = try makeFixture()
        let first = try makeDownloadedEpisode(title: "First", in: fixture)
        let second = try makeDownloadedEpisode(title: "Second", in: fixture)
        try queue(first, in: fixture.defaultPlaylist, fixture: fixture)
        try queue(second, in: fixture.defaultPlaylist, fixture: fixture)

        let provider = AutomaticTranscriptionCandidateProvider(
            modelContainer: fixture.container,
            defaults: fixture.defaults
        )
        let candidates = await provider.candidates(
            excluding: [try XCTUnwrap(first.url)]
        )

        XCTAssertEqual(candidates.map(\.episodeURL), [second.url].compactMap { $0 })
    }

    // MARK: - Fixture

    struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let defaults: UserDefaults
        let defaultPlaylist: Playlist
        let secondPlaylist: Playlist
    }

    private func makeFixture() throws -> Fixture {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            Episode.self,
            EpisodeMetaData.self,
            Playlist.self,
            PlaylistEntry.self,
            TranscriptLineAndTime.self,
            Marker.self,
            Bookmark.self,
            RateSegment.self,
            PlaySession.self,
            ListeningStat.self,
            PlaySessionSummary.self,
            TranscriptionRecord.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let defaultPlaylist = Playlist.ensureDefaultQueue(in: context)

        let secondPlaylist = Playlist()
        secondPlaylist.title = "Later"
        secondPlaylist.deleteable = true
        secondPlaylist.hidden = false
        secondPlaylist.sortIndex = 1
        secondPlaylist.kind = .manual
        context.insert(secondPlaylist)
        try context.save()

        let suiteName = "AutomaticTranscriptionCandidateProviderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        return Fixture(
            container: container,
            context: context,
            defaults: defaults,
            defaultPlaylist: defaultPlaylist,
            secondPlaylist: secondPlaylist
        )
    }

    /// A side-loaded episode backed by a real file, so `calculatedIsAvailableLocally`
    /// reports the episode as downloaded.
    private func makeDownloadedEpisode(title: String, in fixture: Fixture) throws -> Episode {
        let fileURL = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        try Data("audio".utf8).write(to: fileURL)

        let episode = Episode(
            guid: "\(title)-\(UUID().uuidString)",
            title: title,
            url: fileURL,
            source: .sideLoaded
        )
        fixture.context.insert(episode)
        try fixture.context.save()

        XCTAssertEqual(episode.metaData?.calculatedIsAvailableLocally, true)
        return episode
    }

    private func transcriptFile() -> ExternalFile {
        ExternalFile(
            url: "https://example.com/transcript.vtt",
            category: .transcript,
            source: nil,
            fileType: "text/vtt"
        )
    }

    private func queue(_ episode: Episode, in playlist: Playlist, fixture: Fixture) throws {
        let order = (playlist.items?.count ?? 0)
        let entry = PlaylistEntry(episode: episode, order: order)
        fixture.context.insert(entry)
        entry.playlist = playlist
        try fixture.context.save()
    }
}
