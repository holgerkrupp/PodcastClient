import Foundation
import SwiftData
import WatchConnectivity

@MainActor
final class PhoneWatchSyncController: NSObject {
    static let shared = PhoneWatchSyncController()

    private struct TransferCandidate {
        let fileURL: URL
        let size: Int64
    }

    private struct SnapshotBundle {
        let snapshot: WatchSyncSnapshot
        let transferCandidates: [String: TransferCandidate]
    }

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil

    private var lastStorageReport: WatchStorageReport?
    private var pendingTransferEpisodeIDs: Set<String> = []

    private override init() {
        super.init()
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func refreshSnapshotAndTransfers() async {
        guard let session else { return }
        guard session.isPaired, session.isWatchAppInstalled else { return }

        let bundle = makeSnapshotBundle()
        pushSnapshot(bundle.snapshot, via: session)
        syncPlaylistFilesIfPossible(bundle, via: session)
    }

    private func makeSnapshotBundle() -> SnapshotBundle {
        let container = ModelContainerManager.shared.container
        let context = ModelContext(container)

        let playlistEntries = fetchPlaylistEntries(with: context)
        let inboxEpisodes = fetchInboxEpisodes(with: context)

        var transferCandidates: [String: TransferCandidate] = [:]
        let playlist = playlistEntries.compactMap { entry -> WatchSyncEpisode? in
            guard let episode = entry.episode else { return nil }
            guard let syncEpisode = makeSyncEpisode(from: episode) else { return nil }
            if let candidate = makeTransferCandidate(from: episode) {
                transferCandidates[syncEpisode.id] = candidate
            }
            return syncEpisode
        }

        let inbox = inboxEpisodes.compactMap(makeSyncEpisode(from:))

        return SnapshotBundle(
            snapshot: WatchSyncSnapshot(
                generatedAt: .now,
                playlist: playlist,
                inbox: inbox
            ),
            transferCandidates: transferCandidates
        )
    }

    private func fetchPlaylistEntries(with context: ModelContext) -> [PlaylistEntry] {
        let descriptor = FetchDescriptor<PlaylistEntry>(
            predicate: #Predicate<PlaylistEntry> { entry in
                entry.playlist?.title == "de.holgerkrupp.podbay.queue"
            },
            sortBy: [SortDescriptor(\.order)]
        )

        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchInboxEpisodes(with context: ModelContext) -> [Episode] {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.metaData?.isInbox == true
            },
            sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
        )

