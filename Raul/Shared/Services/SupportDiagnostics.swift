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

struct SupportDiagnosticStoreFile: Codable, Hashable, Sendable {
    let name: String
    let status: String
    let approximateBytes: Int64?

    var displayValue: String {
        guard status == "present" else { return "\(name)=\(status)" }
        let size = approximateBytes.map { "\($0) bytes" } ?? "size unavailable"
        return "\(name)=present (\(size))"
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
    let exportEventID: String?
    let exportStartedAt: Date?
    let exportAt: Date?
    let lastFailedExportEventID: String?
    let lastFailedExportAt: Date?
    let lastSuccessfulExportAt: Date?
    let failedExportCount: Int
    let retryAfterSeconds: Double?
    let failureCategories: [String]
}

struct SupportDiagnosticSnapshot: Codable, Hashable, Sendable, Identifiable {
    let capturedAt: Date
    let elapsedSeconds: Int
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let deviceClass: String
    let releasePhase: String
    let bootstrapMode: String
    let installationClassification: String
    let onboardingCompleted: Bool
    let appGroupAvailable: Bool
    let storeFiles: [SupportDiagnosticStoreFile]
    let legacyCloudAttachmentConfigured: Bool
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
    let runtimeSubscriptionCount: SupportDiagnosticCount
    let legacySubscriptionCount: SupportDiagnosticCount
    let userStateSubscriptionActiveCount: SupportDiagnosticCount
    let userStateSubscriptionTombstoneCount: SupportDiagnosticCount
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
    let portableRecovery: SupportDiagnosticPortableRecovery
    let cloudStores: [SupportDiagnosticCloudStore]

    var id: Date { capturedAt }
}

struct SupportDiagnosticPortableRecovery: Codable, Hashable, Sendable {
    let status: String
    let outboxCount: Int?
    let outboxCapacity: Int
    let oldestOutboxAgeSeconds: Int?
    let fallbackWriteCount: Int
    let incidentCount: Int
    let operationKinds: [String]
    let failureStages: [String]
    let failureCategories: [String]
    let firstRetryAt: Date?
    let lastRetryAt: Date?
    let lastDrainAttemptAt: Date?
    let lastDrainSucceededAt: Date?
    let lastDrainFailedAt: Date?
    let lastSuccessfulRepairAt: Date?
    let lastDrainFailureCategory: String?

    init(
        state: PortableWriteFailureMonitor.State,
        queue: StoreSplitPortableWriteOutbox.QueueDiagnostics? = nil
    ) {
        status = state.status.rawValue
        outboxCount = queue?.count ?? state.latestQueueCount
        outboxCapacity = queue?.capacity ?? state.latestQueueCapacity
        oldestOutboxAgeSeconds = queue?.oldestAge.map { max(0, Int($0)) }
            ?? state.latestQueueOldestAgeSeconds
        fallbackWriteCount = state.pendingOperations.count
        incidentCount = state.incidents.count
        operationKinds = Array(Set(state.incidents.map(\.operationKind))).sorted()
        failureStages = Array(Set(state.incidents.map(\.failureStage))).sorted()
        failureCategories = Array(Set(state.incidents.map(\.errorCategory))).sorted()
        firstRetryAt = state.firstRetryAt
        lastRetryAt = state.lastRetryAt
        lastDrainAttemptAt = state.lastDrainAttemptAt
        lastDrainSucceededAt = state.lastDrainSucceededAt
        lastDrainFailedAt = state.lastDrainFailedAt
        lastSuccessfulRepairAt = state.lastSuccessfulRepairAt
        lastDrainFailureCategory = state.latestDrainFailureCategory
    }
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
            sections.append(NSLocalizedString("Capture a snapshot while Up Next is empty and another after its entries return, or after waiting at least three minutes. Install the build without reinstalling or resetting data.", comment: "Instruction shown before the first diagnostic snapshot"))
        } else {
            sections.append(contentsOf: snapshots.enumerated().map { index, snapshot in
                Self.format(snapshot, index: index + 1)
            })
        }
        sections.append("Listening totals and subscriptions: \(ListeningTotalsDiagnostics.latest)")
        sections.append("User data copy pending: \(StoreCutoverState.isDeferredMigrationPending), phase: \(StoreCutoverState.currentCopyPhase)")
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
        let countSnapshot = await SupportDiagnosticsStoreCounter(
            runtimeContainer: modelContainer,
            legacyContainer: nil,
            userStateContainer: manager.preparedUserStateContainer,
            cacheContainer: manager.preparedCacheContainer
        ).snapshot()
        let portableOutboxQueue = try? await StoreSplitPortableWriteOutbox.shared.queueDiagnostics()

