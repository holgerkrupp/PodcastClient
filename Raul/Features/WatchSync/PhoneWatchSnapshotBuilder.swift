//
//  PhoneWatchSnapshotBuilder.swift
//  Raul
//

import Foundation
import SwiftData
#if canImport(WatchConnectivity)

/// The parts of the snapshot only the main actor knows about: the player state
/// and the file transfers currently in flight.
struct WatchSnapshotInput: Sendable {
    var phoneTransferEpisodeIDs: [String]
    var phoneTransferProgressByEpisodeID: [String: Double]
    var phonePlaybackState: WatchPhonePlaybackState?
}

struct WatchTransferCandidate: Sendable {
    let fileURL: URL
    let size: Int64
}

struct WatchSnapshotBundle: Sendable {
    let snapshot: WatchSyncSnapshot
    let transferCandidates: [String: WatchTransferCandidate]
}

/// The identifiers a watch command needs to address a playlist, without handing
/// model objects across actors.
struct WatchPlaylistSelectionSummary: Sendable {
    let selectedPlaylistID: UUID
    let manualPlaylistIDs: [UUID]

    func resolvedPlaylistID(preferring requestedPlaylistID: UUID?) -> UUID {
        guard let requestedPlaylistID,
              manualPlaylistIDs.contains(requestedPlaylistID) else {
            return selectedPlaylistID
        }

        return requestedPlaylistID
    }
}

enum WatchSyncChapterIdentity {
    static func syncID(for chapter: Marker) -> String {
        chapter.uuid?.uuidString ?? "\(chapter.start ?? 0)-\(chapter.title)"
    }
}

