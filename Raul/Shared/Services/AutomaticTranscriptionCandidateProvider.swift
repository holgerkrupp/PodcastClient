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
    /// Upper bound on the episodes inspected per playlist. A smart playlist can
    /// match a whole library, and deciding whether an episode is downloaded
    /// touches the file system, so the scan stays near the top of each list.
    static let maximumEpisodesScannedPerPlaylist = 200

    private let modelContext: ModelContext
    private let selectedPlaylistID: UUID?
    /// `podcast.episodes` is a fault; resolving it once per podcast keeps a scan
    /// over several playlists from faulting the same back catalog repeatedly.
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

        playlistScan: for playlist in playlists {
            let episodes: [Episode]
            if playlist.isSmartPlaylist {
                if allEpisodes == nil {
                    allEpisodes = (try? modelContext.fetch(FetchDescriptor<Episode>())) ?? []
                }
                episodes = SmartPlaylistEngine.episodes(from: allEpisodes ?? [], for: playlist)
            } else {
                episodes = orderedEntries(in: playlist.id).compactMap(\.episode)
            }

            let playlistTitle = playlist.displayTitle

            for episode in episodes.prefix(Self.maximumEpisodesScannedPerPlaylist) {
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
        guard let podcast = episode.podcast else { return false }

        let cacheKey = podcast.persistentModelID
        if let cached = podcastPublishesTranscriptsCache[cacheKey] {
            return cached
        }

        let publishesTranscripts = (podcast.episodes ?? []).contains { candidate in
            candidate.externalFiles.contains { $0.category == .transcript }
        }
        podcastPublishesTranscriptsCache[cacheKey] = publishesTranscripts
        return publishesTranscripts
    }

    /// Visible playlists in display order, with the playlist the user plays from
    /// pulled to the front.
    private func orderedPlaylists() -> [Playlist] {
        let allPlaylists = (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []
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
        let descriptor = FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate<PlaylistEntry> { entry in
                entry.playlist?.id == playlistID
            },
            sortBy: [
                SortDescriptor(\PlaylistEntry.order, order: .forward),
                SortDescriptor(\PlaylistEntry.dateAdded, order: .forward)
            ]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}
