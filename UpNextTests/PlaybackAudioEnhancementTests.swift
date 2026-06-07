import SwiftData
import XCTest
@testable import UpNext

final class PlaybackAudioEnhancementTests: XCTestCase {
    func testSilenceDetectorStartsAfterSustainedQuietAudio() {
        var detector = AudioSilenceGapDetector(level: .high)

        XCTAssertNil(detector.observe(decibels: -50, duration: 0.2))
        XCTAssertEqual(detector.observe(decibels: -50, duration: 0.16), true)
    }

    func testSilenceDetectorStopsWhenAudioReturns() {
        var detector = AudioSilenceGapDetector(level: .high)

        _ = detector.observe(decibels: -50, duration: 0.4)

        XCTAssertEqual(detector.observe(decibels: -20, duration: 0.02), false)
        XCTAssertNil(detector.observe(decibels: -20, duration: 0.02))
    }

    func testSilenceReducedRateIsClamped() {
        XCTAssertEqual(AudioSilenceGapDetector.silenceReducedRate(for: 1.0, level: .high), 1.8)
        XCTAssertEqual(AudioSilenceGapDetector.silenceReducedRate(for: 2.5, level: .high), 3.0)
    }

    func testLowSilenceReductionWaitsLongerAndUsesGentlerRate() {
        var detector = AudioSilenceGapDetector(level: .low)

        XCTAssertNil(detector.observe(decibels: -55, duration: 0.5))
        XCTAssertEqual(detector.observe(decibels: -55, duration: 0.16), true)
        XCTAssertEqual(AudioSilenceGapDetector.silenceReducedRate(for: 1.0, level: .low), 1.25)
    }

    func testVoiceEnhancerGraduallyRaisesQuietSpeech() {
        let sampleRate = 48_000
        let enhancer = SpokenWordEnhancer(sampleRate: Double(sampleRate), channelCount: 1)
        var inputEnergy: Float = 0
        var outputEnergy: Float = 0
        let measuredSamples = sampleRate

        for index in 0..<(sampleRate * 6) {
            let sample = Float(sin(2 * Double.pi * 220 * Double(index) / Double(sampleRate))) * 0.03
            let output = enhancer.process(sample: sample, channel: 0)
            if index >= sampleRate * 5 {
                inputEnergy += sample * sample
                outputEnergy += output * output
            }
        }

        XCTAssertGreaterThan(outputEnergy / Float(measuredSamples), inputEnergy / Float(measuredSamples))
        XCTAssertGreaterThan(enhancer.currentGain, 1)
    }

    func testVoiceEnhancerRejectsSteadyLowFrequencyOffset() {
        let enhancer = SpokenWordEnhancer(sampleRate: 48_000, channelCount: 1)
        var output: Float = 0

        for _ in 0..<48_000 {
            output = enhancer.process(sample: 0.2, channel: 0)
        }

        XCTAssertLessThan(abs(output), 0.001)
    }

    func testVoiceEnhancerLimitsFullScalePeaks() {
        let enhancer = SpokenWordEnhancer(sampleRate: 48_000, channelCount: 1)
        var maximumOutput: Float = 0

        for index in 0..<48_000 {
            let sample: Float = index.isMultiple(of: 100) ? 1 : 0.2
            maximumOutput = max(
                maximumOutput,
                abs(enhancer.process(sample: sample, channel: 0))
            )
        }

        XCTAssertLessThanOrEqual(maximumOutput, 0.892)
    }

