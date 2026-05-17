import CryptoKit
import Foundation
import WatchConnectivity
import WidgetKit
import SwiftUI

@MainActor
final class WatchSyncStore: NSObject, ObservableObject {
    private static let snapshotDefaultsKey = "watch.sync.snapshot"
    private static let downloadedFilesDefaultsKey = "watch.sync.downloadedFiles"
    private static let storageSettingsDefaultsKey = "watch.sync.storageSettings"

    @Published private(set) var snapshot: WatchSyncSnapshot
    @Published private(set) var downloadedFiles: [String: String]
    @Published private(set) var usedStorageBytes: Int64 = 0
    @Published private(set) var downloadingEpisodeIDs: Set<String> = []
    @Published private(set) var downloadProgressByEpisodeID: [String: Double] = [:]
    @Published var storageSettings: WatchStorageSettings
    @Published var isRefreshingInbox = false
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private var directDownloadSessions: [String: URLSession] = [:]
    private var directDownloadEpisodesByTask: [String: WatchSyncEpisode] = [:]
    private var automaticDirectDownloadEpisodeIDs: Set<String> = []
    private var lastStorageReportSignature: String?
    private var lastStorageReportSentAt: Date = .distantPast
    private var lastComplicationSignature: String?
    private var lastComplicationReloadAt: Date = .distantPast

    override init() {
        self.snapshot = Self.loadSnapshot(from: UserDefaults.standard, key: Self.snapshotDefaultsKey)
        self.downloadedFiles = Self.loadDownloadedFiles(from: UserDefaults.standard, key: Self.downloadedFilesDefaultsKey)
        self.storageSettings = Self.loadStorageSettings(from: UserDefaults.standard, key: Self.storageSettingsDefaultsKey)

        super.init()

        pruneMissingDownloads()
        recalculateStorageUsage()
        enforceStorageLimit()
        activateSession()
        updateComplicationSnapshot()
        if session?.activationState == .activated {
            sendStorageReport(force: true)
            requestSnapshot(silently: true)
        }
    }

    var playlist: [WatchSyncEpisode] {
        snapshot.playlist
    }

    var playlists: [WatchSyncPlaylist] {
        snapshot.playlists
    }

    var selectedPlaylistID: String? {
        snapshot.selectedPlaylistID
    }

    var selectedPlaylistTitle: String {
        snapshot.selectedPlaylistTitle
    }

    var inbox: [WatchSyncEpisode] {
        snapshot.inbox
    }

    var usedStorageDescription: String {
        Self.format(bytes: usedStorageBytes)
    }

    var storageLimitDescription: String {
        Self.format(bytes: storageSettings.maxStorageBytes)
    }

    func episode(withID episodeID: String) -> WatchSyncEpisode? {
        playlist.first(where: { $0.episodeURL == episodeID }) ?? inbox.first(where: { $0.episodeURL == episodeID })
    }