        return (try? context.fetch(descriptor)) ?? []
    }

    private func makeSyncEpisode(from episode: Episode) -> WatchSyncEpisode? {
        guard let episodeURL = episode.url?.absoluteString else { return nil }
        let audioURL = episodeURL
        let imageURL = (episode.imageURL ?? episode.podcast?.imageURL)?.absoluteString

        return WatchSyncEpisode(
            episodeURL: episodeURL,
            audioURL: audioURL,
            title: episode.title,
            subtitle: episode.subtitle ?? episode.desc,
            podcastTitle: episode.podcast?.title,
            publishDate: episode.publishDate,
            duration: episode.duration,
            imageURL: imageURL,
            phoneHasLocalFile: episode.metaData?.calculatedIsAvailableLocally ?? false,
            fileSize: resolvedFileSize(for: episode),
            playPosition: episode.metaData?.playPosition,
            chapters: makeSyncChapters(from: episode)
        )
    }

    private func makeSyncChapters(from episode: Episode) -> [WatchSyncChapter] {
        resolvedChapters(for: episode).map { chapter in
            WatchSyncChapter(
                id: chapter.uuid?.uuidString ?? "\(chapter.start ?? 0)-\(chapter.title)",
                title: chapter.title,
                start: chapter.start ?? 0,
                duration: chapter.duration,
                imageURL: chapter.image?.absoluteString
            )
        }
    }

    private func resolvedChapters(for episode: Episode) -> [Marker] {
        let chapters = episode.chapters ?? []
        guard chapters.isEmpty == false else { return [] }

        let preferredOrder: [MarkerType] = [.mp3, .mp4, .podlove, .extracted, .ai]
        let priorityByType = Dictionary(
            uniqueKeysWithValues: preferredOrder.enumerated().map { ($1, $0) }
        )
        let categoryGroups = Dictionary(grouping: chapters) {
            $0.title + Duration.seconds($0.start ?? 0).formatted(.units(width: .narrow))
        }

        var resolved: [Marker] = []
        resolved.reserveCapacity(chapters.count)

        for group in categoryGroups.values {
            var bestType: MarkerType?
            var bestPriority = preferredOrder.count

            for marker in group {
                let priority = priorityByType[marker.type] ?? preferredOrder.count
                if priority < bestPriority {
                    bestPriority = priority
                    bestType = marker.type
                }
            }

            guard let bestType else { continue }
            resolved.append(contentsOf: group.filter { $0.type == bestType })
        }

        resolved.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        return resolved
    }

    private func makeTransferCandidate(from episode: Episode) -> TransferCandidate? {
        guard episode.metaData?.calculatedIsAvailableLocally == true,
              let localFile = episode.localFile,
              FileManager.default.fileExists(atPath: localFile.path)
        else {
            return nil
        }

        let values = try? localFile.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values?.fileSize ?? 0)
        guard size > 0 else { return nil }

        return TransferCandidate(fileURL: localFile, size: size)
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

    private func pushSnapshot(_ snapshot: WatchSyncSnapshot, via session: WCSession) {
        guard let data = WatchSyncTransport.encode(snapshot) else { return }

        do {
            try session.updateApplicationContext([
                WatchSyncTransport.snapshotContextKey: data
            ])
        } catch {
            #if DEBUG
            print("Failed to push watch snapshot: \(error)")
            #endif
        }
    }

    private func syncPlaylistFilesIfPossible(_ bundle: SnapshotBundle, via session: WCSession) {
        guard let storageReport = lastStorageReport else { return }

        var remainingBudget = max(storageReport.maxStorageBytes - storageReport.usedBytes, 0)
        let downloadedEpisodeIDs = Set(storageReport.downloadedEpisodeIDs)

        for episode in bundle.snapshot.playlist {
            guard let candidate = bundle.transferCandidates[episode.episodeURL] else { continue }
            guard !downloadedEpisodeIDs.contains(episode.episodeURL) else { continue }
            guard !pendingTransferEpisodeIDs.contains(episode.episodeURL) else { continue }
            guard candidate.size <= remainingBudget else { continue }

            pendingTransferEpisodeIDs.insert(episode.episodeURL)
            session.transferFile(candidate.fileURL, metadata: [
                WatchSyncTransport.transferEpisodeIDKey: episode.episodeURL,
                WatchSyncTransport.transferEpisodeURLKey: episode.episodeURL
            ])
            remainingBudget -= candidate.size
        }
    }

    private func handleIncomingPayload(storageData: Data?, commandData: Data?) async {
        if let data = storageData,
           let report = WatchSyncTransport.decode(WatchStorageReport.self, from: data) {
            lastStorageReport = report
            await refreshSnapshotAndTransfers()
        }

        if let data = commandData,
           let command = WatchSyncTransport.decode(WatchCommand.self, from: data) {
            await handle(command: command)
        }
    }

    private func handle(command: WatchCommand) async {
        switch command.kind {
        case .requestSnapshot:
            await refreshSnapshotAndTransfers()

        case .refreshInbox:
            let subscriptionManager = SubscriptionManager(modelContainer: ModelContainerManager.shared.container)
            await subscriptionManager.bgupdateFeeds()
            await refreshSnapshotAndTransfers()

        case .queueEpisodeAtFront:
            guard let episodeURLString = command.episodeURL,
                  let episodeURL = URL(string: episodeURLString),
                  let playlistActor = try? PlaylistModelActor(modelContainer: ModelContainerManager.shared.container)
            else {
                return
            }

            try? await playlistActor.add(episodeURL: episodeURL, to: .front)
            await refreshSnapshotAndTransfers()

        case .syncPlaybackProgress:
            guard let episodeURLString = command.episodeURL,
                  let episodeURL = URL(string: episodeURLString),
                  let playPosition = command.playPosition
            else {
                return
            }

            let episodeActor = EpisodeActor(modelContainer: ModelContainerManager.shared.container)
            await episodeActor.setLastPlayed(episodeURL: episodeURL)
            await episodeActor.setPlayPosition(episodeURL: episodeURL, position: playPosition)
        }
    }

    private func handleFinishedTransfer(episodeID: String?, error: Error?) {
        if let episodeID {
            pendingTransferEpisodeIDs.remove(episodeID)
        }
        guard error == nil else { return }
    }
}

extension PhoneWatchSyncController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            guard error == nil, activationState == .activated else { return }
            await refreshSnapshotAndTransfers()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            WCSession.default.activate()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            await refreshSnapshotAndTransfers()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        let storageData = applicationContext[WatchSyncTransport.storageContextKey] as? Data
        let commandData = applicationContext[WatchSyncTransport.commandMessageKey] as? Data
        Task { @MainActor in
            await handleIncomingPayload(storageData: storageData, commandData: commandData)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        let storageData = userInfo[WatchSyncTransport.storageContextKey] as? Data
        let commandData = userInfo[WatchSyncTransport.commandMessageKey] as? Data
        Task { @MainActor in
            await handleIncomingPayload(storageData: storageData, commandData: commandData)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        let storageData = message[WatchSyncTransport.storageContextKey] as? Data
        let commandData = message[WatchSyncTransport.commandMessageKey] as? Data
        Task { @MainActor in
            await handleIncomingPayload(storageData: storageData, commandData: commandData)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String : Any],
        replyHandler: @escaping ([String : Any]) -> Void
    ) {
        let storageData = message[WatchSyncTransport.storageContextKey] as? Data
        let commandData = message[WatchSyncTransport.commandMessageKey] as? Data
        replyHandler([:])
        Task { @MainActor in
            await handleIncomingPayload(storageData: storageData, commandData: commandData)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: (any Error)?
    ) {
        let episodeID = fileTransfer.file.metadata?[WatchSyncTransport.transferEpisodeIDKey] as? String
        Task { @MainActor in
            handleFinishedTransfer(episodeID: episodeID, error: error)
        }
    }
}

enum WatchSyncCoordinator {
    static func activate() {
        Task { @MainActor in
            PhoneWatchSyncController.shared.activate()
        }
    }

    static func refreshSoon() {
        Task { @MainActor in
            await PhoneWatchSyncController.shared.refreshSnapshotAndTransfers()
        }
    }
}
