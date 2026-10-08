//
//  PlaylistAutoDownloadService.swift
//  Raul
//

import Foundation
import SwiftData

/// Keeps a playlist's first episodes downloaded.
///
/// This is deliberately independent of `EpisodeActor.applyAutomaticDownloadPolicy`,
/// which only ever looks at a single podcast's newest or oldest unplayed
/// episodes. A playlist mixes shows and carries a user-defined order, so the
/// only thing that decides what to fetch here is the playlist order itself.
///
/// The policy never deletes anything: leaving the playlist (or the per-podcast
/// policy) stays the only thing that removes a downloaded file.
@ModelActor
actor PlaylistAutoDownloadService {
    private func log(_ message: String) async {
        await MainActor.run {
            AppDiagnostics.log("[AutoDL] \(message)")
        }
    }

    private func playlist(id: UUID) -> Playlist? {
        var descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Entries are read through their own fetch rather than through
    /// `playlist.items`, so an invalidated relationship object cannot trap while
    /// another context is writing the playlist. See `PlaylistModelActor`.
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

    private func autoDownloadPlaylistIDs() -> [UUID] {
        let descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { $0.autoDownloadEnabled == true }
        )
        return ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { $0.isSmartPlaylist == false }
            .map(\.id)
    }

    /// Whether any playlist would need the network gate re-checked once Wi-Fi
    /// comes back.
    func hasPlaylistsWithAutoDownload() -> Bool {
        autoDownloadPlaylistIDs().isEmpty == false
    }

    func applyPolicyToAllPlaylists(force: Bool = false) async {
        let playlistIDs = autoDownloadPlaylistIDs()
        guard playlistIDs.isEmpty == false else { return }

        await log("playlist-policy/apply-all count=\(playlistIDs.count) force=\(force)")
        for playlistID in playlistIDs {
            await applyPolicy(for: playlistID, force: force)
        }
    }

    /// The episodes this playlist's policy would fetch, in playlist order.
    ///
    /// Split out of `applyPolicy` so the selection rule stays verifiable without
    /// a network round trip. Returns nothing for a playlist whose policy is off.
    func pendingDownloadURLs(for playlistID: UUID) -> [URL] {
        guard let playlist = playlist(id: playlistID),
              playlist.autoDownloadEnabled,
              playlist.isSmartPlaylist == false else {
            return []
        }

        let orderedEpisodes = orderedEntries(in: playlistID).compactMap(\.episode)
        let targetEpisodes = playlist.resolvedAutoDownloadEpisodeLimit
            .map { Array(orderedEpisodes.prefix($0)) } ?? orderedEpisodes

        let globalTitle = "de.holgerkrupp.podbay.queue"
        var globalDescriptor = FetchDescriptor<PodcastSettings>(
            predicate: #Predicate<PodcastSettings> { $0.title == globalTitle }
        )
        globalDescriptor.fetchLimit = 1
        let globalSettings = try? modelContext.fetch(globalDescriptor).first

        return targetEpisodes.compactMap { episode -> URL? in
            guard let episodeURL = episode.url else { return nil }
            // A sideloaded file has no remote to fetch, and anything already on
            // disk is nothing to re-fetch.
            guard episode.source != .sideLoaded else { return nil }
            guard episode.metaData?.calculatedIsAvailableLocally != true else { return nil }
            let customSettings = episode.podcast?.settings
            let resolvedSettings = customSettings?.isEnabled == true ? customSettings : globalSettings
            if let resolvedSettings,
               resolvedSettings.autoDownloadFilter.allows(
                   title: episode.title,
                   duration: episode.duration,
                   publishDate: episode.publishDate,
                   type: episode.type
               ) == false {
                return nil
            }
            return episodeURL
        }
    }

    func applyPolicy(for playlistID: UUID, force: Bool = false) async {
        let throttle = PlaylistAutoDownloadThrottle.shared

        switch await throttle.begin(playlistID: playlistID, force: force) {
        case .run:
            break
        case .skip(let reason):
            await log("playlist-policy/skip playlist=\(playlistID.uuidString) reason=\(reason)")
            return
        }
        defer {
            Task {
                await throttle.finish(playlistID: playlistID)
            }
        }

        guard let playlist = playlist(id: playlistID) else {
            await log("playlist-policy/skip playlist=\(playlistID.uuidString) reason=playlist-not-found")
            return
        }
        guard playlist.autoDownloadEnabled else {
            await log("playlist-policy/skip playlist=\(playlistID.uuidString) reason=disabled")
            return
        }
        // Smart playlists resolve their contents by scanning every episode, which
        // is far too heavy to run on every playlist mutation.
        guard playlist.isSmartPlaylist == false else {
            await log("playlist-policy/skip playlist=\(playlistID.uuidString) reason=smart-playlist")
            return
        }

        let playlistTitle = playlist.displayTitle
        let pendingEpisodeURLs = pendingDownloadURLs(for: playlistID)

        await log(
            "playlist-policy/config playlist=\(playlistTitle) limit=\(playlist.resolvedAutoDownloadEpisodeLimit.map(String.init) ?? "none") pending=\(pendingEpisodeURLs.count)"
        )

        guard pendingEpisodeURLs.isEmpty == false else {
            await log("playlist-policy/done playlist=\(playlistTitle) reason=nothing-to-download")
            return
        }

        let networkMode = await PodcastSettingsModelActor(modelContainer: modelContainer)
            .globalAutoDownloadNetworkMode()
        guard await AutoDownloadNetworkGate.canScheduleDownloads(for: networkMode) else {
            await log(
                "playlist-policy/defer playlist=\(playlistTitle) pending=\(pendingEpisodeURLs.count) reason=network-gate network=\(networkMode.rawValue)"
            )
            return
        }

        let episodeActor = EpisodeActor(modelContainer: modelContainer)
        for episodeURL in pendingEpisodeURLs {
            await log("playlist-policy/download playlist=\(playlistTitle) episode=\(episodeURL.redactedPodcastURLString)")
            await episodeActor.download(episodeURL: episodeURL)
        }

        await log("playlist-policy/done playlist=\(playlistTitle) started=\(pendingEpisodeURLs.count)")
    }
}