/// Builds the watch snapshot away from the main thread.
///
/// The snapshot walks the selected playlist, the inbox, the chapters of every
/// queued episode and the per-podcast settings. Doing that on the main actor
/// parked the main thread inside SwiftData for as long as the store stayed
/// busy, and the scene-update watchdog killed the app (0x8BADF00D) when it went
/// past ten seconds - most often right after a background launch, where the
/// watch session activates while a refresh or a CloudKit import is still
/// running.
@ModelActor
actor PhoneWatchSnapshotBuilder {
    /// A Watch snapshot must fit inside the background scene-update budget.
    /// The watch UI remains useful with a recent queue window; trying to
    /// serialize an unbounded queue can fault thousands of SwiftData objects.
    private let maximumPlaylistSnapshotEpisodes = 100
    private let maximumInboxSnapshotEpisodes = 25
    private let maximumVisibleWatchPlaylists = 50
    private let maximumSnapshotChaptersPerEpisode = 100

    private struct PlaylistSelection {
        let selectedPlaylist: Playlist
        let manualPlaylists: [Playlist]
        let defaultPlaylistID: UUID?
    }

    func makeBundle(input: WatchSnapshotInput) -> WatchSnapshotBundle {
        let selection = resolvePlaylistSelection()
        let playlistEntries = (try? WatchSyncPlaylistEntryQuery.fetchOrdered(
            playlistID: selection.selectedPlaylist.id,
            in: modelContext,
            limit: maximumPlaylistSnapshotEpisodes
        )) ?? []
        let playlistEpisodes = playlistEntries.compactMap(\.episode)
        let inboxEpisodes = fetchInboxEpisodes()
        let settings = fetchStandardSettings()
        let enabledSettingsByFeed = fetchEnabledPodcastSettingsByFeed(
            for: playlistEpisodes + inboxEpisodes
        )
        let globalPlaybackSettings = makePlaybackSettings(from: settings, isPodcastSpecific: false)
        let watchPlaylists = makeSyncPlaylists(from: selection)

        var transferCandidates: [String: WatchTransferCandidate] = [:]
        let playlist = playlistEpisodes.compactMap { episode -> WatchSyncEpisode? in
            guard let syncEpisode = makeSyncEpisode(
                from: episode,
                globalSettings: settings,
                enabledSettingsByFeed: enabledSettingsByFeed,
                includeChapters: true
            ) else { return nil }
            if let candidate = makeTransferCandidate(from: episode) {
                transferCandidates[syncEpisode.id] = candidate
            }
            return syncEpisode
        }

        let inbox = inboxEpisodes.compactMap { episode in
            makeSyncEpisode(
                from: episode,
                globalSettings: settings,
                enabledSettingsByFeed: enabledSettingsByFeed,
                includeChapters: false
            )
        }

        return WatchSnapshotBundle(
            snapshot: WatchSyncSnapshot(
                generatedAt: .now,
                playlist: playlist,
                inbox: inbox,
                playlists: watchPlaylists,
                selectedPlaylistID: selection.selectedPlaylist.id.uuidString,
                selectedPlaylistTitle: selection.selectedPlaylist.displayTitle,
                skipBackSeconds: settings.skipBack.rawValue,
                skipForwardSeconds: settings.skipForward.rawValue,
                playbackSettings: globalPlaybackSettings,
                phoneTransferEpisodeIDs: input.phoneTransferEpisodeIDs,
                phoneTransferProgressByEpisodeID: input.phoneTransferProgressByEpisodeID,
                phonePlaybackState: input.phonePlaybackState
            ),
            transferCandidates: transferCandidates
        )
    }

    func playlistSelectionSummary() -> WatchPlaylistSelectionSummary {
        let selection = resolvePlaylistSelection()
        return WatchPlaylistSelectionSummary(
            selectedPlaylistID: selection.selectedPlaylist.id,
            manualPlaylistIDs: selection.manualPlaylists.map(\.id)
        )
    }

    private func resolvePlaylistSelection() -> PlaylistSelection {
        let defaults = UserDefaults.standard
        // Snapshot creation is a read-only background path. Default-queue
        // repair can fault every queued episode, so it belongs to foreground
        // maintenance rather than this selection lookup.
        let defaultPlaylist = Playlist.existingDefaultQueue(in: modelContext)
        let manualPlaylists = fetchVisibleManualPlaylists()
        let fallbackPlaylist = defaultPlaylist.flatMap { defaultPlaylist in
            manualPlaylists.first(where: { $0.id == defaultPlaylist.id })
        }
            ?? manualPlaylists.first
            ?? defaultPlaylist
            // A missing queue is repaired during foreground maintenance. Use
            // a detached fallback here so a Watch refresh remains read-only.
            ?? Playlist()

        let storedPlaylistID = Playlist.resolvePlaylistID(
            from: defaults.string(forKey: PlaylistPreferenceKeys.selectedPlaylistID)
        )
        let selectedPlaylist = storedPlaylistID.flatMap { selectedID in
            manualPlaylists.first(where: { $0.id == selectedID })
        } ?? fallbackPlaylist

        if defaults.string(forKey: PlaylistPreferenceKeys.selectedPlaylistID) != selectedPlaylist.id.uuidString {
            defaults.set(selectedPlaylist.id.uuidString, forKey: PlaylistPreferenceKeys.selectedPlaylistID)
        }

        return PlaylistSelection(
            selectedPlaylist: selectedPlaylist,
            manualPlaylists: manualPlaylists.isEmpty ? [selectedPlaylist] : manualPlaylists,
            defaultPlaylistID: defaultPlaylist?.id
        )
    }

    private func fetchVisibleManualPlaylists() -> [Playlist] {
        let manualKindRawValue = Playlist.Kind.manual.rawValue
        var descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { playlist in
                playlist.hidden == false
                    && playlist.kindRawValue == manualKindRawValue
            }
        )
        descriptor.fetchLimit = maximumVisibleWatchPlaylists
        let playlists = (try? modelContext.fetch(descriptor)) ?? []
        // This list is required for the Watch playlist picker. Unlike the old
        // unfiltered fetch, it neither evaluates hidden/smart playlists nor
        // accesses a playlist's entries.
        return Playlist.manualVisibleSorted(playlists)
    }

    private func makeSyncPlaylists(from selection: PlaylistSelection) -> [WatchSyncPlaylist] {
        selection.manualPlaylists.map { playlist in
            WatchSyncPlaylist(
                id: playlist.id.uuidString,
                title: playlist.displayTitle,
                symbolName: playlist.displaySymbolName,
                isSelected: playlist.id == selection.selectedPlaylist.id,
                isDefault: playlist.id == selection.defaultPlaylistID
            )
        }
    }

    private func fetchInboxEpisodes() -> [Episode] {
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.metaData?.isInbox == true
            },
            sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = maximumInboxSnapshotEpisodes

        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchStandardSettings() -> PodcastSettings {
        let defaultSettingsTitle = "de.holgerkrupp.podbay.queue"
        var descriptor = FetchDescriptor<PodcastSettings>(
            predicate: #Predicate { $0.title == defaultSettingsTitle }
        )
        descriptor.fetchLimit = 1

        if let settings = try? modelContext.fetch(descriptor).first {
            return settings
        }

        let settings = PodcastSettings(defaultSettings: true)
        modelContext.insert(settings)
        modelContext.saveIfNeeded()
        return settings
    }

    private func fetchEnabledPodcastSettingsByFeed(
        for episodes: [Episode]
    ) -> [URL: PodcastSettings] {
        let feeds = Set(episodes.compactMap { $0.podcast?.feed })
        return feeds.reduce(into: [:]) { result, feed in
            var descriptor = FetchDescriptor<PodcastSettings>(
                predicate: #Predicate<PodcastSettings> { setting in
                    setting.isEnabled == true && setting.podcast?.feed == feed
                }
            )
            descriptor.fetchLimit = 1
            if let setting = try? modelContext.fetch(descriptor).first {
                result[feed] = setting
            }
        }
    }

    private func makePlaybackSettings(
        from settings: PodcastSettings,
        isPodcastSpecific: Bool
    ) -> WatchPlaybackSettings {
        WatchPlaybackSettings(
            playbackSpeed: settings.playbackSpeed ?? 1.0,
            skipBackSeconds: settings.skipBack.rawValue,
            skipForwardSeconds: settings.skipForward.rawValue,
            continuousPlay: settings.getContinuousPlay,
            isPodcastSpecific: isPodcastSpecific
        )
    }

    private func makeSyncEpisode(
        from episode: Episode,
        globalSettings: PodcastSettings,
        enabledSettingsByFeed: [URL: PodcastSettings],
        includeChapters: Bool
    ) -> WatchSyncEpisode? {
        guard let episodeURL = episode.url?.absoluteString else { return nil }
        let podcastFeed = episode.podcast?.feed
        let podcastSettings = podcastFeed.flatMap { enabledSettingsByFeed[$0] }
        let playbackSettings = makePlaybackSettings(
            from: podcastSettings ?? globalSettings,
            isPodcastSpecific: podcastSettings != nil
        )
        let audioURL = episodeURL
        let imageURL = (episode.imageURL ?? episode.podcast?.imageURL)?.absoluteString

        return WatchSyncEpisode(
            episodeURL: episodeURL,
            audioURL: audioURL,
            podcastFeedURL: podcastFeed?.absoluteString,
            title: episode.title,
            subtitle: episode.subtitle ?? episode.desc,
            podcastTitle: episode.displayPodcastTitle,
            publishDate: episode.publishDate,
            duration: episode.duration,
            imageURL: imageURL,
            phoneHasLocalFile: episode.metaData?.calculatedIsAvailableLocally ?? false,
            fileSize: resolvedFileSize(for: episode),
            playPosition: episode.metaData?.playPosition,
            chapters: includeChapters ? makeSyncChapters(from: episode) : [],
            playbackSettings: playbackSettings
        )
    }

    private func makeSyncChapters(from episode: Episode) -> [WatchSyncChapter] {
        episode.preferredChapters.prefix(maximumSnapshotChaptersPerEpisode).map { chapter in
            WatchSyncChapter(
                id: WatchSyncChapterIdentity.syncID(for: chapter),
                title: watchChapterTitle(for: chapter),
                start: chapter.start ?? 0,
                duration: chapter.duration,
                imageURL: chapter.image?.absoluteString,
                shouldPlay: chapter.shouldPlay
            )
        }
    }

    private func watchChapterTitle(for chapter: Marker) -> String {
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled chapter" : title
    }

    private func makeTransferCandidate(from episode: Episode) -> WatchTransferCandidate? {
        guard episode.metaData?.calculatedIsAvailableLocally == true,
              let localFile = episode.localFile,
              FileManager.default.fileExists(atPath: localFile.path)
        else {
            return nil
        }

        let values = try? localFile.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values?.fileSize ?? 0)
        guard size > 0 else { return nil }

        return WatchTransferCandidate(fileURL: localFile, size: size)
    }

    private func resolvedFileSize(for episode: Episode) -> Int64? {
        if let localFile = episode.localFile,
           FileManager.default.fileExists(atPath: localFile.path),
           let values = try? localFile.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize {
            return Int64(fileSize)
        }

        return episode.fileSize
    }
}
#endif