    func testAudioEnhancementSettingsFallbackToGlobalDefaults() async throws {
        let fixture = try makeSettingsFixture()
        let globalSettings = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<PodcastSettings>()).first)
        globalSettings.reduceSilenceGapsEnabled = true
        globalSettings.silenceGapReductionLevel = .medium
        globalSettings.voiceEnhancementEnabled = true
        try fixture.context.save()

        let actor = PodcastSettingsModelActor(modelContainer: fixture.container)
        let reduceSilence = await actor.getReduceSilenceGapsEnabled(for: fixture.podcast.feed)
        let voiceEnhancement = await actor.getVoiceEnhancementEnabled(for: fixture.podcast.feed)
        let reductionLevel = await actor.getSilenceGapReductionLevel(for: fixture.podcast.feed)

        XCTAssertTrue(reduceSilence)
        XCTAssertTrue(voiceEnhancement)
        XCTAssertEqual(reductionLevel, .medium)
    }

    func testAudioEnhancementSettingsUseEnabledPodcastOverrides() async throws {
        let fixture = try makeSettingsFixture()
        let globalSettings = try XCTUnwrap(try fixture.context.fetch(FetchDescriptor<PodcastSettings>()).first)
        globalSettings.reduceSilenceGapsEnabled = true
        globalSettings.voiceEnhancementEnabled = true

        let customSettings = PodcastSettings(podcast: fixture.podcast)
        customSettings.isEnabled = true
        customSettings.reduceSilenceGapsEnabled = false
        customSettings.silenceGapReductionLevel = .high
        customSettings.voiceEnhancementEnabled = false
        fixture.context.insert(customSettings)
        fixture.podcast.settings = customSettings
        try fixture.context.save()

        let actor = PodcastSettingsModelActor(modelContainer: fixture.container)
        let reduceSilence = await actor.getReduceSilenceGapsEnabled(for: fixture.podcast.feed)
        let voiceEnhancement = await actor.getVoiceEnhancementEnabled(for: fixture.podcast.feed)
        let reductionLevel = await actor.getSilenceGapReductionLevel(for: fixture.podcast.feed)

        XCTAssertFalse(reduceSilence)
        XCTAssertFalse(voiceEnhancement)
        XCTAssertEqual(reductionLevel, .high)
    }

    func testSilenceGapTimeSavedPersistsForSessionEpisodeAndStats() async throws {
        let fixture = try makeSettingsFixture()
        let episodeURL = URL(string: "https://example.com/episode.mp3")!
        let episode = Episode(
            guid: "episode",
            title: "Episode",
            url: episodeURL,
            podcast: fixture.podcast,
            duration: 600
        )
        let metadata = EpisodeMetaData()
        metadata.episode = episode
        episode.metaData = metadata
        fixture.context.insert(episode)
        fixture.context.insert(metadata)
        try fixture.context.save()

        let actor = PlaySessionTrackerActor(modelContainer: fixture.container)
        await actor.startOrUpdateSession(episodeURL: episodeURL, position: 0, rate: 1.0, appVersion: "test")
        await actor.recordSilenceGapTimeSaved(12.5)
        await actor.pauseSession(at: 20)
        await actor.rebuildListeningStats()

        let context = ModelContext(fixture.container)
        let sessions = try context.fetch(FetchDescriptor<PlaySession>())
        let savedSessionSeconds = try XCTUnwrap(sessions.first?.silenceGapTimeSavedSeconds)
        XCTAssertEqual(savedSessionSeconds, 12.5, accuracy: 0.001)

        let episodes = try context.fetch(FetchDescriptor<Episode>())
        let savedEpisodeSeconds = try XCTUnwrap(episodes.first(where: { $0.url == episodeURL })?.metaData?.totalSilenceGapTimeSaved)
        XCTAssertEqual(savedEpisodeSeconds, 12.5, accuracy: 0.001)

        let stats = try context.fetch(FetchDescriptor<ListeningStat>())
        let savedStatSeconds = stats.reduce(0.0) { $0 + ($1.silenceGapTimeSavedSeconds ?? 0) }
        XCTAssertEqual(savedStatSeconds, 12.5, accuracy: 0.001)

        let summaries = try context.fetch(FetchDescriptor<PlaySessionSummary>())
        XCTAssertTrue(summaries.contains { summary in
            (summary.silenceGapTimeSavedSeconds ?? 0) > 12.49
        }, "Summaries: \(summaries.map { "\($0.periodKind ?? "nil")=\($0.silenceGapTimeSavedSeconds ?? -1)" })")
    }

    func testPlaybackRateTimeSavedPersistsInStatsAndSummaries() async throws {
        let fixture = try makeSettingsFixture()
        let episodeURL = URL(string: "https://example.com/fast-episode.mp3")!
        let episode = Episode(
            guid: "fast-episode",
            title: "Fast Episode",
            url: episodeURL,
            podcast: fixture.podcast,
            duration: 600
        )
        fixture.context.insert(episode)
        try fixture.context.save()

        let actor = PlaySessionTrackerActor(modelContainer: fixture.container)
        await actor.startOrUpdateSession(episodeURL: episodeURL, position: 0, rate: 2.0, appVersion: "test")
        try await Task.sleep(for: .milliseconds(50))
        await actor.pauseSession(at: 0.1)
        await actor.rebuildListeningStats()

        let context = ModelContext(fixture.container)
        let stats = try context.fetch(FetchDescriptor<ListeningStat>())
        let savedStatSeconds = stats.reduce(0.0) { $0 + ($1.playbackRateTimeSavedSeconds ?? 0) }
        XCTAssertGreaterThan(savedStatSeconds, 0)

        let summaries = try context.fetch(FetchDescriptor<PlaySessionSummary>())
        XCTAssertTrue(summaries.contains { ($0.playbackRateTimeSavedSeconds ?? 0) > 0 })
    }

    func testPlaybackRateSavingsDoesNotDoubleCountOverlappingUnorderedSegments() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let end = start.addingTimeInterval(100)
        let laterSegment = RateSegment(
            rate: 1.5,
            startTime: start.addingTimeInterval(60),
            endTime: end
        )
        let earlierOverlappingSegment = RateSegment(
            rate: 1.5,
            startTime: start,
            endTime: end
        )
        let session = PlaySession(
            startTime: start,
            endTime: end,
            segments: [laterSegment, earlierOverlappingSegment]
        )

        XCTAssertEqual(
            PlaybackRateSavingsCalculator.secondsSaved(in: session),
            50,
            accuracy: 0.001
        )
    }
}

private extension PlaybackAudioEnhancementTests {
    struct SettingsFixture {
        let container: ModelContainer
        let context: ModelContext
        let podcast: Podcast
    }

    func makeSettingsFixture() throws -> SettingsFixture {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Podcast.self,
            PodcastMetaData.self,
            Episode.self,
            EpisodeMetaData.self,
            Playlist.self,
            PlaylistEntry.self,
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

        let globalSettings = PodcastSettings()
        globalSettings.title = "de.holgerkrupp.podbay.queue"
        globalSettings.defaultPlaylistID = defaultPlaylist.id
        context.insert(globalSettings)

        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        podcast.title = "Example"
        context.insert(podcast)
        try context.save()

        return SettingsFixture(container: container, context: context, podcast: podcast)
    }
}
