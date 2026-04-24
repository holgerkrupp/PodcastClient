import Foundation
import SwiftData
import CoreData

@MainActor
final class CloudSyncProgressStore: ObservableObject {
    struct EntityCounts: Codable, Equatable {
        var podcasts: Int
        var episodes: Int
        var chapters: Int
        var transcripts: Int

        static let zero = EntityCounts(podcasts: 0, episodes: 0, chapters: 0, transcripts: 0)

        var total: Int {
            podcasts + episodes + chapters + transcripts
        }
    }

    struct DeviceSnapshot: Codable, Equatable, Identifiable {
        var id: String { deviceID }
        var deviceID: String
        var updatedAt: Date
        var counts: EntityCounts
    }

    static let shared = CloudSyncProgressStore()

    @Published private(set) var localCounts: EntityCounts = .zero
    @Published private(set) var expectedCounts: EntityCounts = .zero
    @Published private(set) var expectedUpdatedAt: Date?

    private let kvStore = NSUbiquitousKeyValueStore.default
    private var modelContext: ModelContext?
    private var hasStarted = false
    private var kvStoreObserver: NSObjectProtocol?
    private var cloudKitEventObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?

    private var lastPublishedSnapshot: DeviceSnapshot?
    private var lastPublishDate: Date?

    private static let keyPrefix = "cloudsync.snapshot."
    private static let deviceIDDefaultsKey = "cloudsync.deviceID"
    private static let minimumPublishInterval: TimeInterval = 15
    private static let refreshIntervalNanoseconds: UInt64 = 20_000_000_000

    private init() {}

    var shouldDisplayProgress: Bool {
        let expected = expectedCounts
        guard expected.total > 0 else { return false }
        return localCounts.podcasts < expected.podcasts
            || localCounts.episodes < expected.episodes
            || localCounts.chapters < expected.chapters
            || localCounts.transcripts < expected.transcripts
    }

    var overallProgress: Double {
        let expectedTotal = expectedCounts.total
        guard expectedTotal > 0 else { return 1.0 }
        let localTotal = min(localCounts.total, expectedTotal)
        return max(0, min(1, Double(localTotal) / Double(expectedTotal)))
    }

    var overallProgressText: String {
        "\(Int(overallProgress * 100))%"
    }

    var detailText: String {
        let e = expectedCounts
        let l = localCounts
        let chunks: [String] = [
            "Episodes \(min(l.episodes, e.episodes))/\(e.episodes)",
            "Podcasts \(min(l.podcasts, e.podcasts))/\(e.podcasts)",
            "Chapters \(min(l.chapters, e.chapters))/\(e.chapters)",
            "Transcripts \(min(l.transcripts, e.transcripts))/\(e.transcripts)"
        ]
        return chunks.joined(separator: " · ")
    }

    func startMonitoring(modelContext: ModelContext) {
        self.modelContext = modelContext

        guard hasStarted == false else {
            Task { await refreshNow() }
            return
        }
        hasStarted = true

        kvStoreObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recomputeExpectedCounts()
            }
        }

        cloudKitEventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshNow()
            }
        }

        kvStore.synchronize()
        recomputeExpectedCounts()

        refreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: Self.refreshIntervalNanoseconds)
                await self?.refreshNow()
            }
        }

        Task { await refreshNow() }
    }

    func refreshNow() async {
        await refreshLocalCountsAndPublishIfNeeded(forcePublish: false)
        recomputeExpectedCounts()
    }

    private func refreshLocalCountsAndPublishIfNeeded(forcePublish: Bool) async {
        guard let modelContext else { return }
        let newCounts = computeLocalCounts(using: modelContext)
        localCounts = newCounts
        publishLocalSnapshotIfNeeded(counts: newCounts, forcePublish: forcePublish)
    }

    private func computeLocalCounts(using modelContext: ModelContext) -> EntityCounts {
        let podcasts = (try? modelContext.fetchCount(FetchDescriptor<Podcast>())) ?? 0
        let episodes = (try? modelContext.fetchCount(FetchDescriptor<Episode>())) ?? 0
        let markers = (try? modelContext.fetchCount(FetchDescriptor<Marker>())) ?? 0
        let bookmarks = (try? modelContext.fetchCount(FetchDescriptor<Bookmark>())) ?? 0
        let transcripts = (try? modelContext.fetchCount(FetchDescriptor<TranscriptionRecord>())) ?? 0

        return EntityCounts(
            podcasts: podcasts,
            episodes: episodes,
            chapters: max(0, markers - bookmarks),
            transcripts: transcripts
        )
    }

    private func publishLocalSnapshotIfNeeded(counts: EntityCounts, forcePublish: Bool) {
        let now = Date()
        let snapshot = DeviceSnapshot(
            deviceID: Self.deviceID,
            updatedAt: now,
            counts: counts
        )

        if forcePublish == false {
            if let lastPublishedSnapshot,
               lastPublishedSnapshot.counts == snapshot.counts,
               let lastPublishDate,
               now.timeIntervalSince(lastPublishDate) < Self.minimumPublishInterval {
                return
            }
            if let lastPublishDate,
               now.timeIntervalSince(lastPublishDate) < Self.minimumPublishInterval,
               lastPublishedSnapshot?.counts != snapshot.counts {
                return
            }
        }

        do {
            let data = try JSONEncoder().encode(snapshot)
            kvStore.set(data, forKey: Self.snapshotKey(for: Self.deviceID))
            kvStore.synchronize()
            lastPublishedSnapshot = snapshot
            lastPublishDate = now
        } catch {
            // Best-effort telemetry only: ignore encoding failures.
        }
    }

    private func recomputeExpectedCounts() {
        let snapshots = Self.allSnapshots(from: kvStore)
        guard snapshots.isEmpty == false else {
            expectedCounts = .zero
            expectedUpdatedAt = nil
            return
        }

        // Choose the most "complete" snapshot first, then newest timestamp.
        let best = snapshots.max { lhs, rhs in
            if lhs.counts.total == rhs.counts.total {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.counts.total < rhs.counts.total
        }

        expectedCounts = best?.counts ?? .zero
        expectedUpdatedAt = best?.updatedAt
    }

    private static var deviceID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIDDefaultsKey), existing.isEmpty == false {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: deviceIDDefaultsKey)
        return created
    }

    private static func snapshotKey(for deviceID: String) -> String {
        "\(keyPrefix)\(deviceID)"
    }

    private static func allSnapshots(from kvStore: NSUbiquitousKeyValueStore) -> [DeviceSnapshot] {
        let values = kvStore.dictionaryRepresentation
        return values.compactMap { key, value in
            guard key.hasPrefix(keyPrefix) else { return nil }
            guard let data = value as? Data else { return nil }
            return try? JSONDecoder().decode(DeviceSnapshot.self, from: data)
        }
    }
}
