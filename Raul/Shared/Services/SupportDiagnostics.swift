import Foundation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SupportDiagnosticCount: Codable, Hashable, Sendable {
    let value: Int?
    let state: String?

    static func available(_ value: Int) -> Self { .init(value: value, state: nil) }
    static let unavailable = Self(value: nil, state: "unavailable (local store query failed)")
    static let storeNotOpen = Self(value: nil, state: "unavailable (store not open)")

    var displayValue: String {
        value.map(String.init) ?? state ?? "unavailable"
    }
}

struct SupportDiagnosticEvent: Codable, Hashable, Sendable, Identifiable {
    let at: Date
    let category: String
    let detail: String

    var id: String { "\(at.timeIntervalSince1970)-\(category)" }
}

struct SupportDiagnosticCloudStore: Codable, Hashable, Sendable {
    let store: String
    let setupStatus: String
    let setupAt: Date?
    let importStatus: String
    let importAt: Date?
    let exportStatus: String
    let exportAt: Date?
    let lastSuccessfulExportAt: Date?
    let failureCategories: [String]
}

struct SupportDiagnosticSnapshot: Codable, Hashable, Sendable, Identifiable {
    let capturedAt: Date
    let elapsedSeconds: Int
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let deviceClass: String
    let bootstrapMode: String
    let readAuthority: String
    let runtimeKind: String
    let runtimeStoreStatus: String
    let legacyStoreStatus: String
    let userStateStoreStatus: String
    let cacheStoreStatus: String
    let runtimeReadiness: String
    let migrationVersion: Int
    let migrationPhase: String
    let migrationProgress: String
    let pendingWork: String
    let runtimeQueuePlaylistCount: SupportDiagnosticCount
    let runtimeQueueEntryCount: SupportDiagnosticCount
    let legacyPlaylistCount: SupportDiagnosticCount
    let legacyPlaylistEntryCount: SupportDiagnosticCount
    let userStatePlaylistActiveCount: SupportDiagnosticCount
    let userStatePlaylistTombstoneCount: SupportDiagnosticCount
    let userStatePlaylistEntryActiveCount: SupportDiagnosticCount
    let userStatePlaylistEntryTombstoneCount: SupportDiagnosticCount
    let userStateQueueActiveCount: SupportDiagnosticCount
    let userStateQueueTombstoneCount: SupportDiagnosticCount
    let unresolvedEpisodeReferenceCount: SupportDiagnosticCount
    let networkStatus: String
    let accountStatus: String
    let aggregateErrorCategories: [String]
    let cloudStores: [SupportDiagnosticCloudStore]

    var id: Date { capturedAt }
}

@MainActor
final class SupportDiagnosticsRecorder: ObservableObject {
    static let shared = SupportDiagnosticsRecorder()

    @Published private(set) var snapshots: [SupportDiagnosticSnapshot] = []
    @Published private(set) var events: [SupportDiagnosticEvent] = []
    private(set) var sessionStartedAt = Date()
    private let maximumEvents = 160
    private let eventWindow: TimeInterval = 5 * 60

    init() {}

    func record(_ category: String, detail: String = "") {
        let event = SupportDiagnosticEvent(at: .now, category: category, detail: detail)
        events.append(event)
        trimEvents()
    }

    func recordPlaylistVisibleCount(_ count: Int, isDefaultQueue: Bool) {
        record(isDefaultQueue ? "Up Next visible" : "Playlist visible", detail: "entries=\(count)")
    }

    func append(_ snapshot: SupportDiagnosticSnapshot) {
        snapshots = Array((snapshots + [snapshot]).suffix(2))
        record("Support snapshot captured", detail: "queue_entries=\(snapshot.runtimeQueueEntryCount.displayValue)")
    }

