import Foundation
import SwiftData
#if canImport(WatchConnectivity)
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

    private struct PlaylistSelection {
        let selectedPlaylist: Playlist
        let manualPlaylists: [Playlist]
        let defaultPlaylistID: UUID?
    }

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private let defaults = UserDefaults.standard
    private let maximumOutstandingFileTransfers = 2
    private let maximumInboxSnapshotEpisodes = 25
    private let maximumSnapshotChaptersPerEpisode = 100
    private let staleFileTransferTimeout: TimeInterval = 120
    private let refreshDebounceNanoseconds: UInt64 = 750_000_000

    private var lastStorageReport: WatchStorageReport?
    private var pendingTransferEpisodeIDs: Set<String> = []
    private var requestedFileTransferEpisodeIDs: Set<String> = []
    private var transferProgressByEpisodeID: [String: Double] = [:]
    private var transferProgressObservers: [String: NSKeyValueObservation] = [:]
    private var lastPushedSnapshot: WatchSyncSnapshot?
    private var lastPushedSnapshotSignature: String?
    private var pendingRefreshTask: Task<Void, Never>?
    private var handledCommandIDs: Set<UUID> = []
    private var handledCommandIDOrder: [UUID] = []
    private let maximumHandledCommandIDs = 100

    private override init() {
        super.init()
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func refreshSnapshotAndTransfers(forcePush: Bool = true) async {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        await performRefreshSnapshotAndTransfers(forcePush: forcePush)
    }

    private func refreshSnapshotAndTransfersFromDebounce() async {
        pendingRefreshTask = nil
        await performRefreshSnapshotAndTransfers(forcePush: false)
    }

    private func performRefreshSnapshotAndTransfers(forcePush: Bool) async {
        guard let session else { return }
        guard session.isPaired, session.isWatchAppInstalled else { return }

        reconcileOutstandingFileTransfers(via: session)
        let bundle = makeSnapshotBundle()
        pushSnapshot(bundle.snapshot, via: session, force: forcePush)
        let didQueueTransfers = syncPlaylistFilesIfPossible(bundle, via: session)
        if didQueueTransfers {
            pushSnapshot(makeSnapshotBundle().snapshot, via: session, force: true)
        }
    }

    func refreshSnapshotAndTransfersSoon() {
        pendingRefreshTask?.cancel()
        let delay = refreshDebounceNanoseconds
        pendingRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.refreshSnapshotAndTransfersFromDebounce()
        }
    }

    private func makeSnapshotBundle() -> SnapshotBundle {
        let container = ModelContainerManager.shared.container
        let context = ModelContext(container)

        let selection = resolvePlaylistSelection(with: context)
        let playlistEntries = selection.selectedPlaylist.ordered
        let inboxEpisodes = fetchInboxEpisodes(with: context)
        let settings = fetchStandardSettings(with: context)
        let enabledSettingsByFeed = fetchEnabledPodcastSettingsByFeed(with: context)
        let globalPlaybackSettings = makePlaybackSettings(from: settings, isPodcastSpecific: false)
        let watchPlaylists = makeSyncPlaylists(from: selection)

        var transferCandidates: [String: TransferCandidate] = [:]
        let playlist = playlistEntries.compactMap { entry -> WatchSyncEpisode? in
            guard let episode = entry.episode else { return nil }
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

        return SnapshotBundle(
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
                phoneTransferEpisodeIDs: Array(pendingTransferEpisodeIDs).sorted(),
                phoneTransferProgressByEpisodeID: filteredTransferProgress(),
                phonePlaybackState: makePhonePlaybackState()
            ),
            transferCandidates: transferCandidates
        )
    }

    private func makePhonePlaybackState() -> WatchPhonePlaybackState {
        let player = Player.shared
        return WatchPhonePlaybackState(
            generatedAt: .now,
            currentEpisodeURL: player.currentEpisodeURL?.absoluteString,
            playPosition: max(player.playPosition, 0),
            duration: player.currentEpisode?.duration,
            isPlaying: player.isPlaying,
            isBuffering: false,
            playbackRate: player.playbackRate
        )
    }

    private func resolvePlaylistSelection(with context: ModelContext) -> PlaylistSelection {
        let defaultPlaylist = Playlist.ensureDefaultQueue(in: context)
        let allPlaylists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? [defaultPlaylist]
        let manualPlaylists = Playlist.manualVisibleSorted(allPlaylists)
        let fallbackPlaylist = manualPlaylists.first(where: { $0.id == defaultPlaylist.id })
            ?? manualPlaylists.first
            ?? defaultPlaylist

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
            defaultPlaylistID: defaultPlaylist.id
        )
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

    private func fetchInboxEpisodes(with context: ModelContext) -> [Episode] {
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.metaData?.isInbox == true
            },
            sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = maximumInboxSnapshotEpisodes

        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchStandardSettings(with context: ModelContext) -> PodcastSettings {
        let defaultSettingsTitle = "de.holgerkrupp.podbay.queue"
        var descriptor = FetchDescriptor<PodcastSettings>(
            predicate: #Predicate { $0.title == defaultSettingsTitle }
        )
        descriptor.fetchLimit = 1

        if let settings = try? context.fetch(descriptor).first {
            return settings
        }

        let settings = PodcastSettings(defaultSettings: true)
        context.insert(settings)
        context.saveIfNeeded()
        return settings
    }

    private func fetchEnabledPodcastSettingsByFeed(with context: ModelContext) -> [URL: PodcastSettings] {
        let descriptor = FetchDescriptor<PodcastSettings>(
            predicate: #Predicate<PodcastSettings> { setting in
                setting.isEnabled == true
            }
        )
        let settings = (try? context.fetch(descriptor)) ?? []
        return settings.reduce(into: [:]) { result, setting in
            guard let feed = setting.podcast?.feed else { return }
            result[feed] = setting
        }
    }

    private func makePlaybackSettings(from settings: PodcastSettings, isPodcastSpecific: Bool) -> WatchPlaybackSettings {
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
                id: chapterSyncID(for: chapter),
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

    private func chapterSyncID(for chapter: Marker) -> String {
        chapter.uuid?.uuidString ?? "\(chapter.start ?? 0)-\(chapter.title)"
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

    private func pushSnapshot(_ snapshot: WatchSyncSnapshot, via session: WCSession, force: Bool = false) {
        let signature = snapshotSignature(snapshot)
        guard force || signature != lastPushedSnapshotSignature else {
            #if DEBUG
            print("Watch sync skipped unchanged snapshot")
            #endif
            return
        }

        guard let data = WatchSyncTransport.encode(snapshot) else { return }

        do {
            try session.updateApplicationContext([
                WatchSyncTransport.snapshotContextKey: data
            ])
            if session.isReachable {
                session.sendMessage(
                    [WatchSyncTransport.snapshotContextKey: data],
                    replyHandler: nil,
                    errorHandler: nil
                )
            }
            lastPushedSnapshot = snapshot
            lastPushedSnapshotSignature = signature
            #if DEBUG
            print("Watch sync pushed snapshot: playlist=\(snapshot.playlist.count), inbox=\(snapshot.inbox.count)")
            #endif
        } catch {
            #if DEBUG
            print("Failed to push watch snapshot: \(error)")
            #endif
        }
    }

    private func snapshotSignature(_ snapshot: WatchSyncSnapshot) -> String {
        let playlistSignature = snapshot.playlist.map(syncEpisodeSignature).joined(separator: "\n")
        let inboxSignature = snapshot.inbox.map(syncEpisodeSignature).joined(separator: "\n")
        let playlistsSignature = snapshot.playlists.map {
            "\($0.id)|\($0.title)|\($0.symbolName)|\($0.isSelected)|\($0.isDefault)"
        }.joined(separator: "\n")
        let transferSignature = snapshot.phoneTransferEpisodeIDs.sorted().joined(separator: ",")
        let progressSignature = snapshot.phoneTransferProgressByEpisodeID
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\(Int(($0.value * 100).rounded()))" }
            .joined(separator: ",")
        let phoneStateSignature = snapshot.phonePlaybackState.map { state in
            return [
                state.currentEpisodeURL ?? "",
                "\(state.duration ?? 0)",
                "\(state.isPlaying)",
                "\(state.isBuffering)",
                "\(state.playbackRate)"
            ].joined(separator: "|")
        } ?? ""

        return [
            playlistSignature,
            inboxSignature,
            playlistsSignature,
            snapshot.selectedPlaylistID ?? "",
            snapshot.selectedPlaylistTitle,
            "\(snapshot.skipBackSeconds)",
            "\(snapshot.skipForwardSeconds)",
            "\(snapshot.playbackSettings)",
            transferSignature,
            progressSignature,
            phoneStateSignature
        ].joined(separator: "\u{1F}")
    }

    private func syncEpisodeSignature(_ episode: WatchSyncEpisode) -> String {
        let chapterSignature = episode.chapters.map {
            "\($0.id)|\($0.title)|\($0.start)|\($0.duration ?? 0)|\($0.imageURL ?? "")|\($0.shouldPlay)"
        }.joined(separator: ";")
        return [
            episode.episodeURL,
            episode.audioURL,
            episode.podcastFeedURL ?? "",
            episode.title,
            episode.subtitle ?? "",
            episode.podcastTitle ?? "",
            "\(episode.publishDate?.timeIntervalSince1970 ?? 0)",
            "\(episode.duration ?? 0)",
            episode.imageURL ?? "",
            "\(episode.phoneHasLocalFile)",
            "\(episode.fileSize ?? 0)",
            chapterSignature,
            "\(String(describing: episode.playbackSettings))"
        ].joined(separator: "|")
    }

    @discardableResult
    private func syncPlaylistFilesIfPossible(_ bundle: SnapshotBundle, via session: WCSession) -> Bool {
        let storageReport: WatchStorageReport
        if let lastStorageReport {
            storageReport = lastStorageReport
        } else {
            storageReport = provisionalStorageReport()
            #if DEBUG
            print("Watch sync using provisional storage report while waiting for watch")
            #endif
        }

        var remainingBudget = max(storageReport.maxStorageBytes - storageReport.usedBytes, 0)
        let downloadedEpisodeIDs = Set(storageReport.downloadedEpisodeIDs)
        var didQueueTransfers = false

        let requestedEpisodeIDs = requestedFileTransferEpisodeIDs
        guard requestedEpisodeIDs.isEmpty == false else { return false }

        for episode in bundle.snapshot.playlist where requestedEpisodeIDs.contains(episode.episodeURL) {
            guard pendingTransferEpisodeIDs.count < maximumOutstandingFileTransfers else {
                #if DEBUG
                print("Watch sync paused file transfer queue: \(pendingTransferEpisodeIDs.count) transfer(s) already outstanding")
                #endif
                break
            }

            guard let candidate = bundle.transferCandidates[episode.episodeURL] else {
                requestedFileTransferEpisodeIDs.remove(episode.episodeURL)
                #if DEBUG
                print("Watch sync cannot fall back to phone transfer for \(episode.title): no local phone file candidate")
                #endif
                continue
            }
            guard !downloadedEpisodeIDs.contains(episode.episodeURL) else {
                requestedFileTransferEpisodeIDs.remove(episode.episodeURL)
                #if DEBUG
                print("Watch sync skipped \(episode.title): already on watch")
                #endif
                continue
            }
            guard !pendingTransferEpisodeIDs.contains(episode.episodeURL) else {
                #if DEBUG
                print("Watch sync skipped \(episode.title): transfer already pending")
                #endif
                continue
            }
            guard candidate.size <= remainingBudget else {
                #if DEBUG
                print("Watch sync skipped \(episode.title): file \(candidate.size) exceeds remaining watch budget \(remainingBudget)")
                #endif
                continue
            }

            pendingTransferEpisodeIDs.insert(episode.episodeURL)
            requestedFileTransferEpisodeIDs.remove(episode.episodeURL)
            transferProgressByEpisodeID[episode.episodeURL] = 0
            let transfer = session.transferFile(candidate.fileURL, metadata: [
                WatchSyncTransport.transferEpisodeIDKey: episode.episodeURL,
                WatchSyncTransport.transferEpisodeURLKey: episode.episodeURL,
                WatchSyncTransport.transferQueuedAtKey: Date().timeIntervalSince1970
            ])
            installProgressObserver(for: transfer, episodeID: episode.episodeURL)
            #if DEBUG
            print("Watch sync queued requested phone fallback transfer: \(episode.title), bytes=\(candidate.size)")
            #endif
            didQueueTransfers = true
            remainingBudget -= candidate.size
        }

        return didQueueTransfers
    }

    private func provisionalStorageReport() -> WatchStorageReport {
        let settings = WatchStorageSettings()
        return WatchStorageReport(
            generatedAt: .now,
            usedBytes: 0,
            maxStorageBytes: settings.maxStorageBytes,
            allowCellularDownloads: settings.allowCellularDownloads,
            downloadedEpisodeIDs: []
        )
    }

    private func reconcileOutstandingFileTransfers(via session: WCSession) {
        let transfers = session.outstandingFileTransfers
        guard transfers.isEmpty == false else {
            if pendingTransferEpisodeIDs.isEmpty == false {
                pendingTransferEpisodeIDs.removeAll()
                transferProgressByEpisodeID.removeAll()
                transferProgressObservers.removeAll()
            }
            return
        }

        var keptEpisodeIDs: Set<String> = []
        var keptTransferCount = 0
        let now = Date().timeIntervalSince1970

        for transfer in transfers {
            guard let episodeID = transfer.file.metadata?[WatchSyncTransport.transferEpisodeIDKey] as? String else {
                continue
            }

            let queuedAt = transfer.file.metadata?[WatchSyncTransport.transferQueuedAtKey] as? TimeInterval
            let age = queuedAt.map { now - $0 }
            let fractionCompleted = transfer.progress.fractionCompleted

            if queuedAt == nil || (age ?? 0) > staleFileTransferTimeout && fractionCompleted == 0 {
                transfer.cancel()
                transferProgressObservers.removeValue(forKey: episodeID)
                transferProgressByEpisodeID.removeValue(forKey: episodeID)
                #if DEBUG
                if let age {
                    print("Watch sync cancelled stale transfer for \(episodeID), age=\(Int(age))s, progress=\(fractionCompleted)")
                } else {
                    print("Watch sync cancelled legacy transfer without queue timestamp for \(episodeID)")
                }
                #endif
                continue
            }

            if keptTransferCount >= maximumOutstandingFileTransfers {
                transfer.cancel()
                transferProgressObservers.removeValue(forKey: episodeID)
                transferProgressByEpisodeID.removeValue(forKey: episodeID)
                #if DEBUG
                print("Watch sync cancelled overflow transfer for \(episodeID)")
                #endif
                continue
            }

            keptEpisodeIDs.insert(episodeID)
            keptTransferCount += 1
            transferProgressByEpisodeID[episodeID] = fractionCompleted
            installProgressObserver(for: transfer, episodeID: episodeID)
            #if DEBUG
            print("Watch sync kept outstanding transfer for \(episodeID), progress=\(fractionCompleted)")
            #endif
        }

        pendingTransferEpisodeIDs = keptEpisodeIDs
        transferProgressByEpisodeID = transferProgressByEpisodeID.filter { keptEpisodeIDs.contains($0.key) }
    }

    private func installProgressObserver(for transfer: WCSessionFileTransfer, episodeID: String) {
        guard transferProgressObservers[episodeID] == nil else { return }

        transferProgressObservers[episodeID] = transfer.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, change in
            guard let fractionCompleted = change.newValue else { return }
            Task { @MainActor in
                self?.handleTransferProgress(fractionCompleted, episodeID: episodeID)
            }
        }
    }

    private func handleTransferProgress(_ fractionCompleted: Double, episodeID: String) {
        let progress = min(max(fractionCompleted, 0), 1)
        let previousProgress = transferProgressByEpisodeID[episodeID] ?? 0
        guard abs(progress - previousProgress) >= 0.01 || progress >= 1 else { return }

        transferProgressByEpisodeID[episodeID] = progress
        #if DEBUG
        let percentage = Int((progress * 100).rounded())
        print("Watch sync transfer progress \(percentage)% for \(episodeID)")
        #endif

        pushTransferProgressSnapshot()
    }

    private func pushTransferProgressSnapshot() {
        guard let session,
              let lastPushedSnapshot,
              session.activationState == .activated
        else {
            return
        }

        pushSnapshot(snapshotWithCurrentTransferState(from: lastPushedSnapshot), via: session)
    }

    private func snapshotWithCurrentTransferState(from snapshot: WatchSyncSnapshot) -> WatchSyncSnapshot {
        WatchSyncSnapshot(
            generatedAt: snapshot.generatedAt,
            playlist: snapshot.playlist,
            inbox: snapshot.inbox,
            playlists: snapshot.playlists,
            selectedPlaylistID: snapshot.selectedPlaylistID,
            selectedPlaylistTitle: snapshot.selectedPlaylistTitle,
            skipBackSeconds: snapshot.skipBackSeconds,
            skipForwardSeconds: snapshot.skipForwardSeconds,
            playbackSettings: snapshot.playbackSettings,
            phoneTransferEpisodeIDs: Array(pendingTransferEpisodeIDs).sorted(),
            phoneTransferProgressByEpisodeID: filteredTransferProgress(),
            phonePlaybackState: makePhonePlaybackState()
        )
    }

    private func filteredTransferProgress() -> [String: Double] {
        transferProgressByEpisodeID.filter { pendingTransferEpisodeIDs.contains($0.key) }
    }

    private func handleIncomingPayload(storageData: Data?, commandData: Data?) async {
        if let data = storageData,
           let report = WatchSyncTransport.decode(WatchStorageReport.self, from: data) {
            let shouldRefresh = storageReportDidChange(report)
            lastStorageReport = report
            #if DEBUG
            print("Watch sync received storage report: used=\(report.usedBytes), max=\(report.maxStorageBytes), downloads=\(report.downloadedEpisodeIDs.count)")
            #endif
            if shouldRefresh {
                await refreshSnapshotAndTransfers()
            }
        }

        if let data = commandData,
           let command = WatchSyncTransport.decode(WatchCommand.self, from: data) {
            await handle(command: command)
        }
    }

    private func storageReportDidChange(_ report: WatchStorageReport) -> Bool {
        guard let lastStorageReport else { return true }

        return lastStorageReport.usedBytes != report.usedBytes
            || lastStorageReport.maxStorageBytes != report.maxStorageBytes
            || lastStorageReport.allowCellularDownloads != report.allowCellularDownloads
            || Set(lastStorageReport.downloadedEpisodeIDs) != Set(report.downloadedEpisodeIDs)
    }

    private func handle(command: WatchCommand) async {
        guard register(commandID: command.id) else { return }

        switch command.kind {
        case .requestSnapshot:
            await refreshSnapshotAndTransfers()

        case .refreshInbox:
            let subscriptionManager = SubscriptionManager(modelContainer: ModelContainerManager.shared.container)
            await subscriptionManager.bgupdateFeeds()
            await refreshSnapshotAndTransfers()

        case .queueEpisodeAtFront:
            guard let episodeURLString = command.episodeURL,
                  let episodeURL = URL(string: episodeURLString)
            else {
                return
            }

            let context = ModelContext(ModelContainerManager.shared.container)
            let selection = resolvePlaylistSelection(with: context)
            let requestedPlaylistID = Playlist.resolvePlaylistID(from: command.playlistID)
            let resolvedPlaylistID = requestedPlaylistID.flatMap { playlistID in
                selection.manualPlaylists.first(where: { $0.id == playlistID })?.id
            } ?? selection.selectedPlaylist.id

            guard let playlistActor = try? PlaylistModelActor(
                modelContainer: ModelContainerManager.shared.container,
                playlistID: resolvedPlaylistID
            ) else {
                return
            }

            switch command.position ?? .front {
            case .front:
                try? await playlistActor.insert(episodeURL: episodeURL, after: Player.shared.currentEpisodeURL)
            case .end:
                try? await playlistActor.add(episodeURL: episodeURL, to: .end)
            }
            await refreshSnapshotAndTransfers()

        case .selectPlaylist:
            guard let playlistID = Playlist.resolvePlaylistID(from: command.playlistID) else {
                await refreshSnapshotAndTransfers()
                return
            }

            let context = ModelContext(ModelContainerManager.shared.container)
            let selection = resolvePlaylistSelection(with: context)
            guard selection.manualPlaylists.contains(where: { $0.id == playlistID }) else {
                await refreshSnapshotAndTransfers()
                return
            }

            defaults.set(playlistID.uuidString, forKey: PlaylistPreferenceKeys.selectedPlaylistID)
            await PlayNextWidgetSync.refresh(
                using: ModelContainerManager.shared.container,
                playlistIDs: Set([playlistID])
            )
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
            await episodeActor.setPlayPosition(episodeURL: episodeURL, position: playPosition, force: true)

        case .setChapterShouldPlay:
            guard let chapterIDString = command.chapterID,
                  let shouldPlay = command.shouldPlay
            else {
                return
            }

            if let chapterID = UUID(uuidString: chapterIDString) {
                let chapterActor = ChapterModelActor(modelContainer: ModelContainerManager.shared.container)
                await chapterActor.setShouldPlay(shouldPlay, for: chapterID)
            } else if let episodeURLString = command.episodeURL,
                      let episodeURL = URL(string: episodeURLString) {
                setChapterShouldPlay(
                    shouldPlay,
                    chapterSyncID: chapterIDString,
                    episodeURL: episodeURL
                )
            }
            await refreshSnapshotAndTransfers()

        case .setPlaybackSettings:
            guard let playbackSettings = command.playbackSettings else { return }

            let settingsActor = PodcastSettingsModelActor(modelContainer: ModelContainerManager.shared.container)
            let podcastFeed = command.podcastFeedURL.flatMap(URL.init(string:))
            await settingsActor.setPlaybackSpeed(for: podcastFeed, to: playbackSettings.playbackSpeed)
            await refreshSnapshotAndTransfers()

        case .requestFileTransfer:
            guard let episodeURLString = command.episodeURL else { return }
            requestedFileTransferEpisodeIDs.insert(episodeURLString)
            #if DEBUG
            print("Watch sync received phone fallback transfer request for \(episodeURLString)")
            #endif
            await refreshSnapshotAndTransfers()

        case .remotePlayEpisode:
            guard let episodeURLString = command.episodeURL,
                  let episodeURL = URL(string: episodeURLString)
            else {
                return
            }
            await Player.shared.playEpisode(
                episodeURL,
                playDirectly: true,
                startingAt: command.playPosition
            )
            await refreshSnapshotAndTransfers()

        case .remotePause:
            Player.shared.pause()
            await refreshSnapshotAndTransfers()

        case .remoteResume:
            Player.shared.play()
            await refreshSnapshotAndTransfers()

        case .remoteSeek:
            guard let playPosition = command.playPosition else { return }
            await Player.shared.jumpTo(time: playPosition)
            await refreshSnapshotAndTransfers()

        case .remoteSkipBackward:
            Player.shared.remoteSkipBack()
            await refreshSnapshotAndTransfers()

        case .remoteSkipForward:
            Player.shared.remoteSkipForward()
            await refreshSnapshotAndTransfers()

        case .remoteSkipToChapterStart:
            await Player.shared.skipToChapterStart()
            await refreshSnapshotAndTransfers()

        case .remoteSkipToNextChapter:
            await Player.shared.skipToNextChapter()
            await refreshSnapshotAndTransfers()

        case .remoteSetPlaybackRate:
            guard let playbackRate = command.playbackRate else { return }
            Player.shared.playbackRate = playbackRate
            await refreshSnapshotAndTransfers()

        case .remoteRemovePlaylistEpisode:
            guard let episodeURLString = command.episodeURL,
                  let episodeURL = URL(string: episodeURLString)
            else {
                return
            }
            let context = ModelContext(ModelContainerManager.shared.container)
            let selection = resolvePlaylistSelection(with: context)
            let requestedPlaylistID = Playlist.resolvePlaylistID(from: command.playlistID)
            let resolvedPlaylistID = requestedPlaylistID.flatMap { playlistID in
                selection.manualPlaylists.first(where: { $0.id == playlistID })?.id
            } ?? selection.selectedPlaylist.id

            if let playlistActor = try? PlaylistModelActor(
                modelContainer: ModelContainerManager.shared.container,
                playlistID: resolvedPlaylistID
            ) {
                try? await playlistActor.remove(episodeURL: episodeURL)
            }
            await refreshSnapshotAndTransfers()

        case .remoteMovePlaylistEpisode:
            guard let sourceIndex = command.sourceIndex,
                  let destinationIndex = command.destinationIndex
            else {
                return
            }
            let context = ModelContext(ModelContainerManager.shared.container)
            let selection = resolvePlaylistSelection(with: context)
            let requestedPlaylistID = Playlist.resolvePlaylistID(from: command.playlistID)
            let resolvedPlaylistID = requestedPlaylistID.flatMap { playlistID in
                selection.manualPlaylists.first(where: { $0.id == playlistID })?.id
            } ?? selection.selectedPlaylist.id

            if let playlistActor = try? PlaylistModelActor(
                modelContainer: ModelContainerManager.shared.container,
                playlistID: resolvedPlaylistID
            ) {
                let actorDestinationIndex = sourceIndex < destinationIndex ? destinationIndex + 1 : destinationIndex
                try? await playlistActor.moveEntry(from: sourceIndex, to: actorDestinationIndex)
            }
            await refreshSnapshotAndTransfers()
        }
    }

    private func register(commandID: UUID) -> Bool {
        guard handledCommandIDs.insert(commandID).inserted else { return false }

        handledCommandIDOrder.append(commandID)
        if handledCommandIDOrder.count > maximumHandledCommandIDs {
            let expiredCommandID = handledCommandIDOrder.removeFirst()
            handledCommandIDs.remove(expiredCommandID)
        }
        return true
    }

    private func setChapterShouldPlay(_ shouldPlay: Bool, chapterSyncID: String, episodeURL: URL) {
        let context = ModelContext(ModelContainerManager.shared.container)
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.url == episodeURL
            }
        )

        guard let episode = try? context.fetch(descriptor).first,
              let chapter = episode.preferredChapters.first(where: { self.chapterSyncID(for: $0) == chapterSyncID })
        else {
            return
        }

        chapter.shouldPlay = shouldPlay
        context.saveIfNeeded()
    }

    private func handleFinishedTransfer(episodeID: String?, error: Error?) {
        if let episodeID {
            pendingTransferEpisodeIDs.remove(episodeID)
            transferProgressObservers.removeValue(forKey: episodeID)
            transferProgressByEpisodeID.removeValue(forKey: episodeID)
        }
        #if DEBUG
        if let error {
            print("Watch sync file transfer failed for \(episodeID ?? "unknown episode"): \(error)")
        } else {
            print("Watch sync file transfer finished for \(episodeID ?? "unknown episode")")
        }
        #endif

        Task {
            await refreshSnapshotAndTransfers()
        }
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

    static func refreshSoon(force: Bool = false) {
        Task { @MainActor in
            if force {
                await PhoneWatchSyncController.shared.refreshSnapshotAndTransfers(forcePush: true)
            } else {
                PhoneWatchSyncController.shared.refreshSnapshotAndTransfersSoon()
            }
        }
    }
}
#else
enum WatchSyncCoordinator {
    static func activate() {}
    static func refreshSoon(force: Bool = false) {}
}
#endif
