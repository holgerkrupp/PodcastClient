//
//  AutomaticTranscriptionCandidateProvider.swift
//  Raul
//
//  Picks the episodes automatic transcription works on next.
//

import Foundation
import SwiftData

/// Where the transcript for an episode is expected to come from.
enum AutomaticTranscriptionSource: String, Sendable {
    /// The feed publishes a transcript file. Importing it costs one small
    /// download, so it is always preferred over running the analyzer.
    case publishedTranscript
    /// Nobody publishes a transcript for this episode, so the on-device
    /// analyzer is the only way to get one.
    case onDevice
}

struct AutomaticTranscriptionCandidate: Sendable, Equatable {
    let episodeURL: URL
    let playlistTitle: String
    let source: AutomaticTranscriptionSource
}

/// Selects transcription candidates from the user's playlists.
///
/// Selection walks the playlists the way the user sees them — the playlist they
/// play from first, then the remaining visible playlists in their configured
/// order — so the episodes closest to being played get a transcript first.
/// Earlier revisions only ever looked at Up Next, which left everything queued
/// in another playlist untranscribed.
///
/// Within that order the episodes whose feed already publishes a transcript come
/// first: importing a published transcript takes seconds while the analyzer
/// takes minutes, so a background window that starts with the cheap ones ends
/// with more transcribed episodes.
actor AutomaticTranscriptionCandidateProvider {
    static let defaultLimit = 24
    /// Do not materialize every episode in a large or unsupported smart
    /// playlist just to find a small number of transcription candidates.
    static let maximumUnsupportedSmartPlaylistLibraryScan = 200
    /// Upper bound on the episodes inspected per playlist. A smart playlist can
    /// match a whole library, and deciding whether an episode is downloaded
    /// touches the file system, so the scan stays near the top of each list.
    static let maximumEpisodesScannedPerPlaylist = 200
    /// A transcript publication check is opportunistic. If a podcast has more
    /// than this many recent episodes and none of them has a transcript, treat
    /// its publication status as unknown and skip on-device analysis.
    static let maximumPodcastTranscriptScan = 64

    private let modelContext: ModelContext
    private let selectedPlaylistID: UUID?
    /// Cache the result of a concrete store query once per podcast. Do not walk
    /// `podcast.episodes`: a relationship fault can be invalidated by a feed
    /// import while the launch-time transcription sweep is starting.
    private var podcastPublishesTranscriptsCache: [PersistentIdentifier: Bool] = [:]

    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
        self.selectedPlaylistID = Playlist.resolvePlaylistID(
            from: UserDefaults.standard.string(forKey: PlaylistPreferenceKeys.selectedPlaylistID)
        )
    }

    init(modelContainer: ModelContainer, selectedPlaylistID: UUID?) {
        self.modelContext = ModelContext(modelContainer)
        self.selectedPlaylistID = selectedPlaylistID
    }

    /// Ordered transcription candidates across every visible playlist.
    ///
    /// - Parameters:
    ///   - limit: Upper bound on the returned candidates.
    ///   - allowOnDeviceFallback: When `false`, only episodes with a published
    ///     transcript are returned, so the caller never starts the analyzer.
    ///   - excludedEpisodeURLs: Episodes the caller already handled (running,
    ///     finished, or parked after a failed attempt).
    func candidates(
        limit: Int = AutomaticTranscriptionCandidateProvider.defaultLimit,
        allowOnDeviceFallback: Bool = true,
        excluding excludedEpisodeURLs: Set<URL> = []
    ) -> [AutomaticTranscriptionCandidate] {
        guard limit > 0 else { return [] }

        let playlists = orderedPlaylists()
        guard playlists.isEmpty == false else { return [] }

        var allEpisodes: [Episode]?
        var seenEpisodeURLs = Set<URL>()
        var publishedCandidates: [AutomaticTranscriptionCandidate] = []
        var onDeviceCandidates: [AutomaticTranscriptionCandidate] = []
        var scannedEpisodeCount = 0
        let scanStartedAt = ProcessInfo.processInfo.systemUptime

        playlistScan: for playlist in playlists {
            let episodes: [Episode]
            if playlist.isSmartPlaylist {
                if SmartPlaylistEngine.candidatePlan(for: playlist.smartFilter) != nil {
                    let candidates = (try? SmartPlaylistEngine.boundedCandidateEpisodes(
                        in: modelContext,
                        for: playlist.smartFilter,
                        limit: Self.maximumEpisodesScannedPerPlaylist + 1
                    )) ?? []
                    episodes = SmartPlaylistEngine.episodes(from: candidates, for: playlist)
                } else {
                    if allEpisodes == nil {
                        var descriptor = FetchDescriptor<Episode>(
                            sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
                        )
                        descriptor.fetchLimit = Self.maximumUnsupportedSmartPlaylistLibraryScan + 1
                        allEpisodes = (try? modelContext.fetch(descriptor)) ?? []
                    }
                    episodes = SmartPlaylistEngine.episodes(from: allEpisodes ?? [], for: playlist)
                }
            } else {
                episodes = orderedEntries(in: playlist.id).compactMap(\.episode)
            }

            let playlistTitle = playlist.displayTitle

            for episode in episodes.prefix(Self.maximumEpisodesScannedPerPlaylist) {
                scannedEpisodeCount += 1
                guard let episodeURL = episode.url else { continue }
                guard excludedEpisodeURLs.contains(episodeURL) == false else { continue }
                guard seenEpisodeURLs.insert(episodeURL).inserted else { continue }
                guard let source = transcriptionSource(
                    for: episode,
                    allowOnDeviceFallback: allowOnDeviceFallback
                ) else { continue }

                let candidate = AutomaticTranscriptionCandidate(
                    episodeURL: episodeURL,
                    playlistTitle: playlistTitle,
                    source: source
                )

                switch source {
                case .publishedTranscript:
                    publishedCandidates.append(candidate)
                case .onDevice:
                    onDeviceCandidates.append(candidate)
                }

                if publishedCandidates.count + onDeviceCandidates.count >= limit {
                    break playlistScan
                }
            }
        }

        AppDiagnostics.log(
            "automatic_transcription_candidates scanned=\(scannedEpisodeCount) candidates=\(min(limit, publishedCandidates.count + onDeviceCandidates.count)) duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - scanStartedAt) * 1_000))"
        )

        return Array((publishedCandidates + onDeviceCandidates).prefix(limit))
    }

    /// Re-classifies a single episode, e.g. to check whether an attempt left it
    /// waiting for another try.
    func transcriptionSource(
        for episodeURL: URL,
        allowOnDeviceFallback: Bool = true
    ) -> AutomaticTranscriptionSource? {
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.url == episodeURL }
        )
        descriptor.fetchLimit = 1
        guard let episode = try? modelContext.fetch(descriptor).first else { return nil }
        return transcriptionSource(for: episode, allowOnDeviceFallback: allowOnDeviceFallback)
    }

    // MARK: - Private helpers

    private func transcriptionSource(
        for episode: Episode,
        allowOnDeviceFallback: Bool
    ) -> AutomaticTranscriptionSource? {
        guard episode.hasLoadedTranscript == false else { return nil }

        if episode.externalFiles.contains(where: { $0.category == .transcript }) {
            return .publishedTranscript
        }

        guard allowOnDeviceFallback else { return nil }

        // A podcast that publishes transcripts for its other episodes publishes
        // one for this episode too, usually within a day of release. Running the
        // analyzer on it would spend minutes of CPU and battery on a transcript
        // the next feed refresh brings in for free.
        guard podcastPublishesTranscripts(episode) == false else { return nil }

        // The analyzer reads the downloaded audio file; without it there is
        // nothing to transcribe.
        guard episode.metaData?.calculatedIsAvailableLocally == true else { return nil }

        return .onDevice
    }

    private func podcastPublishesTranscripts(_ episode: Episode) -> Bool {
        guard let podcastID = episode.podcast?.persistentModelID else { return false }

        let cacheKey = podcastID
        if let cached = podcastPublishesTranscriptsCache[cacheKey] {
            return cached
        }

        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { candidate in
                candidate.podcast?.persistentModelID == podcastID
            },
            sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = Self.maximumPodcastTranscriptScan + 1
        // Automatic transcription is opportunistic. If SwiftData cannot
        // materialize this query during launch/import, fail closed and let the
        // next sweep retry instead of faulting a relationship.
        guard let episodes = try? modelContext.fetch(descriptor) else {
            podcastPublishesTranscriptsCache[cacheKey] = true
            return true
        }
        let publishesTranscripts = episodes.contains { candidate in
            candidate.externalFiles.contains { $0.category == .transcript }
        }
        // If the bounded sample filled, absence of a transcript is not
        // evidence that the publisher never provides one. Fail closed and
        // avoid starting optional multi-minute analysis.
        let result = publishesTranscripts || episodes.count > Self.maximumPodcastTranscriptScan
        podcastPublishesTranscriptsCache[cacheKey] = result
        return result
    }

    /// Visible playlists in display order, with the playlist the user plays from
    /// pulled to the front.
    private func orderedPlaylists() -> [Playlist] {
        var descriptor = FetchDescriptor<Playlist>(
            sortBy: [SortDescriptor(\.sortIndex, order: .forward)]
        )
        descriptor.fetchLimit = 64
        var allPlaylists = (try? modelContext.fetch(descriptor)) ?? []
        if let selectedPlaylistID,
           allPlaylists.contains(where: { $0.id == selectedPlaylistID }) == false {
            var selectedDescriptor = FetchDescriptor<Playlist>(
                predicate: #Predicate<Playlist> { $0.id == selectedPlaylistID }
            )
            selectedDescriptor.fetchLimit = 1
            if let selected = try? modelContext.fetch(selectedDescriptor).first {
                allPlaylists.append(selected)
            }
        }
        guard allPlaylists.isEmpty == false else { return [] }

        var ordered = Playlist.visibleSorted(allPlaylists)
        if let selectedPlaylistID,
           let selectedIndex = ordered.firstIndex(where: { $0.id == selectedPlaylistID }),
           selectedIndex > 0 {
            let selected = ordered.remove(at: selectedIndex)
            ordered.insert(selected, at: 0)
        }

        return ordered
    }

    /// Entries in storage order instead of sorting the relationship in memory:
    /// SwiftData can invalidate a relationship object while another context
    /// updates the playlist, and reading `order` from it then traps.
    private func orderedEntries(in playlistID: UUID) -> [PlaylistEntry] {
        var descriptor = FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate<PlaylistEntry> { entry in
                entry.playlist?.id == playlistID
            },
            sortBy: [
                SortDescriptor(\PlaylistEntry.order, order: .forward),
                SortDescriptor(\PlaylistEntry.dateAdded, order: .forward)
            ]
        )
        descriptor.fetchLimit = Self.maximumEpisodesScannedPerPlaylist + 1
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}