    func isDownloaded(_ episode: WatchSyncEpisode) -> Bool {
        guard let url = localFileURL(forEpisodeID: episode.episodeURL) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func isDownloading(_ episode: WatchSyncEpisode) -> Bool {
        downloadingEpisodeIDs.contains(episode.episodeURL)
            || snapshot.phoneTransferEpisodeIDs.contains(episode.episodeURL)
    }

    func syncProgress(for episode: WatchSyncEpisode) -> Double? {
        let phoneProgress = snapshot.phoneTransferProgressByEpisodeID[episode.episodeURL]
        let directProgress = downloadProgressByEpisodeID[episode.episodeURL]

        if let progress = [phoneProgress, directProgress].compactMap(\.self).max() {
            return min(max(progress, 0), 1)
        }

        if downloadingEpisodeIDs.contains(episode.episodeURL) {
            return 0
        }

        return nil
    }

    func playbackURL(for episode: WatchSyncEpisode) -> URL? {
        localFileURL(forEpisodeID: episode.episodeURL) ?? episode.resolvedAudioURL
    }

    func syncPlaybackProgress(for episodeID: String, position: Double) {
        guard position.isFinite else { return }
        updateEpisodePlaybackPosition(for: episodeID, position: position)
        send(
            command: WatchCommand(
                kind: .syncPlaybackProgress,
                episodeURL: episodeID,
                playPosition: position
            ),
            preferImmediateDelivery: true,
            showErrors: false
        )
    }

    func updateComplicationSnapshot(
        currentEpisodeID: String? = nil,
        playPosition: Double? = nil,
        isPlaying: Bool = false
    ) {
        let currentEpisode = resolvedComplicationEpisode(currentEpisodeID: currentEpisodeID)
        let currentIndex = currentEpisode.flatMap { episode in
            snapshot.playlist.firstIndex(where: { $0.episodeURL == episode.episodeURL })
        }
        let nextEpisode: WatchSyncEpisode?
        if let currentIndex {
            nextEpisode = snapshot.playlist.dropFirst(currentIndex + 1).first
        } else {
            nextEpisode = snapshot.playlist.first
        }

        let resolvedPlayPosition = playPosition ?? currentEpisode?.playPosition
        let activeTransferIDs = Set(snapshot.phoneTransferEpisodeIDs).union(downloadingEpisodeIDs)
        let transferProgressValues = activeTransferIDs.compactMap { episodeID in
            [
                snapshot.phoneTransferProgressByEpisodeID[episodeID],
                downloadProgressByEpisodeID[episodeID]
            ].compactMap(\.self).max()
        }
        let highestTransferProgress = transferProgressValues.max()
        let complicationSnapshot = WatchComplicationSnapshot(
            generatedAt: .now,
            selectedPlaylistTitle: self.snapshot.selectedPlaylistTitle,
            currentEpisodeID: currentEpisode?.episodeURL,
            currentTitle: currentEpisode?.title,
            currentPodcast: currentEpisode?.podcastTitle,
            currentChapterTitle: currentEpisode?.chapter(at: resolvedPlayPosition)?.title,
            duration: currentEpisode?.duration,
            playPosition: resolvedPlayPosition,
            isPlaying: isPlaying,
            playlistTotalCount: self.snapshot.playlist.count,
            currentIndex: currentIndex,
            nextTitle: nextEpisode?.title,
            nextPodcast: nextEpisode?.podcastTitle,
            inboxCount: self.snapshot.inbox.count,
            downloadedCount: downloadedFiles.count,
            activeTransferCount: activeTransferIDs.count,
            highestTransferProgress: highestTransferProgress
        )

        WatchComplicationStore.save(complicationSnapshot)
        reloadComplicationsIfNeeded(for: complicationSnapshot)
    }

    func setChapterShouldPlay(_ shouldPlay: Bool, chapterID: String, episodeID: String) {
        updateChapterShouldPlay(shouldPlay, chapterID: chapterID, episodeID: episodeID)
        send(
            command: WatchCommand(
                kind: .setChapterShouldPlay,
                episodeURL: episodeID,
                chapterID: chapterID,
                shouldPlay: shouldPlay
            ),
            preferImmediateDelivery: true
        )
    }

    func setPlaybackSettings(_ playbackSettings: WatchPlaybackSettings, for episode: WatchSyncEpisode?) {
        updatePlaybackSettings(playbackSettings, for: episode)
        send(
            command: WatchCommand(
                kind: .setPlaybackSettings,
                episodeURL: episode?.episodeURL,
                podcastFeedURL: episode?.playbackSettings?.isPodcastSpecific == true ? episode?.podcastFeedURL : nil,
                playbackSettings: playbackSettings
            ),
            preferImmediateDelivery: true
        )
    }

    func requestSnapshot(silently: Bool = false) {
        send(command: WatchCommand(kind: .requestSnapshot), showErrors: silently == false)
    }

    func refreshInbox() {
        isRefreshingInbox = true
        send(command: WatchCommand(kind: .refreshInbox), preferImmediateDelivery: true)
    }

    func selectPlaylist(_ playlist: WatchSyncPlaylist) {
        optimisticallySelectPlaylist(playlist)
        send(
            command: WatchCommand(
                kind: .selectPlaylist,
                playlistID: playlist.id
            ),
            preferImmediateDelivery: true
        )
    }

    func queueEpisode(_ episode: WatchSyncEpisode, downloadAfterQueue: Bool) {
        optimisticallyQueueEpisode(episode)
        send(command: WatchCommand(
            kind: .queueEpisodeAtFront,
            episodeURL: episode.episodeURL,
            playlistID: selectedPlaylistID,
            position: .front
        ))

        if downloadAfterQueue {
            downloadEpisode(episode)
        }
    }

    func downloadEpisode(_ episode: WatchSyncEpisode) {
        guard !downloadingEpisodeIDs.contains(episode.episodeURL) else { return }
        guard let remoteURL = episode.resolvedAudioURL else {
            errorMessage = "This episode does not expose a download URL yet."
            return
        }

        if let fileSize = episode.fileSize,
           fileSize > storageSettings.maxStorageBytes {
            errorMessage = "This episode is larger than the watch storage limit."
            return
        }

        downloadingEpisodeIDs.insert(episode.episodeURL)
        downloadProgressByEpisodeID[episode.episodeURL] = 0

        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = storageSettings.allowCellularDownloads
        configuration.waitsForConnectivity = true

        let downloadSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = downloadSession.downloadTask(with: remoteURL)
        let key = Self.directDownloadKey(for: downloadSession, task: task)
        directDownloadSessions[key] = downloadSession
        directDownloadEpisodesByTask[key] = episode
        task.resume()
    }

    func removeDownload(_ episode: WatchSyncEpisode) {
        guard let url = localFileURL(forEpisodeID: episode.episodeURL) else { return }

        try? fileManager.removeItem(at: url)
        downloadedFiles.removeValue(forKey: episode.episodeURL)
        persistDownloadedFiles()
        recalculateStorageUsage()
        sendStorageReport(force: true)
    }

    func setMaxStorageBytes(_ maxStorageBytes: Int64) {
        storageSettings.maxStorageBytes = maxStorageBytes
        persistStorageSettings()
        enforceStorageLimit()
        sendStorageReport(force: true)
        requestSnapshot(silently: true)
    }

    func setAllowCellularDownloads(_ allowCellularDownloads: Bool) {
        storageSettings.allowCellularDownloads = allowCellularDownloads
        persistStorageSettings()
        sendStorageReport(force: true)
    }

    private func activateSession() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    private func send(
        command: WatchCommand,
        preferImmediateDelivery: Bool = false,
        showErrors: Bool = true
    ) {
        guard let session else {
            if showErrors {
                errorMessage = "Watch sync is not available on this device."
            }
            return
        }

        guard let data = WatchSyncTransport.encode(command) else { return }
        let payload = [WatchSyncTransport.commandMessageKey: data]

        if preferImmediateDelivery && session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { [weak self] error in
                Task { @MainActor in
                    if showErrors {
                        self?.errorMessage = error.localizedDescription
                    }
                }
            }
            return
        }

        guard session.activationState == .activated else {
            if showErrors {
                errorMessage = "Open the iPhone app once so the watch can finish pairing."
            }
            return
        }

        session.transferUserInfo(payload)
    }