    var reportText: String {
        var sections = [
            NSLocalizedString("Up Next Support Diagnostics", comment: "Title of the support report"),
            NSLocalizedString("Generated locally. This report contains local counts and categorized sync errors; no data was uploaded.", comment: "Privacy note at the top of the support report")
        ]
        if snapshots.isEmpty {
            sections.append(NSLocalizedString("Capture a snapshot while Up Next is empty and another after its entries return.", comment: "Instruction shown before the first diagnostic snapshot"))
        } else {
            sections.append(contentsOf: snapshots.enumerated().map { index, snapshot in
                Self.format(snapshot, index: index + 1)
            })
        }
        sections.append(NSLocalizedString("Recent event timeline (last five minutes)", comment: "Heading for recent app events in support report"))
        let visibleEvents = events.filter { $0.at >= Date().addingTimeInterval(-eventWindow) }
        sections.append(contentsOf: visibleEvents.map {
            "\($0.at.formatted(date: .omitted, time: .standard)) · \($0.category)\($0.detail.isEmpty ? "" : " · \($0.detail)")"
        })
        return sections.joined(separator: "\n\n")
    }

    func capture(
        manager: ModelContainerManager,
        modelContainer: ModelContainer,
        networkStatus: String,
        accountStatus: String,
        aggregateErrorCategories: [String],
        storeMonitor: StoreCloudKitActivityMonitor
    ) async {
        let now = Date()
        let legacyContainer = manager.runtimeProjectsFromCache
            ? manager.preparedLegacyMigrationContainer
            : modelContainer
        let countSnapshot = await SupportDiagnosticsStoreCounter(
            runtimeContainer: modelContainer,
            legacyContainer: legacyContainer,
            userStateContainer: manager.preparedUserStateContainer,
            cacheContainer: manager.preparedCacheContainer
        ).snapshot()

        let snapshot = SupportDiagnosticSnapshot(
            capturedAt: now,
            elapsedSeconds: max(0, Int(now.timeIntervalSince(sessionStartedAt))),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unavailable",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unavailable",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceClass: Self.deviceClass,
            bootstrapMode: manager.bootstrapMode.rawValue,
            readAuthority: manager.bootstrapMode == .legacyUpgrade
                ? "Legacy Library"
                : "User State",
            runtimeKind: manager.runtimeProjectsFromCache ? "in-memory projection" : "durable library store",
            runtimeStoreStatus: "open (primary app container available)",
            legacyStoreStatus: manager.preparedLegacyMigrationContainer != nil || !manager.runtimeProjectsFromCache
                ? "open"
                : "not open",
            userStateStoreStatus: manager.preparedUserStateContainer == nil ? "not open" : "open",
            cacheStoreStatus: manager.preparedCacheContainer == nil ? "not open" : "open",
            runtimeReadiness: String(describing: manager.runtimeStoreReadiness),
            migrationVersion: StoreSplitMigrationService.migrationVersion,
            migrationPhase: manager.migrationCurrentPhase ?? "not observed",
            migrationProgress: manager.migrationProgressSummary ?? "not observed",
            pendingWork: Self.safePendingWork(manager.pendingSplitStoreWorkReason),
            runtimeQueuePlaylistCount: countSnapshot.runtimeQueuePlaylistCount,
            runtimeQueueEntryCount: countSnapshot.runtimeQueueEntryCount,
            legacyPlaylistCount: countSnapshot.legacyPlaylistCount,
            legacyPlaylistEntryCount: countSnapshot.legacyPlaylistEntryCount,
            userStatePlaylistActiveCount: countSnapshot.userStatePlaylistActiveCount,
            userStatePlaylistTombstoneCount: countSnapshot.userStatePlaylistTombstoneCount,
            userStatePlaylistEntryActiveCount: countSnapshot.userStatePlaylistEntryActiveCount,
            userStatePlaylistEntryTombstoneCount: countSnapshot.userStatePlaylistEntryTombstoneCount,
            userStateQueueActiveCount: countSnapshot.userStateQueueActiveCount,
            userStateQueueTombstoneCount: countSnapshot.userStateQueueTombstoneCount,
            unresolvedEpisodeReferenceCount: countSnapshot.unresolvedEpisodeReferenceCount,
            networkStatus: networkStatus,
            accountStatus: accountStatus,
            aggregateErrorCategories: Array(aggregateErrorCategories.prefix(12)),
            cloudStores: Self.cloudStoreSnapshots(storeMonitor)
        )
        append(snapshot)
    }

    private func trimEvents() {
        let cutoff = Date().addingTimeInterval(-eventWindow)
        events.removeAll { $0.at < cutoff }
        if events.count > maximumEvents {
            events.removeFirst(events.count - maximumEvents)
        }
    }