        let snapshot = SupportDiagnosticSnapshot(
            capturedAt: now,
            elapsedSeconds: max(0, Int(now.timeIntervalSince(sessionStartedAt))),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unavailable",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unavailable",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceClass: Self.deviceClass,
            releasePhase: Self.releasePhase,
            bootstrapMode: manager.bootstrapMode.rawValue,
            installationClassification: Self.installationClassification(manager.bootstrapMode),
            onboardingCompleted: UserDefaults.standard.bool(forKey: "didCompleteOnboarding"),
            appGroupAvailable: ModelContainerManager.sharedContainerURL != nil,
            storeFiles: Self.storeFiles(),
            legacyCloudAttachmentConfigured: StoreDevelopmentConfiguration.legacyCloudSyncEnabled,
            readAuthority: "User State",
            runtimeKind: manager.runtimeProjectsFromCache ? "in-memory projection" : "durable library store",
            runtimeStoreStatus: "open (primary app container available)",
            legacyStoreStatus: "not used (local library is the runtime)",
            userStateStoreStatus: manager.preparedUserStateContainer == nil ? "not open" : "open",
            cacheStoreStatus: manager.preparedCacheContainer == nil ? "not open" : "open",
            runtimeReadiness: String(describing: manager.runtimeStoreReadiness),
            migrationVersion: StoreSplitMigrationService.migrationVersion,
            migrationPhase: StoreCutoverState.isDeferredMigrationPending ? "copying to user state" : "complete",
            migrationProgress: "not observed",
            pendingWork: Self.safePendingWork(manager.pendingSplitStoreWorkReason),
            runtimeQueuePlaylistCount: countSnapshot.runtimeQueuePlaylistCount,
            runtimeQueueEntryCount: countSnapshot.runtimeQueueEntryCount,
            runtimeSubscriptionCount: countSnapshot.runtimeSubscriptionCount,
            legacySubscriptionCount: countSnapshot.legacySubscriptionCount,
            userStateSubscriptionActiveCount: countSnapshot.userStateSubscriptionActiveCount,
            userStateSubscriptionTombstoneCount: countSnapshot.userStateSubscriptionTombstoneCount,
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
            portableRecovery: SupportDiagnosticPortableRecovery(
                state: PortableWriteFailureMonitor.shared.state,
                queue: portableOutboxQueue
            ),
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

    private static var releasePhase: String {
        switch StoreSplitReleasePhase.current {
        case .dualSyncBackfill: "dualSyncBackfill"
        case .userStateAuthority: "userStateAuthority"
        }
    }

    private static func installationClassification(_ mode: StoreBootstrapMode) -> String {
        switch mode {
        case .freshSplitInstall: "new split install"
        case .legacyUpgrade: "existing installation"
        case .existingLibraryUnavailable: "existing installation; library unavailable"
        }
    }

    private static func storeFiles() -> [SupportDiagnosticStoreFile] {
        let names = [
            "SharedDatabase.sqlite", "SharedDatabase.sqlite-wal", "SharedDatabase.sqlite-shm",
            "UserState.sqlite", "UserState.sqlite-wal", "UserState.sqlite-shm",
            "PodcastCache.sqlite", "PodcastCache.sqlite-wal", "PodcastCache.sqlite-shm"
        ]
        guard let directory = ModelContainerManager.sharedContainerURL else {
            return names.map { SupportDiagnosticStoreFile(name: $0, status: "unknown (App Group unavailable)", approximateBytes: nil) }
        }
        return names.map { name in
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else {
                return SupportDiagnosticStoreFile(name: name, status: "not found or unreadable", approximateBytes: nil)
            }
            return SupportDiagnosticStoreFile(name: name, status: "present", approximateBytes: size.int64Value)
        }
    }

    /// Safe to call from the launch recovery screen. Reads metadata and
    /// defaults only; it never opens a model container or changes sync state.
    static func launchReport() -> String {
        let fileSummary = storeFiles().map(\.displayValue).joined(separator: ", ")
        let configured = StoreDevelopmentConfiguration.legacyCloudSyncEnabled
        let onboarding = UserDefaults.standard.bool(forKey: "didCompleteOnboarding")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unavailable"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unavailable"
        let manager = ModelContainerManager.shared
        let startupEvents = recentStartupEvents()
        let releasePhase: String
        switch StoreSplitReleasePhase.current {
        case .dualSyncBackfill: releasePhase = "dualSyncBackfill"
        case .userStateAuthority: releasePhase = "userStateAuthority"
        }
        return """
        Up Next Data Recovery Diagnostics
        App version/build: \(version) (\(build))
        Release phase: \(releasePhase)
        Runtime container: \(manager.preparedContainer == nil ? "not open" : "open")
        Runtime readiness: \(String(describing: manager.runtimeStoreReadiness))
        Bootstrap mode: \(manager.preparedContainer == nil ? "not yet adopted" : manager.bootstrapMode.rawValue)
        Initialization error recorded: \(manager.initializationError != nil || manager.userStateInitializationError != nil || manager.cacheInitializationError != nil)
        User data copy pending: \(StoreCutoverState.isDeferredMigrationPending)
        Runtime hydration: \(manager.lastHydrationSummary ?? "not finished")
        Memory footprint: \(MemoryFootprint.current() / (1024 * 1024)) MB
        Listening totals: \(ListeningTotalsDiagnostics.latest), deferred pending: \(StoreCutoverState.isDeferredMigrationPending)
        Library build: \(ModelContainerManager.shared.lastHydrationSummary ?? "not this launch"), transcripts pending: \(StoreRuntimeProjection.isLibraryBackfillPending)
        Recent startup and hydration events (category and time only):
        \(startupEvents.isEmpty ? "none observed" : startupEvents)
        App Group available: \(ModelContainerManager.sharedContainerURL != nil)
        Onboarding previously completed: \(onboarding)
        Installation evidence: \(onboarding ? "existing installation" : "unknown/new installation")
        Legacy CloudKit attachment configured: \(configured)
        SQLite files: \(fileSummary)
        """
    }

    /// Keep this launch-only view small and privacy-safe: categories are selected
    /// from a fixed startup allowlist, and event details/error text are omitted.
    private static func recentStartupEvents() -> String {
        let startupCategories: Set<String> = [
            "Library migration started",
            "Library migration ended",
            "Deferred library migration ended",
            "Opening User State store",
            "Opening Podcast cache store",
            "Opening runtime library store",
            "Runtime library store opened",
            "User State store preparation",
            "Podcast cache store preparation",
            "Runtime store ready",
            "Runtime compatibility hydration started",
            "Runtime compatibility hydration finished",
            "Runtime compatibility hydration interrupted",
            "Runtime compatibility hydration failed",
            "Playlist hydration started",
            "Playlist hydration finished"
        ]
        let formatter = ISO8601DateFormatter()
        return SupportDiagnosticsRecorder.shared.events
            .filter { startupCategories.contains($0.category) }
            .suffix(12)
            .map { "\(formatter.string(from: $0.at)) \($0.category)" }
            .joined(separator: "\n")
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
                (report?.groups ?? []).prefix(6).map { group in
                    let detail = group.detail.map { " [\($0)]" } ?? ""
                    return "\(group.displayName) × \(group.count)\(detail)"
                }
            }
            let active = activeEvents.filter { $0.storeKind == store }
            let setup = latest(.setup)
            let importEvent = latest(.importEvent)
            let export = latest(.export)
            let completedExports = completedEvents
                .filter { $0.storeKind == store }
                .filter { $0.type == .export }
            let failedExports = completedExports.filter { $0.succeeded == false }
            let lastFailedExport = failedExports.first
            let failedExportCount = failedExports.count
            let activeSetup = active.first { $0.type == .setup }
            let activeImport = active.first { $0.type == .importEvent }
            let activeExport = active.first { $0.type == .export }
            let setupStatus = status(setup, active: activeSetup != nil)
            let importStatus = status(importEvent, active: activeImport != nil)
            let exportStatus = status(export, active: activeExport != nil)
            let retryAfterSeconds = lastFailedExport?.failureReport?.groups
                .first(where: { $0.retryAfterSeconds != nil })?.retryAfterSeconds
            let lastSuccessfulExport = completedExports.first { $0.succeeded }
            let setupAt = setup?.endedAt ?? activeSetup?.startedAt
            let importAt = importEvent?.endedAt ?? activeImport?.startedAt
            let exportStartedAt = export?.startedAt ?? activeExport?.startedAt
            let exportAt = export?.endedAt ?? activeExport?.startedAt
            return SupportDiagnosticCloudStore(
                store: store.title,
                setupStatus: setupStatus,
                setupAt: setupAt,
                importStatus: importStatus,
                importAt: importAt,
                exportStatus: exportStatus,
                exportEventID: export?.id.uuidString,
                exportStartedAt: exportStartedAt,
                exportAt: exportAt,
                lastFailedExportEventID: lastFailedExport?.id.uuidString,
                lastFailedExportAt: lastFailedExport?.endedAt,
                lastSuccessfulExportAt: lastSuccessfulExport?.endedAt,
                failedExportCount: failedExportCount,
                retryAfterSeconds: retryAfterSeconds,
                failureCategories: categories(lastFailedExport?.failureReport)
            )
        }
    }

    private static func format(_ snapshot: SupportDiagnosticSnapshot, index: Int) -> String {
        let date = snapshot.capturedAt.formatted(date: .numeric, time: .standard)
        let cloud = snapshot.cloudStores.map {
            let started = $0.exportStartedAt?.formatted(date: .omitted, time: .standard) ?? "n/a"
            let ended = $0.exportAt?.formatted(date: .omitted, time: .standard) ?? "n/a"
            let successful = $0.lastSuccessfulExportAt?.formatted(date: .omitted, time: .standard) ?? "n/a"
            let eventID = $0.exportEventID ?? "n/a"
            let failedEventID = $0.lastFailedExportEventID ?? "n/a"
            let failedAt = $0.lastFailedExportAt?.formatted(date: .omitted, time: .standard) ?? "n/a"
            let retry = $0.retryAfterSeconds.map { String(Int(ceil($0))) } ?? "n/a"
            let failedCount = String($0.failedExportCount)
            let errors = $0.failureCategories.isEmpty ? "none observed" : $0.failureCategories.joined(separator: ", ")
            return formatted(
                "%@ · setup %@ at %@ · import %@ at %@ · latest export %@ (event %@, %@–%@) · last successful export %@ · last failed export at %@ (event %@) · failed exports in retained history %@ · retry hint %@ seconds · failure categories %@",
                $0.store, $0.setupStatus, $0.setupAt?.formatted(date: .omitted, time: .standard) ?? "n/a",
                $0.importStatus, $0.importAt?.formatted(date: .omitted, time: .standard) ?? "n/a",
                $0.exportStatus, eventID, started, ended, successful, failedAt, failedEventID,
                failedCount, retry, errors
            )
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
        \(formatted("Runtime: release phase=%@, bootstrap=%@, classification=%@, onboarding completed=%@, read authority=%@, %@, readiness=%@", snapshot.releasePhase, snapshot.bootstrapMode, snapshot.installationClassification, snapshot.onboardingCompleted ? "yes" : "no", snapshot.readAuthority, snapshot.runtimeKind, snapshot.runtimeReadiness))
        \(formatted("App Group available=%@ · legacy CloudKit attachment configured=%@", snapshot.appGroupAvailable ? "yes" : "no", snapshot.legacyCloudAttachmentConfigured ? "yes" : "no"))
        \(formatted("SQLite files (approximate bytes): %@", snapshot.storeFiles.map(\.displayValue).joined(separator: ", ")))
        \(formatted("Stores: runtime=%@, legacy=%@, user state=%@, cache=%@", snapshot.runtimeStoreStatus, snapshot.legacyStoreStatus, snapshot.userStateStoreStatus, snapshot.cacheStoreStatus))
        \(formatted("Migration: version=%d, phase=%@, progress=%@, pending=%@", snapshot.migrationVersion, snapshot.migrationPhase, snapshot.migrationProgress, snapshot.pendingWork))
        \(formatted("Runtime-visible local snapshot: subscriptions=%@, Up Next playlists=%@, entries=%@", snapshot.runtimeSubscriptionCount.displayValue, snapshot.runtimeQueuePlaylistCount.displayValue, snapshot.runtimeQueueEntryCount.displayValue))
        \(formatted("Legacy local snapshot: subscriptions=%@, playlists=%@, playlist entries=%@", snapshot.legacySubscriptionCount.displayValue, snapshot.legacyPlaylistCount.displayValue, snapshot.legacyPlaylistEntryCount.displayValue))
        \(formatted("User State local snapshot: subscriptions active/tombstones=%@/%@, PlaylistSync active/tombstones=%@/%@, PlaylistEntrySync active/tombstones=%@/%@, QueueEntrySync active/tombstones=%@/%@, unresolved episode references=%@", snapshot.userStateSubscriptionActiveCount.displayValue, snapshot.userStateSubscriptionTombstoneCount.displayValue, snapshot.userStatePlaylistActiveCount.displayValue, snapshot.userStatePlaylistTombstoneCount.displayValue, snapshot.userStatePlaylistEntryActiveCount.displayValue, snapshot.userStatePlaylistEntryTombstoneCount.displayValue, snapshot.userStateQueueActiveCount.displayValue, snapshot.userStateQueueTombstoneCount.displayValue, snapshot.unresolvedEpisodeReferenceCount.displayValue))
        \(formatted("Network=%@, iCloud account=%@", snapshot.networkStatus, snapshot.accountStatus))
        \(formatted("Aggregate monitor attribution=unknown · errors=%@", snapshot.aggregateErrorCategories.isEmpty ? "none observed" : snapshot.aggregateErrorCategories.joined(separator: ", ")))
        \(formatted("Portable playback/history recovery: status=%@ · outbox=%@/%d · oldest age=%@ seconds · fallback writes=%d · retained incidents=%d · operations=%@ · stages=%@ · categories=%@ · first retry=%@ · last retry=%@ · drain attempted=%@ · succeeded=%@ · failed=%@ · last successful repair=%@ · latest drain failure=%@", snapshot.portableRecovery.status, snapshot.portableRecovery.outboxCount.map(String.init) ?? "unknown", snapshot.portableRecovery.outboxCapacity, snapshot.portableRecovery.oldestOutboxAgeSeconds.map(String.init) ?? "unknown", snapshot.portableRecovery.fallbackWriteCount, snapshot.portableRecovery.incidentCount, snapshot.portableRecovery.operationKinds.isEmpty ? "none observed" : snapshot.portableRecovery.operationKinds.joined(separator: ", "), snapshot.portableRecovery.failureStages.isEmpty ? "none observed" : snapshot.portableRecovery.failureStages.joined(separator: ", "), snapshot.portableRecovery.failureCategories.isEmpty ? "none observed" : snapshot.portableRecovery.failureCategories.joined(separator: ", "), snapshot.portableRecovery.firstRetryAt?.formatted(date: .numeric, time: .standard) ?? "n/a", snapshot.portableRecovery.lastRetryAt?.formatted(date: .numeric, time: .standard) ?? "n/a", snapshot.portableRecovery.lastDrainAttemptAt?.formatted(date: .numeric, time: .standard) ?? "n/a", snapshot.portableRecovery.lastDrainSucceededAt?.formatted(date: .numeric, time: .standard) ?? "n/a", snapshot.portableRecovery.lastDrainFailedAt?.formatted(date: .numeric, time: .standard) ?? "n/a", snapshot.portableRecovery.lastSuccessfulRepairAt?.formatted(date: .numeric, time: .standard) ?? "n/a", snapshot.portableRecovery.lastDrainFailureCategory ?? "none observed"))
        \(NSLocalizedString("CloudKit store events (local observation; not server record counts):", comment: "Heading for per-store CloudKit event information"))
        \(cloud)
        """
    }
}

private struct SupportDiagnosticStoreCounts: Sendable {
    let runtimeQueuePlaylistCount: SupportDiagnosticCount
    let runtimeQueueEntryCount: SupportDiagnosticCount
    let runtimeSubscriptionCount: SupportDiagnosticCount
    let legacySubscriptionCount: SupportDiagnosticCount
    let userStateSubscriptionActiveCount: SupportDiagnosticCount
    let userStateSubscriptionTombstoneCount: SupportDiagnosticCount
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
        let subscriptions = userStateContainer == nil
            ? unavailable
            : tombstoneCounts(
                active: FetchDescriptor<SubscriptionSync>(predicate: #Predicate { $0.isSubscribed }),
                tombstones: FetchDescriptor<SubscriptionSync>(predicate: #Predicate { !$0.isSubscribed })
            )
        let unresolved = cacheContainer.map {
            readCount(in: $0, FetchDescriptor<CachedMissingEpisodeReference>())
        } ?? .storeNotOpen
        return SupportDiagnosticStoreCounts(
            runtimeQueuePlaylistCount: runtimeQueue.0,
            runtimeQueueEntryCount: runtimeQueue.1,
            runtimeSubscriptionCount: count(in: ModelContext(runtimeContainer), FetchDescriptor<Podcast>()),
            legacySubscriptionCount: legacyContainer.map {
                count(in: ModelContext($0), FetchDescriptor<Podcast>())
            } ?? .storeNotOpen,
            userStateSubscriptionActiveCount: subscriptions.0,
            userStateSubscriptionTombstoneCount: subscriptions.1,
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