    private func sendStorageReport(force: Bool = false) {
        guard let session,
              session.activationState == .activated
        else {
            return
        }

        let report = storageReport()
        let signature = storageReportSignature(report)
        let now = Date()
        guard force
                || signature != lastStorageReportSignature
                || now.timeIntervalSince(lastStorageReportSentAt) > 30
        else {
            return
        }

        guard let data = WatchSyncTransport.encode(report) else { return }
        let payload = [WatchSyncTransport.storageContextKey: data]
        var deliveredImmediately = false

        do {
            try session.updateApplicationContext(payload)
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil) { error in
                    #if DEBUG
                    print("Watch sync immediate storage report failed: \(error)")
                    #endif
                }
                deliveredImmediately = true
            }
        } catch {
            #if DEBUG
            print("Failed to send storage report: \(error)")
            #endif
        }

        session.transferUserInfo(payload)
        lastStorageReportSignature = signature
        lastStorageReportSentAt = now
        #if DEBUG
        let route = deliveredImmediately ? "context/message/userInfo" : "context/userInfo"
        print("Watch sync sent storage report via \(route): used=\(usedStorageBytes), max=\(storageSettings.maxStorageBytes), downloads=\(downloadedFiles.count)")
        #endif
    }

    private func storageReport() -> WatchStorageReport {
        WatchStorageReport(
            generatedAt: .now,
            usedBytes: usedStorageBytes,
            maxStorageBytes: storageSettings.maxStorageBytes,
            allowCellularDownloads: storageSettings.allowCellularDownloads,
            downloadedEpisodeIDs: Array(downloadedFiles.keys)
        )
    }

    private func storageReportSignature(_ report: WatchStorageReport) -> String {
        [
            "\(report.usedBytes)",
            "\(report.maxStorageBytes)",
            "\(report.allowCellularDownloads)",
            report.downloadedEpisodeIDs.sorted().joined(separator: ",")
        ].joined(separator: "|")
    }

    private func apply(snapshot newSnapshot: WatchSyncSnapshot) {
        snapshot = newSnapshot
        isRefreshingInbox = false
        persistSnapshot()
        enforceStorageLimit()
        sendStorageReport(force: true)
        startDirectDownloadsForPendingPhoneTransfers()
        updateComplicationSnapshot()
    }

    private func startDirectDownloadsForPendingPhoneTransfers() {
        for episodeID in snapshot.phoneTransferEpisodeIDs {
            guard let episode = episode(withID: episodeID),
                  episode.resolvedAudioURL != nil,
                  isDownloaded(episode) == false,
                  downloadingEpisodeIDs.contains(episodeID) == false
            else {
                continue
            }

            #if DEBUG
            print("Watch sync starting direct URL download for \(episodeID)")
            #endif
            automaticDirectDownloadEpisodeIDs.insert(episodeID)
            downloadEpisode(episode)
        }
    }

    private func updateEpisodePlaybackPosition(for episodeID: String, position: Double) {
        let playlist = snapshot.playlist.map { episode in
            updatedEpisode(episode, matching: episodeID, playPosition: position)
        }
        let inbox = snapshot.inbox.map { episode in
            updatedEpisode(episode, matching: episodeID, playPosition: position)
        }

        snapshot = WatchSyncSnapshot(
            generatedAt: snapshot.generatedAt,
            playlist: playlist,
            inbox: inbox,
            playlists: snapshot.playlists,
            selectedPlaylistID: snapshot.selectedPlaylistID,
            selectedPlaylistTitle: snapshot.selectedPlaylistTitle,
            skipBackSeconds: snapshot.skipBackSeconds,
            skipForwardSeconds: snapshot.skipForwardSeconds,
            playbackSettings: snapshot.playbackSettings,
            phoneTransferEpisodeIDs: snapshot.phoneTransferEpisodeIDs,
            phoneTransferProgressByEpisodeID: snapshot.phoneTransferProgressByEpisodeID
        )
        persistSnapshot()
        updateComplicationSnapshot(currentEpisodeID: episodeID, playPosition: position)
    }

    private func updateChapterShouldPlay(_ shouldPlay: Bool, chapterID: String, episodeID: String) {
        let playlist = snapshot.playlist.map { episode in
            updatedEpisode(episode, matching: episodeID, chapterID: chapterID, shouldPlay: shouldPlay)
        }
        let inbox = snapshot.inbox.map { episode in
            updatedEpisode(episode, matching: episodeID, chapterID: chapterID, shouldPlay: shouldPlay)
        }

        snapshot = WatchSyncSnapshot(
            generatedAt: snapshot.generatedAt,
            playlist: playlist,
            inbox: inbox,
            playlists: snapshot.playlists,
            selectedPlaylistID: snapshot.selectedPlaylistID,
            selectedPlaylistTitle: snapshot.selectedPlaylistTitle,
            skipBackSeconds: snapshot.skipBackSeconds,
            skipForwardSeconds: snapshot.skipForwardSeconds,
            playbackSettings: snapshot.playbackSettings,
            phoneTransferEpisodeIDs: snapshot.phoneTransferEpisodeIDs,
            phoneTransferProgressByEpisodeID: snapshot.phoneTransferProgressByEpisodeID
        )
        persistSnapshot()
        updateComplicationSnapshot()
    }

    private func updatePlaybackSettings(_ playbackSettings: WatchPlaybackSettings, for episode: WatchSyncEpisode?) {
        let scopedSettings = WatchPlaybackSettings(
            playbackSpeed: playbackSettings.playbackSpeed,
            skipBackSeconds: playbackSettings.skipBackSeconds,
            skipForwardSeconds: playbackSettings.skipForwardSeconds,
            continuousPlay: playbackSettings.continuousPlay,
            isPodcastSpecific: episode?.playbackSettings?.isPodcastSpecific == true
        )

        let updatedGlobalSettings = scopedSettings.isPodcastSpecific ? snapshot.playbackSettings : scopedSettings
        let playlist = snapshot.playlist.map { candidate in
            updatedEpisode(candidate, matchingPlaybackSettingsScopeOf: episode, playbackSettings: scopedSettings)
        }
        let inbox = snapshot.inbox.map { candidate in
            updatedEpisode(candidate, matchingPlaybackSettingsScopeOf: episode, playbackSettings: scopedSettings)
        }

        snapshot = WatchSyncSnapshot(
            generatedAt: snapshot.generatedAt,
            playlist: playlist,
            inbox: inbox,
            playlists: snapshot.playlists,
            selectedPlaylistID: snapshot.selectedPlaylistID,
            selectedPlaylistTitle: snapshot.selectedPlaylistTitle,
            skipBackSeconds: updatedGlobalSettings.skipBackSeconds,
            skipForwardSeconds: updatedGlobalSettings.skipForwardSeconds,
            playbackSettings: updatedGlobalSettings,
            phoneTransferEpisodeIDs: snapshot.phoneTransferEpisodeIDs,
            phoneTransferProgressByEpisodeID: snapshot.phoneTransferProgressByEpisodeID
        )
        persistSnapshot()
        updateComplicationSnapshot()
    }

    private func updatedEpisode(
        _ episode: WatchSyncEpisode,
        matching episodeID: String,
        playPosition: Double
    ) -> WatchSyncEpisode {
        guard episode.episodeURL == episodeID else { return episode }

        let clampedPosition: Double
        if let duration = episode.duration, duration > 0 {
            clampedPosition = min(max(playPosition, 0), duration)
        } else {
            clampedPosition = max(playPosition, 0)
        }

        return WatchSyncEpisode(
            episodeURL: episode.episodeURL,
            audioURL: episode.audioURL,
            podcastFeedURL: episode.podcastFeedURL,
            title: episode.title,
            subtitle: episode.subtitle,
            podcastTitle: episode.podcastTitle,
            publishDate: episode.publishDate,
            duration: episode.duration,
            imageURL: episode.imageURL,
            phoneHasLocalFile: episode.phoneHasLocalFile,
            fileSize: episode.fileSize,
            playPosition: clampedPosition,
            chapters: episode.chapters,
            playbackSettings: episode.playbackSettings
        )
    }

    private func updatedEpisode(
        _ episode: WatchSyncEpisode,
        matching episodeID: String,
        chapterID: String,
        shouldPlay: Bool
    ) -> WatchSyncEpisode {
        guard episode.episodeURL == episodeID else { return episode }

        let chapters = episode.chapters.map { chapter in
            guard chapter.id == chapterID else { return chapter }
            return WatchSyncChapter(
                id: chapter.id,
                title: chapter.title,
                start: chapter.start,
                duration: chapter.duration,
                imageURL: chapter.imageURL,
                shouldPlay: shouldPlay
            )
        }

        return WatchSyncEpisode(
            episodeURL: episode.episodeURL,
            audioURL: episode.audioURL,
            podcastFeedURL: episode.podcastFeedURL,
            title: episode.title,
            subtitle: episode.subtitle,
            podcastTitle: episode.podcastTitle,
            publishDate: episode.publishDate,
            duration: episode.duration,
            imageURL: episode.imageURL,
            phoneHasLocalFile: episode.phoneHasLocalFile,
            fileSize: episode.fileSize,
            playPosition: episode.playPosition,
            chapters: chapters,
            playbackSettings: episode.playbackSettings
        )
    }

    private func updatedEpisode(
        _ episode: WatchSyncEpisode,
        matchingPlaybackSettingsScopeOf sourceEpisode: WatchSyncEpisode?,
        playbackSettings: WatchPlaybackSettings
    ) -> WatchSyncEpisode {
        let shouldUpdate: Bool
        if playbackSettings.isPodcastSpecific,
           let podcastFeedURL = sourceEpisode?.podcastFeedURL {
            shouldUpdate = episode.podcastFeedURL == podcastFeedURL
        } else {
            shouldUpdate = episode.playbackSettings?.isPodcastSpecific != true
        }
        guard shouldUpdate else { return episode }

        return WatchSyncEpisode(
            episodeURL: episode.episodeURL,
            audioURL: episode.audioURL,
            podcastFeedURL: episode.podcastFeedURL,
            title: episode.title,
            subtitle: episode.subtitle,
            podcastTitle: episode.podcastTitle,
            publishDate: episode.publishDate,
            duration: episode.duration,
            imageURL: episode.imageURL,
            phoneHasLocalFile: episode.phoneHasLocalFile,
            fileSize: episode.fileSize,
            playPosition: episode.playPosition,
            chapters: episode.chapters,
            playbackSettings: playbackSettings
        )
    }

    private func optimisticallyQueueEpisode(_ episode: WatchSyncEpisode) {
        let updatedPlaylist = [episode] + snapshot.playlist.filter { $0.episodeURL != episode.episodeURL }
        let updatedInbox = snapshot.inbox.filter { $0.episodeURL != episode.episodeURL }
        snapshot = WatchSyncSnapshot(
            generatedAt: .now,
            playlist: updatedPlaylist,
            inbox: updatedInbox,
            playlists: snapshot.playlists,
            selectedPlaylistID: snapshot.selectedPlaylistID,
            selectedPlaylistTitle: snapshot.selectedPlaylistTitle,
            skipBackSeconds: snapshot.skipBackSeconds,
            skipForwardSeconds: snapshot.skipForwardSeconds,
            playbackSettings: snapshot.playbackSettings,
            phoneTransferEpisodeIDs: snapshot.phoneTransferEpisodeIDs,
            phoneTransferProgressByEpisodeID: snapshot.phoneTransferProgressByEpisodeID
        )
        persistSnapshot()
        updateComplicationSnapshot()
    }

    private func optimisticallySelectPlaylist(_ playlist: WatchSyncPlaylist) {
        let updatedPlaylists = snapshot.playlists.map { candidate in
            WatchSyncPlaylist(
                id: candidate.id,
                title: candidate.title,
                symbolName: candidate.symbolName,
                isSelected: candidate.id == playlist.id,
                isDefault: candidate.isDefault
            )
        }

        snapshot = WatchSyncSnapshot(
            generatedAt: .now,
            playlist: snapshot.playlist,
            inbox: snapshot.inbox,
            playlists: updatedPlaylists,
            selectedPlaylistID: playlist.id,
            selectedPlaylistTitle: playlist.title,
            skipBackSeconds: snapshot.skipBackSeconds,
            skipForwardSeconds: snapshot.skipForwardSeconds,
            playbackSettings: snapshot.playbackSettings,
            phoneTransferEpisodeIDs: snapshot.phoneTransferEpisodeIDs,
            phoneTransferProgressByEpisodeID: snapshot.phoneTransferProgressByEpisodeID
        )
        persistSnapshot()
        updateComplicationSnapshot()
    }

    private func finishDownload(from temporaryURL: URL, for episode: WatchSyncEpisode, prioritizing prioritizedEpisodeID: String?) {
        defer {
            downloadingEpisodeIDs.remove(episode.episodeURL)
        }

        let destinationURL = destinationURL(forEpisodeID: episode.episodeURL, sourceURL: episode.resolvedAudioURL ?? temporaryURL)

        do {
            try fileManager.createDirectory(
                at: downloadsDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            if let existingURL = localFileURL(forEpisodeID: episode.episodeURL) {
                try? fileManager.removeItem(at: existingURL)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            downloadedFiles[episode.episodeURL] = destinationURL.lastPathComponent
            persistDownloadedFiles()
            recalculateStorageUsage()
            updateComplicationSnapshot(currentEpisodeID: episode.episodeURL)

            if enforceStorageLimit(prioritizing: prioritizedEpisodeID) == false {
                errorMessage = "The watch storage limit is full. Remove a download or raise the limit first."
            }

            sendStorageReport()
            #if DEBUG
            print("Watch sync stored episode \(episode.episodeURL) at \(destinationURL.lastPathComponent)")
            #endif
        } catch {
            errorMessage = error.localizedDescription
            #if DEBUG
            print("Watch sync failed to store episode \(episode.episodeURL): \(error)")
            #endif
        }
    }

    @discardableResult
    private func enforceStorageLimit(prioritizing prioritizedEpisodeID: String? = nil) -> Bool {
        pruneMissingDownloads()

        let playlistIDs = snapshot.playlist.map(\.id)
        let playlistIDSet = Set(playlistIDs)

        var preferredOrder: [String] = []
        if let prioritizedEpisodeID,
           downloadedFiles[prioritizedEpisodeID] != nil {
            preferredOrder.append(prioritizedEpisodeID)
        }

        preferredOrder.append(contentsOf: playlistIDs.filter {
            $0 != prioritizedEpisodeID && downloadedFiles[$0] != nil
        })

        var keptEpisodeIDs: Set<String> = []
        var runningTotal: Int64 = 0

        for episodeID in preferredOrder {
            guard let size = currentFileSize(forEpisodeID: episodeID) else { continue }
            if runningTotal + size <= storageSettings.maxStorageBytes {
                keptEpisodeIDs.insert(episodeID)
                runningTotal += size
            }
        }

        // Any file that is no longer in the selected playlist should be removed from the watch.
        for episodeID in Array(downloadedFiles.keys) {
            if playlistIDSet.contains(episodeID) == false {
                removeDownloadedFile(forEpisodeID: episodeID)
            }
        }

        for episodeID in Array(downloadedFiles.keys) where keptEpisodeIDs.contains(episodeID) == false {
            removeDownloadedFile(forEpisodeID: episodeID)
        }

        persistDownloadedFiles()
        recalculateStorageUsage()
        updateComplicationSnapshot()

        if let prioritizedEpisodeID {
            return keptEpisodeIDs.contains(prioritizedEpisodeID)
        }

        return true
    }

    private func removeDownloadedFile(forEpisodeID episodeID: String) {
        if let url = localFileURL(forEpisodeID: episodeID) {
            try? fileManager.removeItem(at: url)
        }
        downloadedFiles.removeValue(forKey: episodeID)
    }

    private func pruneMissingDownloads() {
        downloadedFiles = downloadedFiles.filter { _, fileName in
            let url = downloadsDirectory.appendingPathComponent(fileName)
            return fileManager.fileExists(atPath: url.path)
        }
        persistDownloadedFiles()
    }

    private func recalculateStorageUsage() {
        usedStorageBytes = downloadedFiles.keys.reduce(into: 0) { partialResult, episodeID in
            partialResult += currentFileSize(forEpisodeID: episodeID) ?? 0
        }
    }

    private func currentFileSize(forEpisodeID episodeID: String) -> Int64? {
        guard let url = localFileURL(forEpisodeID: episodeID),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize
        else {
            return nil
        }

        return Int64(fileSize)
    }

    private func localFileURL(forEpisodeID episodeID: String) -> URL? {
        guard let fileName = downloadedFiles[episodeID] else { return nil }
        return downloadsDirectory.appendingPathComponent(fileName)
    }

    private func destinationURL(forEpisodeID episodeID: String, sourceURL: URL) -> URL {
        let pathExtension = sourceURL.pathExtension
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let digest = SHA256.hash(data: Data(episodeID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return downloadsDirectory.appendingPathComponent("episode-\(digest)\(suffix)")
    }

    private var downloadsDirectory: URL {
        let baseDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return baseDirectory.appendingPathComponent("WatchDownloads", isDirectory: true)
    }

    private func persistSnapshot() {
        defaults.set(WatchSyncTransport.encode(snapshot), forKey: Self.snapshotDefaultsKey)
    }

    private func persistDownloadedFiles() {
        defaults.set(downloadedFiles, forKey: Self.downloadedFilesDefaultsKey)
    }

    private func resolvedComplicationEpisode(currentEpisodeID: String?) -> WatchSyncEpisode? {
        if let currentEpisodeID {
            return episode(withID: currentEpisodeID)
        }

        return snapshot.playlist.first(where: { ($0.playPosition ?? 0) > 0 }) ?? snapshot.playlist.first
    }

    private func reloadComplicationsIfNeeded(for snapshot: WatchComplicationSnapshot) {
        let progressBucket = Int(((snapshot.playPosition ?? 0) / 30).rounded(.down))
        let transferBucket = Int(((snapshot.highestTransferProgress ?? 0) * 20).rounded(.down))
        let signature = [
            snapshot.currentEpisodeID ?? "",
            "\(snapshot.isPlaying)",
            "\(progressBucket)",
            "\(snapshot.playlistTotalCount)",
            "\(snapshot.currentIndex ?? -1)",
            "\(snapshot.inboxCount)",
            "\(snapshot.downloadedCount)",
            "\(snapshot.activeTransferCount)",
            "\(transferBucket)"
        ].joined(separator: "|")

        guard signature != lastComplicationSignature
                || Date.now.timeIntervalSince(lastComplicationReloadAt) > 60
        else {
            return
        }

        lastComplicationSignature = signature
        lastComplicationReloadAt = .now
        WidgetCenter.shared.reloadTimelines(ofKind: "WatchEpisodeProgressComplication")
        WidgetCenter.shared.reloadTimelines(ofKind: "WatchPlaylistRemainingComplication")
        WidgetCenter.shared.reloadTimelines(ofKind: "WatchSyncStatusComplication")
        WidgetCenter.shared.reloadTimelines(ofKind: "WatchAppLauncherComplication")
    }

    private func persistStorageSettings() {
        defaults.set(WatchSyncTransport.encode(storageSettings), forKey: Self.storageSettingsDefaultsKey)
    }

    private static func loadSnapshot(from defaults: UserDefaults, key: String) -> WatchSyncSnapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = WatchSyncTransport.decode(WatchSyncSnapshot.self, from: data) else {
            return .empty
        }

        return snapshot
    }

    private static func loadDownloadedFiles(from defaults: UserDefaults, key: String) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private static func loadStorageSettings(from defaults: UserDefaults, key: String) -> WatchStorageSettings {
        guard let data = defaults.data(forKey: key),
              let settings = WatchSyncTransport.decode(WatchStorageSettings.self, from: data) else {
            return WatchStorageSettings()
        }

        return settings
    }

    nonisolated private static func directDownloadKey(for session: URLSession, task: URLSessionTask) -> String {
        "\(ObjectIdentifier(session).hashValue)-\(task.taskIdentifier)"
    }

    private func handleDirectDownloadProgress(key: String, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let episode = directDownloadEpisodesByTask[key],
              totalBytesExpectedToWrite > 0
        else {
            return
        }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        downloadProgressByEpisodeID[episode.episodeURL] = min(max(progress, 0), 1)
    }

    private func handleDirectDownloadFinished(key: String, temporaryURL: URL) {
        guard let episode = directDownloadEpisodesByTask[key] else {
            try? fileManager.removeItem(at: temporaryURL)
            return
        }

        directDownloadSessions.removeValue(forKey: key)?.finishTasksAndInvalidate()
        directDownloadEpisodesByTask.removeValue(forKey: key)
        automaticDirectDownloadEpisodeIDs.remove(episode.episodeURL)
        downloadProgressByEpisodeID[episode.episodeURL] = 1
        finishDownload(from: temporaryURL, for: episode, prioritizing: episode.episodeURL)
        downloadProgressByEpisodeID.removeValue(forKey: episode.episodeURL)
    }

    private func handleDirectDownloadCompleted(key: String, error: Error?) {
        guard let error,
              let episode = directDownloadEpisodesByTask[key]
        else {
            return
        }

        directDownloadSessions.removeValue(forKey: key)?.finishTasksAndInvalidate()
        directDownloadEpisodesByTask.removeValue(forKey: key)
        downloadingEpisodeIDs.remove(episode.episodeURL)
        downloadProgressByEpisodeID.removeValue(forKey: episode.episodeURL)
        let wasAutomaticFallback = automaticDirectDownloadEpisodeIDs.remove(episode.episodeURL) != nil
        if wasAutomaticFallback == false {
            errorMessage = error.localizedDescription
        }
        #if DEBUG
        print("Watch sync direct URL download failed for \(episode.episodeURL): \(error)")
        #endif
    }

    private static func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension WatchSyncStore: WCSessionDelegate {
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {}
    #endif

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            guard error == nil, activationState == .activated else { return }
            sendStorageReport(force: true)
            requestSnapshot()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            if isReachable {
                sendStorageReport(force: true)
                requestSnapshot()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        guard let data = applicationContext[WatchSyncTransport.snapshotContextKey] as? Data,
              let snapshot = WatchSyncTransport.decode(WatchSyncSnapshot.self, from: data)
        else {
            return
        }

        Task { @MainActor in
            apply(snapshot: snapshot)
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let temporaryCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(file.fileURL.pathExtension)

        do {
            try FileManager.default.copyItem(at: file.fileURL, to: temporaryCopy)
        } catch {
            #if DEBUG
            print("Watch sync failed to copy received file transfer: \(error)")
            #endif
            return
        }

        let metadata = file.metadata ?? [:]
        let episodeID = metadata[WatchSyncTransport.transferEpisodeIDKey] as? String
        let episodeURLString = metadata[WatchSyncTransport.transferEpisodeURLKey] as? String

        #if DEBUG
        print("Watch sync received file transfer for \(episodeID ?? "missing episode id")")
        #endif

        Task { @MainActor in
            guard let episodeID else {
                try? FileManager.default.removeItem(at: temporaryCopy)
                #if DEBUG
                print("Watch sync discarded file transfer without episode id")
                #endif
                return
            }

            finishDownload(
                from: temporaryCopy,
                for: WatchSyncEpisode(
                    episodeURL: episodeURLString ?? episodeID,
                    audioURL: episodeURLString ?? episodeID,
                    title: "",
                    subtitle: nil,
                    podcastTitle: nil,
                    publishDate: nil,
                    duration: nil,
                    imageURL: nil,
                    phoneHasLocalFile: true,
                    fileSize: nil
                ),
                prioritizing: nil
            )
        }
    }
}

extension WatchSyncStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let key = Self.directDownloadKey(for: session, task: downloadTask)
        Task { @MainActor in
            handleDirectDownloadProgress(
                key: key,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let key = Self.directDownloadKey(for: session, task: downloadTask)
        let temporaryCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(location.pathExtension)

        do {
            try FileManager.default.copyItem(at: location, to: temporaryCopy)
        } catch {
            #if DEBUG
            print("Watch sync failed to copy direct URL download: \(error)")
            #endif
            return
        }

        Task { @MainActor in
            handleDirectDownloadFinished(key: key, temporaryURL: temporaryCopy)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let key = Self.directDownloadKey(for: session, task: task)
        Task { @MainActor in
            handleDirectDownloadCompleted(key: key, error: error)
        }
    }
}
