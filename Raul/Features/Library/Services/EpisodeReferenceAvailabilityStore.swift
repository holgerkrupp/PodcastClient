import Foundation
import Observation
import SwiftData

/// Chapter, transcript and bookmark badges for episode list rows.
///
/// A list row must never derive these flags from live relationships: reading
/// `chapters`, `bookmarks`, `transcriptLines` or the decoded `externalFiles`
/// array faults SwiftData state every time SwiftUI recreates a row (#498).
/// Rows read a keyed entry from `EpisodeReferenceAvailabilityStore`; the
/// store computes missing entries in coalesced background batches.
struct EpisodeReferenceAvailability: Equatable, Sendable {
    var hasChapters = false
    var hasTranscript = false
    var hasBookmarks = false

}

/// One observable value per episode URL, so an update re-renders only the row
/// showing that episode.
@MainActor
@Observable
final class EpisodeReferenceAvailabilityEntry {
    let episodeURL: URL
    fileprivate(set) var availability: EpisodeReferenceAvailability?

    init(episodeURL: URL, availability: EpisodeReferenceAvailability? = nil) {
        self.episodeURL = episodeURL
        self.availability = availability
    }
}

@ModelActor
actor EpisodeReferenceAvailabilityLoader {
    func availability(
        for requests: [URL: PersistentIdentifier]
    ) -> [URL: EpisodeReferenceAvailability] {
        var result: [URL: EpisodeReferenceAvailability] = [:]
        for (url, id) in requests {
            guard Task.isCancelled == false else { break }
            let episode: Episode? = modelContext.existingModel(for: id)
            guard let episode else { continue }
            result[url] = EpisodeReferenceAvailability(
                hasChapters: episode.chapters?.isEmpty == false,
                hasTranscript: hasTranscriptLines(episodeID: id)
                    || episode.externalFiles.contains(where: { $0.category == .transcript }),
                hasBookmarks: episode.bookmarks?.isEmpty == false
            )
        }
        return result
    }

    /// A transcript can have thousands of lines; count one row instead of
    /// materializing the whole relationship.
    private func hasTranscriptLines(episodeID: PersistentIdentifier) -> Bool {
        var descriptor = FetchDescriptor<TranscriptLineAndTime>(
            predicate: #Predicate<TranscriptLineAndTime> { $0.episode?.persistentModelID == episodeID }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }
}

@MainActor
final class EpisodeReferenceAvailabilityStore {
    static let shared = EpisodeReferenceAvailabilityStore()

    typealias Loader = @Sendable (
        _ container: ModelContainer,
        _ requests: [URL: PersistentIdentifier]
    ) async -> [URL: EpisodeReferenceAvailability]

    private var entries: [URL: EpisodeReferenceAvailabilityEntry] = [:]
    private var pending: [URL: PersistentIdentifier] = [:]
    private var knownIDs: [URL: PersistentIdentifier] = [:]
    private var container: ModelContainer?
    private var batchTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private let loader: Loader
    private let batchDelay: Duration
    private let onReferencesChanged: @MainActor () -> Void

    init(
        notificationCenter: NotificationCenter = .default,
        batchDelay: Duration = .milliseconds(120),
        loader: @escaping Loader = { container, requests in
            await EpisodeReferenceAvailabilityLoader(modelContainer: container)
                .availability(for: requests)
        },
        onReferencesChanged: @escaping @MainActor () -> Void = {
            // A file deletion toggles `Episode.refresh`. Refresh the
            // inventory once here instead of once per visible row.
            DownloadedFilesManager.shared.refreshDownloadedFiles()
        }
    ) {
        self.loader = loader
        self.batchDelay = batchDelay
        self.onReferencesChanged = onReferencesChanged
        observer = notificationCenter.addObserver(
            forName: .episodeReferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let url = Self.notificationURL(
                notification.userInfo?[EpisodeReferenceNotificationKey.episodeURL]
            )
            MainActor.assumeIsolated {
                self?.referencesDidChange(for: url)
            }
        }
    }

    /// The keyed entry for a row. Dictionary lookup only; never touches the
    /// episode's relationships.
    func entry(for episodeURL: URL) -> EpisodeReferenceAvailabilityEntry {
        if let entry = entries[episodeURL] { return entry }
        let entry = EpisodeReferenceAvailabilityEntry(episodeURL: episodeURL)
        entries[episodeURL] = entry
        return entry
    }

    /// Schedules a batched background derivation when the entry has no value.
    func loadIfNeeded(
        _ entry: EpisodeReferenceAvailabilityEntry,
        episodeID: PersistentIdentifier,
        container: ModelContainer
    ) {
        knownIDs[entry.episodeURL] = episodeID
        self.container = container
        guard entry.availability == nil else { return }
        pending[entry.episodeURL] = episodeID
        scheduleBatch()
    }

    /// Keeps the current badges visible and re-derives the affected entries
    /// in the background. A notification without a URL re-derives every
    /// entry this session has shown.
    func referencesDidChange(for episodeURL: URL?) {
        onReferencesChanged()
        let urls = episodeURL.map { [$0] } ?? Array(knownIDs.keys)
        for url in urls {
            guard let id = knownIDs[url] else { continue }
            pending[url] = id
        }
        if pending.isEmpty == false { scheduleBatch() }
    }

    private func scheduleBatch() {
        guard batchTask == nil else { return }
        let delay = batchDelay
        batchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.runBatch()
        }
    }

    private func runBatch() async {
        let requests = pending
        pending = [:]
        guard let container, requests.isEmpty == false else {
            batchTask = nil
            return
        }

        let results = await loader(container, requests)
        for (url, availability) in results {
            guard let entry = entries[url], entry.availability != availability else { continue }
            entry.availability = availability
        }
        batchTask = nil
        if pending.isEmpty == false { scheduleBatch() }
    }

    nonisolated private static func notificationURL(_ value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let url = value as? NSURL { return url as URL }
        if let string = value as? String { return URL(string: string) }
        return nil
    }
}
