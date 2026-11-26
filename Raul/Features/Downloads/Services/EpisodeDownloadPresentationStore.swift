import Foundation
import Combine
import Observation

/// The in-flight download state one episode row shows.
///
/// Only active, paused or failed transfers have an `item`. Completed files are
/// presented from `DownloadedFilesManager`, which stays authoritative for disk
/// availability (#310). Progress lives on the `DownloadItem` and is observed
/// only by the progress view of an active row; it is never persisted.
@MainActor
@Observable
final class EpisodeDownloadPresentationEntry {
    let episodeURL: URL
    fileprivate(set) var item: DownloadItem?
    fileprivate(set) var isStarting = false

    init(episodeURL: URL) {
        self.episodeURL = episodeURL
    }
}

/// One shared coordinator for list download controls (#498).
///
/// Rows read the keyed entry for their episode URL instead of each owning a
/// view model that asks `DownloadManager` for its item whenever the row
/// scrolls on screen and subscribes to every download notification. The store
/// takes one snapshot of active transfers, then follows start and finish
/// notifications for the affected key only.
@MainActor
final class EpisodeDownloadPresentationStore {
    static let shared = EpisodeDownloadPresentationStore()

    typealias ItemLookup = @Sendable (URL) async -> DownloadItem?
    typealias SnapshotLookup = @Sendable () async -> [DownloadItem]

    private var entries: [URL: EpisodeDownloadPresentationEntry] = [:]
    private var items: [URL: DownloadItem] = [:]
    private var finishObservations: [URL: AnyCancellable] = [:]
    private var observers: [NSObjectProtocol] = []
    private let itemLookup: ItemLookup

    init(
        notificationCenter: NotificationCenter = .default,
        itemLookup: @escaping ItemLookup = { await DownloadManager.shared.getItem(for: $0) },
        snapshotLookup: @escaping SnapshotLookup = { await DownloadManager.shared.currentItems() }
    ) {
        self.itemLookup = itemLookup

        observers.append(notificationCenter.addObserver(
            forName: .episodeDownloadStarted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = Self.notificationURL(notification) else { return }
            MainActor.assumeIsolated { self?.downloadDidStart(url) }
        })
        observers.append(notificationCenter.addObserver(
            forName: .episodeDownloadFinished,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = Self.notificationURL(notification) else { return }
            MainActor.assumeIsolated { self?.apply(nil, for: url) }
        })

        Task { [weak self] in
            let snapshot = await snapshotLookup()
            guard let self else { return }
            for item in snapshot where self.items[item.url] == nil {
                self.apply(item, for: item.url)
            }
        }
    }

    // MARK: - Reading

    /// Dictionary lookup only. Never starts an actor lookup.
    func entry(for episodeURL: URL) -> EpisodeDownloadPresentationEntry {
        if let entry = entries[episodeURL] { return entry }
        let entry = EpisodeDownloadPresentationEntry(episodeURL: episodeURL)
        entry.item = items[episodeURL]
        entries[episodeURL] = entry
        return entry
    }

    func item(for episodeURL: URL) -> DownloadItem? {
        items[episodeURL]
    }

    // MARK: - Updates

    func downloadDidStart(_ episodeURL: URL) {
        Task { [weak self, itemLookup] in
            let item = await itemLookup(episodeURL)
            self?.apply(item, for: episodeURL)
        }
    }

    func apply(_ item: DownloadItem?, for episodeURL: URL) {
        finishObservations[episodeURL] = nil
        guard let item, item.isFinished == false else {
            items[episodeURL] = nil
            if entries[episodeURL]?.item != nil { entries[episodeURL]?.item = nil }
            return
        }

        items[episodeURL] = item
        if entries[episodeURL]?.item !== item { entries[episodeURL]?.item = item }
        finishObservations[episodeURL] = item.$isFinished
            .dropFirst()
            .filter { $0 }
            .sink { [weak self, weak item] _ in
                Task { @MainActor in
                    guard let self, let item, self.items[episodeURL] === item else { return }
                    self.apply(nil, for: episodeURL)
                }
            }
    }

    // MARK: - Actions

    func startDownload(for episode: Episode) {
        guard episode.source != .sideLoaded, let url = episode.url else { return }
        let entry = entry(for: url)
        guard entry.isStarting == false else { return }
        entry.isStarting = true
        let destination = episode.localFile
        let protectionEnabled = PodcastNetworkPrivacyPolicy.isEnabled(forPodcast: episode.podcast)
        Task {
            let result = await DownloadManager.shared.download(
                from: url,
                saveTo: destination,
                networkTrackingProtectionEnabled: protectionEnabled
            )
            apply(result, for: url)
            entry.isStarting = false
        }
    }

    func retryDownload(for episode: Episode) {
        guard episode.source != .sideLoaded, let url = episode.url else { return }
        let entry = entry(for: url)
        guard entry.isStarting == false else { return }
        entry.isStarting = true
        let destination = episode.localFile
        let protectionEnabled = PodcastNetworkPrivacyPolicy.isEnabled(forPodcast: episode.podcast)
        Task {
            await DownloadManager.shared.cancelDownload(for: url)
            apply(nil, for: url)
            let result = await DownloadManager.shared.download(
                from: url,
                saveTo: destination,
                networkTrackingProtectionEnabled: protectionEnabled
            )
            apply(result, for: url)
            entry.isStarting = false
        }
    }

    func pauseDownload(for episodeURL: URL) {
        guard let item = items[episodeURL] else { return }
        item.isPaused = true
        Task { await DownloadManager.shared.pauseDownload(for: item.url) }
    }

    func cancelDownload(for episodeURL: URL) {
        guard let item = items[episodeURL] else { return }
        item.isPaused = false
        item.isDownloading = false
        item.isFinished = true
        apply(nil, for: episodeURL)
        Task { await DownloadManager.shared.cancelDownload(for: item.url) }
    }

    func resumeDownload(for episode: Episode) {
        guard let url = episode.url, let item = items[url] else { return }
        item.isPaused = false
        let protectionEnabled = PodcastNetworkPrivacyPolicy.isEnabled(forPodcast: episode.podcast)
        Task {
            await DownloadManager.shared.resumeDownload(
                for: item.url,
                networkTrackingProtectionEnabled: protectionEnabled
            )
        }
    }

    nonisolated private static func notificationURL(_ notification: Notification) -> URL? {
        let value = notification.userInfo?[EpisodeDownloadNotificationKey.episodeURL]
        if let url = value as? URL { return url }
        if let url = value as? NSURL { return url as URL }
        if let string = value as? String { return URL(string: string) }
        return nil
    }
}