/// Playlists change far more often than feeds do — every queue insert, removal
/// and reorder is a reason to re-check — so the policy is rate limited the same
/// way the per-podcast policy is.
actor PlaylistAutoDownloadThrottle {
    static let shared = PlaylistAutoDownloadThrottle()

    private let minimumInterval: TimeInterval = 60
    private var lastStartedAtByPlaylist: [UUID: Date] = [:]
    private var inFlightPlaylists = Set<UUID>()

    private init() {}

    func begin(
        playlistID: UUID,
        force: Bool,
        now: Date = Date()
    ) -> AutoDownloadPolicyThrottleDecision {
        if inFlightPlaylists.contains(playlistID) {
            return .skip(reason: "already-in-flight")
        }

        if force == false,
           let lastStartedAt = lastStartedAtByPlaylist[playlistID] {
            let elapsed = now.timeIntervalSince(lastStartedAt)
            if elapsed < minimumInterval {
                return .skip(reason: "cooldown-\(Int(minimumInterval - elapsed))s-remaining")
            }
        }

        inFlightPlaylists.insert(playlistID)
        lastStartedAtByPlaylist[playlistID] = now
        return .run
    }

    /// A non-claiming look at what `begin` would decide.
    ///
    /// Callers use it to avoid building a whole model context for a playlist
    /// that is only going to be turned away — a bulk import can fire this
    /// hundreds of times in a row. `begin` still makes the real decision.
    func shouldSchedule(playlistID: UUID, force: Bool, now: Date = Date()) -> Bool {
        if inFlightPlaylists.contains(playlistID) {
            return false
        }
        if force == false,
           let lastStartedAt = lastStartedAtByPlaylist[playlistID] {
            return now.timeIntervalSince(lastStartedAt) >= minimumInterval
        }
        return true
    }

    func finish(playlistID: UUID) {
        inFlightPlaylists.remove(playlistID)
    }
}

/// Fire-and-forget entry points for callers that only have a container.
enum PlaylistAutoDownloadCoordinator {
    static func schedule(
        playlistID: UUID,
        modelContainer: ModelContainer,
        force: Bool = false
    ) {
        Task.detached(priority: .utility) {
            guard await PlaylistAutoDownloadThrottle.shared.shouldSchedule(
                playlistID: playlistID,
                force: force
            ) else { return }

            await PlaylistAutoDownloadService(modelContainer: modelContainer)
                .applyPolicy(for: playlistID, force: force)
        }
    }

    static func scheduleAll(
        modelContainer: ModelContainer,
        force: Bool = false
    ) {
        Task.detached(priority: .utility) {
            await PlaylistAutoDownloadService(modelContainer: modelContainer)
                .applyPolicyToAllPlaylists(force: force)
        }
    }
}