    private static var deviceClass: String {
#if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: "iPhone"
        case .pad: "iPad"
        case .mac: "Mac"
        default: "Apple device"
        }
#else
        "Mac"
#endif
    }

    private static func safePendingWork(_ value: String?) -> String {
        guard let value else { return "none observed" }
        let normalized = value.lowercased()
        if normalized.contains("cloudkit export") { return "waiting for a CloudKit export to settle" }
        if normalized.contains("background") || normalized.contains("scheduled") { return "scheduled for background processing" }
        if normalized.contains("playback") { return "waiting for playback to stop" }
        if normalized.contains("paused") { return "paused by a stability or lifecycle gate" }
        if normalized.contains("foreground") { return "waiting for foreground execution" }
        return "work pending (reason not classified)"
    }

    @MainActor
    private static func cloudStoreSnapshots(
        _ monitor: StoreCloudKitActivityMonitor
    ) -> [SupportDiagnosticCloudStore] {
        let completedEvents = monitor.lastCompletedEvents
        let activeEvents = monitor.activeEvents
        return [StoreCloudKitActivityMonitor.StoreKind.legacy, .userState].map { store in
            func latest(_ kind: StoreCloudKitActivityMonitor.EventKind) -> StoreCloudKitActivityMonitor.CompletedEvent? {
                completedEvents.first { $0.storeKind == store && $0.type == kind }
            }
            func status(_ event: StoreCloudKitActivityMonitor.CompletedEvent?, active: Bool) -> String {
                if active { return "active" }
                guard let event else { return "no event observed" }
                return event.succeeded ? "last observed success" : "last observed failure"
            }
            func categories(_ report: CloudKitFailureAnalyzer.Report?) -> [String] {
                (report?.groups ?? []).prefix(6).map { "\($0.name) × \($0.count)" }
            }
            let active = activeEvents.filter { $0.storeKind == store }
            let setup = latest(.setup)
            let importEvent = latest(.importEvent)
            let export = latest(.export)
            return SupportDiagnosticCloudStore(
                store: store.title,
                setupStatus: status(setup, active: active.contains { $0.type == .setup }),
                setupAt: setup?.endedAt ?? active.first { $0.type == .setup }?.startedAt,
                importStatus: status(importEvent, active: active.contains { $0.type == .importEvent }),
                importAt: importEvent?.endedAt ?? active.first { $0.type == .importEvent }?.startedAt,
                exportStatus: status(export, active: active.contains { $0.type == .export }),
                exportAt: export?.endedAt ?? active.first { $0.type == .export }?.startedAt,
                lastSuccessfulExportAt: completedEvents.first {
                    $0.storeKind == store && $0.type == .export && $0.succeeded
                }?.endedAt,
                failureCategories: categories(export?.failureReport)
            )
        }
    }

    private static func format(_ snapshot: SupportDiagnosticSnapshot, index: Int) -> String {
        let date = snapshot.capturedAt.formatted(date: .numeric, time: .standard)
        let cloud = snapshot.cloudStores.map {
            "\($0.store): setup=\($0.setupStatus) @ \($0.setupAt?.formatted(date: .omitted, time: .standard) ?? "n/a"), import=\($0.importStatus) @ \($0.importAt?.formatted(date: .omitted, time: .standard) ?? "n/a"), export=\($0.exportStatus) @ \($0.exportAt?.formatted(date: .omitted, time: .standard) ?? "n/a"), last successful export=\($0.lastSuccessfulExportAt?.formatted(date: .omitted, time: .standard) ?? "n/a"), errors=\($0.failureCategories.isEmpty ? "none observed" : $0.failureCategories.joined(separator: ", "))"
        }.joined(separator: "\n")
        func formatted(_ key: String, _ values: CVarArg...) -> String {
            String(
                format: NSLocalizedString(key, comment: "Support diagnostic snapshot field"),
                locale: Locale.current,
                arguments: values
            )
        }
        return """
        \(formatted("Snapshot %d · %@ · %d seconds since app session start", index, date, snapshot.elapsedSeconds))
        \(formatted("App %@ (%@) · %@ · %@", snapshot.appVersion, snapshot.appBuild, snapshot.osVersion, snapshot.deviceClass))
        \(formatted("Runtime: bootstrap=%@, read authority=%@, %@, readiness=%@", snapshot.bootstrapMode, snapshot.readAuthority, snapshot.runtimeKind, snapshot.runtimeReadiness))
        \(formatted("Stores: runtime=%@, legacy=%@, user state=%@, cache=%@", snapshot.runtimeStoreStatus, snapshot.legacyStoreStatus, snapshot.userStateStoreStatus, snapshot.cacheStoreStatus))
        \(formatted("Migration: version=%d, phase=%@, progress=%@, pending=%@", snapshot.migrationVersion, snapshot.migrationPhase, snapshot.migrationProgress, snapshot.pendingWork))
        \(formatted("Runtime-visible Up Next (local snapshot): playlists=%@, entries=%@", snapshot.runtimeQueuePlaylistCount.displayValue, snapshot.runtimeQueueEntryCount.displayValue))
        \(formatted("Legacy local snapshot: playlists=%@, playlist entries=%@", snapshot.legacyPlaylistCount.displayValue, snapshot.legacyPlaylistEntryCount.displayValue))
        \(formatted("User State local snapshot: PlaylistSync active/tombstones=%@/%@, PlaylistEntrySync active/tombstones=%@/%@, QueueEntrySync active/tombstones=%@/%@, unresolved episode references=%@", snapshot.userStatePlaylistActiveCount.displayValue, snapshot.userStatePlaylistTombstoneCount.displayValue, snapshot.userStatePlaylistEntryActiveCount.displayValue, snapshot.userStatePlaylistEntryTombstoneCount.displayValue, snapshot.userStateQueueActiveCount.displayValue, snapshot.userStateQueueTombstoneCount.displayValue, snapshot.unresolvedEpisodeReferenceCount.displayValue))
        \(formatted("Network=%@, iCloud account=%@", snapshot.networkStatus, snapshot.accountStatus))
        \(formatted("Aggregate monitor attribution=unknown · errors=%@", snapshot.aggregateErrorCategories.isEmpty ? "none observed" : snapshot.aggregateErrorCategories.joined(separator: ", ")))
        \(NSLocalizedString("CloudKit store events (local observation; not server record counts):", comment: "Heading for per-store CloudKit event information"))
        \(cloud)
        """
    }
}

