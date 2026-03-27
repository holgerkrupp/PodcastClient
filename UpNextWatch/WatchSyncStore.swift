import Foundation
import WatchConnectivity
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
    @Published var storageSettings: WatchStorageSettings
    @Published var isRefreshingInbox = false
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil

    override init() {
        self.snapshot = Self.loadSnapshot(from: UserDefaults.standard, key: Self.snapshotDefaultsKey)
        self.downloadedFiles = Self.loadDownloadedFiles(from: UserDefaults.standard, key: Self.downloadedFilesDefaultsKey)
        self.storageSettings = Self.loadStorageSettings(from: UserDefaults.standard, key: Self.storageSettingsDefaultsKey)

        super.init()

        pruneMissingDownloads()
        recalculateStorageUsage()
        enforceStorageLimit()
        activateSession()
        if session?.activationState == .activated {
            sendStorageReport()
            requestSnapshot(silently: true)
        }
    }

    var playlist: [WatchSyncEpisode] {
        snapshot.playlist
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

    func requestSnapshot(silently: Bool = false) {
        send(command: WatchCommand(kind: .requestSnapshot), showErrors: silently == false)
    }

    func refreshInbox() {
        isRefreshingInbox = true
        send(command: WatchCommand(kind: .refreshInbox), preferImmediateDelivery: true)
    }

    func queueEpisode(_ episode: WatchSyncEpisode, downloadAfterQueue: Bool) {
        optimisticallyQueueEpisode(episode)
        send(command: WatchCommand(
            kind: .queueEpisodeAtFront,
            episodeURL: episode.episodeURL
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
        let allowCellularDownloads = storageSettings.allowCellularDownloads

        Task {
            do {
                let configuration = URLSessionConfiguration.default
                configuration.allowsCellularAccess = allowCellularDownloads
                configuration.waitsForConnectivity = true

                let session = URLSession(configuration: configuration)
                let (temporaryURL, _) = try await session.download(from: remoteURL)

                await MainActor.run {
                    finishDownload(from: temporaryURL, for: episode, prioritizing: episode.episodeURL)
                }
            } catch {
                await MainActor.run {
                    downloadingEpisodeIDs.remove(episode.episodeURL)
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func removeDownload(_ episode: WatchSyncEpisode) {
        guard let url = localFileURL(forEpisodeID: episode.episodeURL) else { return }

        try? fileManager.removeItem(at: url)
        downloadedFiles.removeValue(forKey: episode.episodeURL)
        persistDownloadedFiles()
        recalculateStorageUsage()
        sendStorageReport()
    }

    func setMaxStorageBytes(_ maxStorageBytes: Int64) {
        storageSettings.maxStorageBytes = maxStorageBytes
        persistStorageSettings()
        enforceStorageLimit()
        sendStorageReport()
        requestSnapshot(silently: true)
    }

    func setAllowCellularDownloads(_ allowCellularDownloads: Bool) {
        storageSettings.allowCellularDownloads = allowCellularDownloads
        persistStorageSettings()
        sendStorageReport()
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

    private func sendStorageReport() {
        guard let session,
              session.activationState == .activated,
              let data = WatchSyncTransport.encode(storageReport())
        else {
            return
        }

        do {
            try session.updateApplicationContext([
                WatchSyncTransport.storageContextKey: data
            ])
        } catch {
            #if DEBUG
            print("Failed to send storage report: \(error)")
            #endif
        }
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

    private func apply(snapshot newSnapshot: WatchSyncSnapshot) {
        snapshot = newSnapshot
        isRefreshingInbox = false
        persistSnapshot()
        enforceStorageLimit()
        sendStorageReport()
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
            inbox: inbox
        )
        persistSnapshot()
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
            title: episode.title,
            subtitle: episode.subtitle,
            podcastTitle: episode.podcastTitle,
            publishDate: episode.publishDate,
            duration: episode.duration,
            imageURL: episode.imageURL,
            phoneHasLocalFile: episode.phoneHasLocalFile,
            fileSize: episode.fileSize,
            playPosition: clampedPosition,
            chapters: episode.chapters
        )
    }

    private func optimisticallyQueueEpisode(_ episode: WatchSyncEpisode) {
        let updatedPlaylist = [episode] + snapshot.playlist.filter { $0.episodeURL != episode.episodeURL }
        let updatedInbox = snapshot.inbox.filter { $0.episodeURL != episode.episodeURL }
        snapshot = WatchSyncSnapshot(
            generatedAt: .now,
            playlist: updatedPlaylist,
            inbox: updatedInbox
        )
        persistSnapshot()
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

            if enforceStorageLimit(prioritizing: prioritizedEpisodeID) == false {
                errorMessage = "The watch storage limit is full. Remove a download or raise the limit first."
            }

            sendStorageReport()
        } catch {
            errorMessage = error.localizedDescription
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

        // Any file that is no longer in Up Next should be removed from the watch.
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
        return downloadsDirectory.appendingPathComponent("episode-\(episodeID)\(suffix)")
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
            sendStorageReport()
            requestSnapshot()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            if isReachable {
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
            return
        }

        let metadata = file.metadata ?? [:]
        let episodeID = metadata[WatchSyncTransport.transferEpisodeIDKey] as? String
        let episodeURLString = metadata[WatchSyncTransport.transferEpisodeURLKey] as? String

        Task { @MainActor in
            guard let episodeID else {
                try? FileManager.default.removeItem(at: temporaryCopy)
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