private struct SupportDiagnosticStoreCounts: Sendable {
    let runtimeQueuePlaylistCount: SupportDiagnosticCount
    let runtimeQueueEntryCount: SupportDiagnosticCount
    let legacyPlaylistCount: SupportDiagnosticCount
    let legacyPlaylistEntryCount: SupportDiagnosticCount
    let userStatePlaylistActiveCount: SupportDiagnosticCount
    let userStatePlaylistTombstoneCount: SupportDiagnosticCount
    let userStatePlaylistEntryActiveCount: SupportDiagnosticCount
    let userStatePlaylistEntryTombstoneCount: SupportDiagnosticCount
    let userStateQueueActiveCount: SupportDiagnosticCount
    let userStateQueueTombstoneCount: SupportDiagnosticCount
    let unresolvedEpisodeReferenceCount: SupportDiagnosticCount

}

private actor SupportDiagnosticsStoreCounter {
    let runtimeContainer: ModelContainer
    let legacyContainer: ModelContainer?
    let userStateContainer: ModelContainer?
    let cacheContainer: ModelContainer?

    init(
        runtimeContainer: ModelContainer,
        legacyContainer: ModelContainer?,
        userStateContainer: ModelContainer?,
        cacheContainer: ModelContainer?
    ) {
        self.runtimeContainer = runtimeContainer
        self.legacyContainer = legacyContainer
        self.userStateContainer = userStateContainer
        self.cacheContainer = cacheContainer
    }

    func snapshot() -> SupportDiagnosticStoreCounts {
        let runtimeQueue = queue(in: runtimeContainer)
        let legacy = legacyContainer.map(legacyCounts) ?? (.storeNotOpen, .storeNotOpen)
        let unavailable = (SupportDiagnosticCount.storeNotOpen, SupportDiagnosticCount.storeNotOpen)
        let playlists = userStateContainer == nil ? unavailable : playlistCounts()
        let entries = userStateContainer == nil ? unavailable : playlistEntryCounts()
        let queue = userStateContainer == nil ? unavailable : queueEntryCounts()
        let unresolved = cacheContainer.map {
            readCount(in: $0, FetchDescriptor<CachedMissingEpisodeReference>())
        } ?? .storeNotOpen
        return SupportDiagnosticStoreCounts(
            runtimeQueuePlaylistCount: runtimeQueue.0,
            runtimeQueueEntryCount: runtimeQueue.1,
            legacyPlaylistCount: legacy.0,
            legacyPlaylistEntryCount: legacy.1,
            userStatePlaylistActiveCount: playlists.0,
            userStatePlaylistTombstoneCount: playlists.1,
            userStatePlaylistEntryActiveCount: entries.0,
            userStatePlaylistEntryTombstoneCount: entries.1,
            userStateQueueActiveCount: queue.0,
            userStateQueueTombstoneCount: queue.1,
            unresolvedEpisodeReferenceCount: unresolved
        )
    }

    private func queue(in container: ModelContainer) -> (SupportDiagnosticCount, SupportDiagnosticCount) {
        let context = ModelContext(container)
        let defaultQueueTitle = Playlist.defaultQueueTitle
        do {
            var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.title == defaultQueueTitle })
            descriptor.fetchLimit = 1
            let playlists = try context.fetch(descriptor)
            guard let playlistID = playlists.first?.id else { return (.available(0), .available(0)) }
            let playlistCount = try context.fetchCount(FetchDescriptor<Playlist>(
                predicate: #Predicate { $0.title == defaultQueueTitle }
            ))
            let entries = try context.fetchCount(FetchDescriptor<PlaylistEntry>(
                predicate: #Predicate { $0.playlist?.id == playlistID }
            ))
            return (.available(playlistCount), .available(entries))
        } catch {
            return (.unavailable, .unavailable)
        }
    }

    private func legacyCounts(in container: ModelContainer) -> (SupportDiagnosticCount, SupportDiagnosticCount) {
        let context = ModelContext(container)
        return (
            count(in: context, FetchDescriptor<Playlist>()),
            count(in: context, FetchDescriptor<PlaylistEntry>())
        )
    }

    private func playlistCounts() -> (SupportDiagnosticCount, SupportDiagnosticCount) {
        tombstoneCounts(
            active: FetchDescriptor<PlaylistSync>(predicate: #Predicate { !$0.isDeleted }),
            tombstones: FetchDescriptor<PlaylistSync>(predicate: #Predicate { $0.isDeleted })
        )
    }

    private func playlistEntryCounts() -> (SupportDiagnosticCount, SupportDiagnosticCount) {
        tombstoneCounts(
            active: FetchDescriptor<PlaylistEntrySync>(predicate: #Predicate { !$0.isDeleted }),
            tombstones: FetchDescriptor<PlaylistEntrySync>(predicate: #Predicate { $0.isDeleted })
        )
    }

    private func queueEntryCounts() -> (SupportDiagnosticCount, SupportDiagnosticCount) {
        tombstoneCounts(
            active: FetchDescriptor<QueueEntrySync>(predicate: #Predicate { !$0.isDeleted }),
            tombstones: FetchDescriptor<QueueEntrySync>(predicate: #Predicate { $0.isDeleted })
        )
    }

    private func tombstoneCounts<Model: PersistentModel>(
        active: FetchDescriptor<Model>,
        tombstones: FetchDescriptor<Model>
    ) -> (SupportDiagnosticCount, SupportDiagnosticCount) {
        guard let userStateContainer else { return (.storeNotOpen, .storeNotOpen) }
        let context = ModelContext(userStateContainer)
        return (count(in: context, active), count(in: context, tombstones))
    }

    private func readCount<Model: PersistentModel>(
        in container: ModelContainer,
        _ descriptor: FetchDescriptor<Model>
    ) -> SupportDiagnosticCount {
        count(in: ModelContext(container), descriptor)
    }

    private func count<Model: PersistentModel>(
        in context: ModelContext,
        _ descriptor: FetchDescriptor<Model>
    ) -> SupportDiagnosticCount {
        do { return SupportDiagnosticCount.available(try context.fetchCount(descriptor)) }
        catch { return SupportDiagnosticCount.unavailable }
    }
}
