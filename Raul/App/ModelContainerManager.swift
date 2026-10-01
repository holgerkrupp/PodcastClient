import SwiftData
import SwiftUI
import Synchronization
import CloudKitSyncMonitor
import CoreData
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class StoreCloudKitActivityMonitor: ObservableObject {
    enum StoreKind: String, Codable, CaseIterable, Sendable {
        case legacy
        case userState
        case other

        var title: String {
            switch self {
            case .legacy: return "Legacy Library"
            case .userState: return "User State"
            case .other: return "Other Store"
            }
        }
    }

    enum EventKind: String, Codable, Sendable {
        case setup
        case importEvent = "import"
        case export
    }

    enum ImportStatus: String, Codable, Sendable {
        case notObserved
        case syncing
        case complete
        case failed
    }

    struct StoreCounts: Codable, Hashable, Sendable {
        let legacyPlaylistEntryCount: Int?
        let userStateQueueEntryCount: Int?
    }

    struct ActiveEvent: Identifiable, Hashable, Sendable {
        let id: UUID
        let storeIdentifier: String
        let storeKind: StoreKind
        let type: EventKind
        let startedAt: Date
    }

    struct CompletedEvent: Identifiable, Hashable, Codable, Sendable {
        let id: UUID
        let storeIdentifier: String
        let storeKind: StoreKind
        let type: EventKind
        let startedAt: Date
        let endedAt: Date
        let succeeded: Bool
        let errorCode: Int?
        let countsBefore: StoreCounts?
        let countsAfter: StoreCounts?
    }

    struct Reconciliation: Codable, Hashable, Sendable {
        let at: Date
        let succeeded: Bool
        let summary: String
    }

    struct StoreDiagnostics: Identifiable, Hashable, Codable, Sendable {
        let storeKind: StoreKind
        let storeIdentifier: String?
        let isAttached: Bool
        let activeSetupCount: Int
        let activeImportCount: Int
        let activeExportCount: Int
        let lastImportStartedAt: Date?
        let lastImportEndedAt: Date?
        let lastSuccessfulImportAt: Date?
        let lastImportErrorCode: Int?
        let lastImportCountsBefore: StoreCounts?
        let lastImportCountsAfter: StoreCounts?
        let lastExportEndedAt: Date?
        let lastSuccessfulExportAt: Date?
        let lastExportErrorCode: Int?
        let lastReconciliation: Reconciliation?

        var id: String { storeKind.rawValue }

        var importStatus: ImportStatus {
            if activeImportCount > 0 { return .syncing }
            guard let lastImportEndedAt else { return .notObserved }
            if lastSuccessfulImportAt == lastImportEndedAt { return .complete }
            return .failed
        }
    }

    private struct EventPayload: Sendable {
        let id: UUID
        let storeIdentifier: String
        let type: EventKind
        let startDate: Date
        let endDate: Date?
        let succeeded: Bool
        let errorCode: Int?
    }

    static let shared = StoreCloudKitActivityMonitor()

    private static let historyKey = "storeSplit.cloudKitEventHistory.v1"
    private static let reconciliationKey = "storeSplit.cloudKitReconciliations.v1"

    @Published private(set) var activeEvents: [ActiveEvent] = []
    @Published private(set) var lastCompletedEvents: [CompletedEvent] = []
    @Published private(set) var storeDiagnostics: [StoreDiagnostics] = []
    @Published private(set) var latestCompletedImport: CompletedEvent?

    private var activeByID: [UUID: ActiveEvent] = [:]
    private var importCountsByID: [UUID: StoreCounts?] = [:]
    private var reconciliations: [StoreKind: Reconciliation] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        let defaults = UserDefaults(
            suiteName: ModelContainerManager.appGroupID
        ) ?? .standard
        lastCompletedEvents = defaults.data(forKey: Self.historyKey)
            .flatMap { try? JSONDecoder().decode([CompletedEvent].self, from: $0) }
            ?? []
        reconciliations = defaults.data(forKey: Self.reconciliationKey)
            .flatMap { try? JSONDecoder().decode([StoreKind: Reconciliation].self, from: $0) }
            ?? [:]
        latestCompletedImport = lastCompletedEvents.first { event in
            event.type == .importEvent
        }
        rebuildDiagnostics()
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let payload = Self.payload(from: notification) else { return }
            Task { @MainActor [weak self] in
                self?.handle(payload)
            }
        }
    }

    var isAnyStoreExporting: Bool {
        activeEvents.contains { $0.type == .export }
    }

    var activeExportEvents: [ActiveEvent] {
        activeEvents.filter { $0.type == .export }
    }

    func activeExportStatus(for storeKind: StoreKind) -> String {
        let events = activeExportEvents.filter { $0.storeKind == storeKind }
        guard events.isEmpty == false else { return "Idle" }
        let oldest = events.map(\.startedAt).min() ?? .now
        return "Active since "
            + oldest.formatted(date: .omitted, time: .shortened)
            + " (" + String(events.count) + ")"
    }

    func activeExportIdentifiers(for storeKind: StoreKind) -> [String] {
        activeExportEvents
            .filter { $0.storeKind == storeKind }
            .map { String($0.id.uuidString.prefix(8)) }
    }

    func diagnostics(for storeKind: StoreKind) -> StoreDiagnostics? {
        storeDiagnostics.first { $0.storeKind == storeKind }
    }

    func recordReconciliation(
        for storeKind: StoreKind,
        succeeded: Bool,
        summary: String
    ) {
        reconciliations[storeKind] = Reconciliation(
            at: .now,
            succeeded: succeeded,
            summary: summary
        )
        persistReconciliations()
        rebuildDiagnostics()
    }

    nonisolated private static func payload(from notification: Notification) -> EventPayload? {
        guard let event = notification.userInfo?[
            NSPersistentCloudKitContainer.eventNotificationUserInfoKey
        ] as? NSPersistentCloudKitContainer.Event else {
            return nil
        }
        return EventPayload(
            id: event.identifier,
            storeIdentifier: event.storeIdentifier,
            type: EventKind(event.type),
            startDate: event.startDate,
            endDate: event.endDate,
            succeeded: event.succeeded,
            errorCode: event.error.map { ($0 as NSError).code }
        )
    }

    private func handle(_ event: EventPayload) {

        let eventKind = event.type
        let storeKind = StoreKind(storeIdentifier: event.storeIdentifier)
        let id = event.id
        if let endedAt = event.endDate {
            activeByID.removeValue(forKey: id)
            let countsBefore = importCountsByID.removeValue(forKey: id) ?? nil
            let countsAfter = eventKind == .importEvent
                ? ModelContainerManager.shared.cloudKitStoreCounts(for: storeKind)
                : nil
            let completed = CompletedEvent(
                id: id,
                storeIdentifier: event.storeIdentifier,
                storeKind: storeKind,
                type: eventKind,
                startedAt: event.startDate,
                endedAt: endedAt,
                succeeded: event.succeeded,
                errorCode: event.errorCode,
                countsBefore: countsBefore,
                countsAfter: countsAfter
            )
            lastCompletedEvents = ([completed] + lastCompletedEvents).prefix(20).map { $0 }
            if eventKind == .importEvent {
                latestCompletedImport = completed
            }
            if let data = try? JSONEncoder().encode(lastCompletedEvents) {
                (UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard)
                    .set(data, forKey: Self.historyKey)
            }
            let errorCode = event.errorCode.map(String.init) ?? "none"
            let details = "store=" + storeKind.rawValue
                + ",type=" + eventKind.rawValue
                + ",duration_ms=" + String(
                    Int(endedAt.timeIntervalSince(event.startDate) * 1_000)
                )
                + ",succeeded=" + String(event.succeeded)
                + ",error_code=" + errorCode
            CrashBreadcrumbs.shared.record(
                "cloudkit_store_event_finished",
                details: details
            )
            if eventKind == .export {
                Task {
                    await StoreSplitWorkCoordinator.shared.resumeAfterCloudKitExport()
                }
            }
        } else {
            let active = ActiveEvent(
                id: id,
                storeIdentifier: event.storeIdentifier,
                storeKind: storeKind,
                type: eventKind,
                startedAt: event.startDate
            )
            activeByID[id] = active
            if eventKind == .importEvent {
                importCountsByID[id] = ModelContainerManager.shared
                    .cloudKitStoreCounts(for: storeKind)
            }
            CrashBreadcrumbs.shared.record(
                "cloudkit_store_event_started",
                details: "store=" + storeKind.rawValue + ",type=" + eventKind.rawValue
            )
        }
        activeEvents = activeByID.values.sorted { $0.startedAt < $1.startedAt }
        rebuildDiagnostics()
    }

    private func persistReconciliations() {
        guard let data = try? JSONEncoder().encode(reconciliations) else { return }
        (UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard)
            .set(data, forKey: Self.reconciliationKey)
    }

    private func rebuildDiagnostics() {
        storeDiagnostics = [StoreKind.legacy, StoreKind.userState].map { kind in
            let active = activeEvents.filter { $0.storeKind == kind }
            let lastImport = lastCompletedEvents.first {
                $0.storeKind == kind && $0.type == .importEvent
            }
            let activeImport = active.first { $0.type == .importEvent }
            let successfulImport = lastCompletedEvents.first {
                $0.storeKind == kind
                    && $0.type == .importEvent
                    && $0.succeeded
            }
            let lastExport = lastCompletedEvents.first {
                $0.storeKind == kind && $0.type == .export
            }
            let successfulExport = lastCompletedEvents.first {
                $0.storeKind == kind
                    && $0.type == .export
                    && $0.succeeded
            }
            return StoreDiagnostics(
                storeKind: kind,
                storeIdentifier: lastImport?.storeIdentifier
                    ?? active.first?.storeIdentifier,
                isAttached: isAttached(kind),
                activeSetupCount: active.filter { $0.type == .setup }.count,
                activeImportCount: active.filter { $0.type == .importEvent }.count,
                activeExportCount: active.filter { $0.type == .export }.count,
                lastImportStartedAt: activeImport?.startedAt ?? lastImport?.startedAt,
                lastImportEndedAt: lastImport?.endedAt,
                lastSuccessfulImportAt: successfulImport?.endedAt,
                lastImportErrorCode: lastImport?.succeeded == false
                    ? lastImport?.errorCode
                    : nil,
                lastImportCountsBefore: lastImport?.countsBefore,
                lastImportCountsAfter: lastImport?.countsAfter,
                lastExportEndedAt: lastExport?.endedAt,
                lastSuccessfulExportAt: successfulExport?.endedAt,
                lastExportErrorCode: lastExport?.succeeded == false
                    ? lastExport?.errorCode
                    : nil,
                lastReconciliation: reconciliations[kind]
            )
        }
    }

    private func isAttached(_ storeKind: StoreKind) -> Bool {
        switch storeKind {
        case .legacy: return StoreDevelopmentConfiguration.legacyCloudSyncEnabled
        case .userState: return StoreDevelopmentConfiguration.userStateCloudSyncEnabled
        case .other: return false
        }
    }
}

private extension StoreCloudKitActivityMonitor.EventKind {
    init(_ type: NSPersistentCloudKitContainer.EventType) {
        switch type {
        case .setup: self = .setup
        case .import: self = .importEvent
        case .export: self = .export
        @unknown default: self = .setup
        }
    }
}

private extension StoreCloudKitActivityMonitor.StoreKind {
    init(storeIdentifier: String) {
        let value = storeIdentifier.lowercased()
        if value.contains("shared") || value.contains("legacy") {
            self = .legacy
        } else if value.contains("userstate") || value.contains("user-state") {
            self = .userState
        } else {
            self = .other
        }
    }
}

@MainActor
class ModelContainerManager: ObservableObject {
    nonisolated static let appGroupID = "group.de.holgerkrupp.PodcastClient"

    @Published private(set) var preparedContainer: ModelContainer?
    /// Read-only migration/recovery source. This is deliberately separate from
    /// the model container injected into the application UI.
    @Published private(set) var preparedLegacyMigrationContainer: ModelContainer?
    @Published private(set) var preparedUserStateContainer: ModelContainer?
    @Published private(set) var preparedCacheContainer: ModelContainer?
    @Published private(set) var initializationError: String?
    @Published private(set) var userStateInitializationError: String?
    @Published private(set) var cacheInitializationError: String?
    @Published private(set) var migrationError: String?
    @Published private(set) var isInitializing = false
    @Published private(set) var isPreparingSplitStores = false
    enum RuntimeStoreReadiness: Equatable {
        case unopened
        case settling
        case ready
    }
    @Published private(set) var runtimeStoreReadiness: RuntimeStoreReadiness = .unopened
    @Published private(set) var isMigratingSplitStores = false
    @Published private(set) var requiresInitialCloudImport = false
    @Published private(set) var currentSplitStoreJobDescription: String?
    @Published private(set) var pendingSplitStoreWorkReason: String?
    @Published private(set) var lastSplitStoreReconcileSummary: String?
    @Published private(set) var lastSplitStoreReconcileAt: Date?
    // Slice migration telemetry (surfaced in the development settings view).
    @Published private(set) var migrationCurrentPhase: String?
    @Published private(set) var migrationCursorSummary: String?
    @Published private(set) var migrationProgressSummary: String?
    @Published private(set) var migrationFootprintSummary: String?
    @Published private(set) var migrationLastSliceError: String?
    @Published private(set) var migrationReadiness: StoreSplitMigrationReadiness = .unavailable
    @Published private(set) var migrationBlocker: String?
    @Published private(set) var migrationLastSliceStatus: StoreSplitSliceReport.Status?
    @Published private(set) var migrationLastSliceProcessed = 0
    @Published private(set) var migrationLastSliceResult = "No slice has run"
#if DEBUG
    @Published private(set) var developmentResetRequiresRelaunch = false
#endif
    private var preparationTask: Task<RuntimeContainerPreparation, Error>?
    private var splitStorePreparationTask: Task<SplitStoreContainers, Never>?
    /// Set while a `BGProcessingTask` is driving the migration. iOS has granted a
    /// time budget in that window, so the "app is backgrounded" stop condition
    /// must not apply.
    private var isRunningBackgroundProcessingTask = false
    private var didBuildCompatibilityProjection = false
    private var isBuildingCompatibilityProjection = false
    private var migrationTask: Task<StoreSplitMigrationExecutionResult, Never>?
    private var aiContentImportTask: Task<Void, Never>?
    private var userStateImportTask: Task<StoreSplitUserStateImportResult, Never>?
    private var missingFeedRefreshAttempts: [String: Date] = [:]
    private var lastMigrationCompletedAt: Date?
    private var lastAIContentImportAt: Date?
    private var lastUserStateImportAt: Date?
    private var exportWasInProgress = false
    private var exporterPressureEvents = 0
    private var optionalSplitStoreWritesSuspended = false
    private var legacyCloudImportReconcilePending = false
    private let minimumAIContentImportInterval: TimeInterval = 60 * 15
    private let minimumForegroundUserStateImportInterval: TimeInterval = 60 * 10
    private let splitStoreCoordinator = StoreSplitWorkCoordinator.shared
    nonisolated private static let lastMigrationCompletedAtKey =
        "storeSplitMigration.lastCompletedAt.v3"
    nonisolated private static let lastMigrationHadFailuresKey =
        "storeSplitMigration.lastRunHadFailures.v3"
    nonisolated private static let playlistRepairVersion = 2
    nonisolated private static let playlistRepairVersionKey =
        "storeSplit.playlistRepairVersion"
    nonisolated private static let cacheRecoveryVersion = 1
    nonisolated private static let cacheRecoveryVersionKey =
        "storeSplit.cacheOnlyLibraryRecoveryVersion"
    nonisolated private static let usedInMemoryProjectionKey =
        "storeSplit.usedInMemoryLibraryProjection"
    /// Migration version whose phases have all completed on this device.
    nonisolated private static let completedMigrationVersionKey =
        "storeSplit.completedMigrationVersion"
    /// One-time source-authoritative cleanup for rows that an older upsert-only
    /// backfill left active in UserState.
    // Increment this when a later release needs to run another authoritative
    // repair pass for every installation.
    nonisolated private static let authoritativeReconciliationVersion = 2
    nonisolated private static let authoritativeReconciliationVersionKey =
        "storeSplit.authoritativeReconciliationVersion"
    /// Spacing between migration slices while audio is playing. Long enough that
    /// the backfill stays a background trickle rather than a sustained load.
    /// Idle time between slices, so a long backfill stays a background trickle
    /// instead of a sustained CPU/disk load.
    nonisolated private static let sliceSpacingSeconds = 0.75
    /// Wall-clock budget for one foreground migration run.
    nonisolated private static let foregroundRunBudgetSeconds: TimeInterval = 25
    /// Wall-clock budget inside a `BGProcessingTask`.
    nonisolated private static let backgroundRunBudgetSeconds: TimeInterval = 120
    /// How long to wait before picking the backfill up after a budget stop.
    nonisolated private static let budgetExhaustedRetryDelay: TimeInterval = 180
    /// How long to wait before retrying after yielding to a CloudKit export.
    nonisolated private static let exportBackpressureRetryDelay: TimeInterval = 120

    enum StoreSplitMigrationExecutionResult: Equatable {
        case completed
        case progressed
        case deferred(String)
        case blocked(String)
        case failed(String)
    }

    var container: ModelContainer {
        guard let preparedContainer else {
            preconditionFailure("ModelContainer accessed before preparation completed")
        }
        return preparedContainer
    }
    
    nonisolated static let shared = ModelContainerManager()

    nonisolated private init() {
#if DEBUG
        Self.resetLocalStoreFilesIfRequested()
#endif
    }

    nonisolated static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    nonisolated static var sharedStoreURL: URL? {
        sharedContainerURL?.appendingPathComponent("SharedDatabase.sqlite")
    }

    nonisolated static var userStateStoreURL: URL? {
        sharedContainerURL?.appendingPathComponent("UserState.sqlite")
    }

    nonisolated static var cacheStoreURL: URL? {
        sharedContainerURL?.appendingPathComponent("PodcastCache.sqlite")
    }

    /// True only in the experimental cache-projection mode. Every shipping mode
    /// keeps the durable on-disk library store, so the runtime graph is never
    /// rebuilt from scratch and the UI is never empty at launch.
    nonisolated static var runtimeUsesCacheProjection: Bool {
        StoreDevelopmentConfiguration.runtimeStoreIsInMemoryProjection
    }

    /// The store the slice migration reads from. When the runtime graph is the
    /// on-disk library store, that store *is* the migration source — there is no
    /// second copy to open.
    private var legacyMigrationSourceContainer: ModelContainer? {
        if Self.runtimeUsesCacheProjection {
            return preparedLegacyMigrationContainer
        }
        return preparedContainer
    }

#if DEBUG
    func scheduleLocalSplitStoreReset() {
        UserDefaults.standard.set(
            true,
            forKey: StoreDevelopmentConfiguration.resetLocalSplitStoresOnNextLaunchKey
        )
        developmentResetRequiresRelaunch = true
        CrashBreadcrumbs.shared.record("store_split_local_reset_scheduled")
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    func scheduleAllLocalStoreReset() {
        let defaults = UserDefaults.standard
        defaults.set(
            true,
            forKey: StoreDevelopmentConfiguration.resetAllLocalStoresOnNextLaunchKey
        )
        defaults.removeObject(
            forKey: StoreDevelopmentConfiguration.resetLocalSplitStoresOnNextLaunchKey
        )
        developmentResetRequiresRelaunch = true
        CrashBreadcrumbs.shared.record("all_local_stores_reset_scheduled")
    }
    #endif

    nonisolated private static func resetLocalStoreFilesIfRequested() {
        let defaults = UserDefaults.standard
        let resetAllStores = defaults.bool(
            forKey: StoreDevelopmentConfiguration.resetAllLocalStoresOnNextLaunchKey
        )
        let resetSplitStores = defaults.bool(
            forKey: StoreDevelopmentConfiguration.resetLocalSplitStoresOnNextLaunchKey
        )
        guard resetAllStores || resetSplitStores else {
            return
        }

        let storeURLs = resetAllStores
            ? [sharedStoreURL, userStateStoreURL, cacheStoreURL]
            : [userStateStoreURL, cacheStoreURL]
        var failedPaths: [String] = []
        for storeURL in storeURLs.compactMap({ $0 }) {
            do {
                try removeSQLiteArtifacts(for: storeURL)
            } catch {
                failedPaths.append(storeURL.lastPathComponent)
            }
        }

        if failedPaths.isEmpty {
            defaults.removeObject(
                forKey: StoreDevelopmentConfiguration.resetLocalSplitStoresOnNextLaunchKey
            )
            defaults.removeObject(
                forKey: StoreDevelopmentConfiguration.resetAllLocalStoresOnNextLaunchKey
            )
            clearMigrationRunState()
            CrashBreadcrumbs.shared.record(
                resetAllStores
                    ? "all_local_stores_reset_completed"
                    : "store_split_local_reset_completed"
            )
        } else {
            CrashBreadcrumbs.shared.record(
                resetAllStores
                    ? "all_local_stores_reset_failed"
                    : "store_split_local_reset_failed",
                details: failedPaths.joined(separator: ",")
            )
        }
    }

    nonisolated private static func clearMigrationRunState() {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        defaults.removeObject(forKey: lastMigrationCompletedAtKey)
        defaults.removeObject(forKey: lastMigrationHadFailuresKey)
        defaults.removeObject(forKey: authoritativeReconciliationVersionKey)
    }

    nonisolated private static func sqliteArtifactURLs(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
    }

    nonisolated static func removeSQLiteArtifacts(for storeURL: URL) throws {
        for url in sqliteArtifactURLs(for: storeURL) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
#endif

    /// What opening the runtime store produces. `requiresInitialCloudImport` is
    /// decided from the same off-main pass, because it has to be read *before*
    /// the open creates the store file.
    struct RuntimeContainerPreparation: Sendable {
        let container: ModelContainer
        let requiresInitialCloudImport: Bool
    }

    /// Holds the open started by `startEagerContainerPreparation` until
    /// `prepareContainer` adopts it. Deliberately not main-actor state: the
    /// point is to start the open while the main thread is still busy.
    nonisolated private static let eagerPreparationTask =
        Mutex<Task<RuntimeContainerPreparation, Error>?>(nil)

    /// Starts opening the runtime store as soon as the process is up, rather
    /// than waiting for SwiftUI to render the launch view and run its `.task`.
    /// Opening the store is the long pole of launch and needs nothing from the
    /// UI, so it should overlap the first render instead of following it.
    ///
    /// The work must not be hopped through the main actor to get here: during
    /// launch the main thread is building the first frame, so a
    /// `Task { @MainActor }` would not run until after the render this is meant
    /// to overlap - measured as no improvement at all.
    ///
    /// Idempotent. `prepareContainer` adopts this task rather than opening the
    /// store a second time.
    nonisolated static func startEagerContainerPreparation() {
        eagerPreparationTask.withLock { slot in
            guard slot == nil else { return }
            slot = makeRuntimeContainerPreparationTask()
        }
    }

    nonisolated private static func takeEagerPreparationTask()
    -> Task<RuntimeContainerPreparation, Error>? {
        eagerPreparationTask.withLock { slot in
            defer { slot = nil }
            return slot
        }
    }

    /// The order inside this task is load-bearing and matches what used to run
    /// on the main actor: the rollout promotion first (it flips the live
    /// `newStoreReadsEnabled`), then the "is this a fresh install" check, which
    /// is only meaningful while the store file does not exist yet, then the
    /// open itself.
    nonisolated private static func makeRuntimeContainerPreparationTask()
    -> Task<RuntimeContainerPreparation, Error> {
        Task.detached(priority: .userInitiated) {
            // This runs before makeRuntimeContainer(), which is the earliest
            // point at which Core Data can resume a persisted CloudKit export.
            // A repeated unhealthy-launch sequence can therefore quarantine the
            // legacy mirror before the exporter is reopened.
            _ = StoreSplitLaunchHealth.beginLaunch()
            CrashBreadcrumbs.shared.record("model_container_initialization_started")
#if !DEBUG
            _ = Self.promoteRolloutForCompletedSplitStoreMigrationIfNeeded()
#endif
            let requiresInitialCloudImport =
                StoreDevelopmentConfiguration.legacyCloudSyncEnabled
                && (Self.sharedStoreURL.map {
                    !FileManager.default.fileExists(atPath: $0.path)
                } ?? false)
            return RuntimeContainerPreparation(
                container: try Self.makeRuntimeContainer(),
                requiresInitialCloudImport: requiresInitialCloudImport
            )
        }
    }

    func prepareContainer() async {
        guard preparedContainer == nil else { return }

        let task: Task<RuntimeContainerPreparation, Error>
        if let preparationTask {
            task = preparationTask
        } else {
            isInitializing = true
            initializationError = nil
            let newTask = Self.takeEagerPreparationTask()
                ?? Self.makeRuntimeContainerPreparationTask()
            preparationTask = newTask
            task = newTask
        }

        do {
            let preparation = try await task.value
            let preparedContainer = preparation.container
            requiresInitialCloudImport = preparation.requiresInitialCloudImport
            if self.preparedContainer == nil {
                self.preparedContainer = preparedContainer
                self.runtimeStoreReadiness = .settling
                CrashBreadcrumbs.shared.record("model_container_initialization_completed")
            }
            if Self.runtimeUsesCacheProjection {
                // The in-memory graph is empty until it has been rebuilt, so the
                // projection is on the critical path in that mode only.
                await prepareSplitStores()
            } else {
                // The on-disk library store is already complete. Opening the
                // split stores and applying synchronized state happens off the
                // launch path so the UI renders the user's real data at once.
                Task { [weak self] in
                    await self?.prepareSplitStores()
                }
            }
        } catch {
            if initializationError == nil {
                initializationError = error.localizedDescription
                CrashBreadcrumbs.shared.record(
                    "model_container_initialization_failed",
                    details: error.localizedDescription
                )
            }
        }

        preparationTask = nil
        isInitializing = false
    }

    func prepareSplitStores() async {
        guard preparedContainer != nil else {
            migrationReadiness = .unavailable
            migrationBlocker = "Runtime library store is not ready"
            return
        }
#if DEBUG
        guard developmentResetRequiresRelaunch == false else {
            recordMigrationBlocker("Development reset requires a relaunch")
            return
        }
#endif
        guard StoreDevelopmentConfiguration.splitStoresEnabled else {
            migrationReadiness = .blocked
            migrationBlocker = "Split-store work is disabled by the active configuration"
            CrashBreadcrumbs.shared.record(
                "store_split_container_initialization_skipped",
                details: "development_mode=legacy_only"
            )
            runtimeStoreReadiness = .ready
            return
        }
        migrationReadiness = .preparing
        migrationBlocker = nil
        guard preparedUserStateContainer == nil || preparedCacheContainer == nil else {
            await buildRuntimeGraphIfNeeded()
            updateMigrationReadiness()
            return
        }

        let task: Task<SplitStoreContainers, Never>
        if let splitStorePreparationTask {
            task = splitStorePreparationTask
        } else {
            isPreparingSplitStores = true
            userStateInitializationError = nil
            cacheInitializationError = nil
            CrashBreadcrumbs.shared.record("store_split_container_initialization_started")

            let needsUserStateContainer = preparedUserStateContainer == nil
            let needsCacheContainer = preparedCacheContainer == nil
            let newTask = Task.detached(priority: .utility) {
                SplitStoreContainers(
                    userState: needsUserStateContainer
                        ? Result { try Self.makeUserStateContainer() }
                        : nil,
                    cache: needsCacheContainer
                        ? Result { try Self.makeCacheContainer() }
                        : nil
                )
            }
            splitStorePreparationTask = newTask
            task = newTask
        }

        let result = await task.value
        if let userState = result.userState {
            apply(
                userState,
                to: \.preparedUserStateContainer,
                error: \.userStateInitializationError,
                storeName: "user_state"
            )
        }
        if let cache = result.cache {
            apply(
                cache,
                to: \.preparedCacheContainer,
                error: \.cacheInitializationError,
                storeName: "cache"
            )
        }

        splitStorePreparationTask = nil
        isPreparingSplitStores = false

        await buildRuntimeGraphIfNeeded()
        runtimeStoreReadiness = .ready
        updateMigrationReadiness()
        CrashBreadcrumbs.shared.record("runtime_store_ready")

        CrashBreadcrumbs.shared.record(
            "store_split_container_initialization_completed",
            details: "user_state=\(preparedUserStateContainer != nil),cache=\(preparedCacheContainer != nil)"
        )
    }

    /// Application queries wait here instead of racing CloudKit metadata setup
    /// immediately after the runtime container object is returned.
    func waitUntilApplicationQueriesReady() async {
        while runtimeStoreReadiness != .ready {
            guard Task.isCancelled == false else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Opens the runtime graph for callers that can arrive without the normal
    /// SwiftUI launch sequence, such as App Intents and notification actions.
    /// Those callers must not assume that `RaulApp` has already prepared the
    /// container or that the split stores have finished settling.
    func prepareContainerForExternalEntryPoint() async -> ModelContainer? {
        await prepareContainer()
        guard let container = preparedContainer else { return nil }

        if runtimeStoreReadiness != .ready {
            await prepareSplitStores()
        }

        guard runtimeStoreReadiness == .ready else { return nil }
        return container
    }

    /// Brings the runtime library graph up to date once the split stores are
    /// open. On disk that means a bounded, additive recovery of anything the
    /// cache holds but the durable store does not; in the experimental
    /// projection mode it means rebuilding the whole in-memory graph.
    private func buildRuntimeGraphIfNeeded() async {
        if Self.runtimeUsesCacheProjection {
            await buildCompatibilityProjectionIfNeeded()
        } else {
            await recoverCacheOnlyLibraryDataIfNeeded()
        }
    }

    /// A device that ran an earlier build in cache-projection mode wrote feed
    /// refreshes to `PodcastCache.sqlite` while its runtime graph lived in
    /// memory. Those podcasts and episodes are missing from the durable store,
    /// so copy back anything the on-disk graph does not already have.
    ///
    /// Only runs where it is needed. On a device that never ran the projection
    /// build the cache is a mirror of the durable store, so the pass could only
    /// ever insert rows the durable store deliberately no longer has — deleting
    /// a podcast or an episode leaves its cache rows behind. Feed data is
    /// rebuildable from RSS anyway, so skipping is cheap and resurrecting is not.
    @discardableResult
    private func recoverCacheOnlyLibraryDataIfNeeded(
        force: Bool = false
    ) async -> StoreSplitCompatibilityProjectionResult {
        let empty = StoreSplitCompatibilityProjectionResult()
        let defaults = UserDefaults.standard
        guard force || Self.deviceUsedInMemoryProjection,
              force || defaults.integer(forKey: Self.cacheRecoveryVersionKey)
                < Self.cacheRecoveryVersion,
              let runtimeContainer = preparedContainer,
              let cacheContainer = preparedCacheContainer,
              let userStateContainer = preparedUserStateContainer else {
            return empty
        }

        // Only feeds the user still actively subscribes to may be restored. An
        // unsubscribe or a deleted podcast writes a `SubscriptionSync` tombstone,
        // which is what keeps this pass from bringing them back.
        let recoverableFeedKeys = activeSubscriptionFeedKeys(userStateContainer)
        guard recoverableFeedKeys.isEmpty == false else { return empty }

        CrashBreadcrumbs.shared.record(
            "store_split_cache_recovery_started",
            details: "feeds=\(recoverableFeedKeys.count),forced=\(force)"
        )
        let result = await Task.detached(priority: .utility) {
            StoreSplitCompatibilityProjectionService.recoverMissingLibraryData(
                cacheContainer: cacheContainer,
                runtimeContainer: runtimeContainer,
                recoverableFeedKeys: recoverableFeedKeys
            )
        }.value

        if result.failed == 0 {
            defaults.set(Self.cacheRecoveryVersion, forKey: Self.cacheRecoveryVersionKey)
        }
        CrashBreadcrumbs.shared.record(
            "store_split_cache_recovery_completed",
            details: "podcasts=\(result.podcasts),episodes=\(result.episodes),failed=\(result.failed)"
        )

        // Anything recovered here has no user state attached yet, and a device
        // returning from projection mode may also be missing playlist rows.
        // One reconcile right after recovery restores both.
        if result.podcasts > 0 || result.episodes > 0 {
            _ = await performSplitStoreReconcile(
                authoritativePlaylists: false,
                force: true,
                refreshMissingFeeds: false,
                reason: "cache_recovery"
            )
        }
        return result
    }

    /// Normalized feed keys whose newest `SubscriptionSync` record is an active
    /// subscription. Tombstoned and unsubscribed feeds are excluded.
    private func activeSubscriptionFeedKeys(
        _ userStateContainer: ModelContainer
    ) -> Set<String> {
        let context = ModelContext(userStateContainer)
        let records = ((try? context.fetch(
            FetchDescriptor<SubscriptionSync>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )) ?? [])
        var newestByFeed: [String: Bool] = [:]
        for record in records {
            let key = URL(string: record.feedURL)
                .map(PodcastFeedIdentity.normalizedFeedURLString)
                ?? record.feedURL
            guard newestByFeed[key] == nil else { continue }
            newestByFeed[key] = record.isSubscribed && record.unsubscribedAt == nil
        }
        return Set(newestByFeed.filter { $0.value }.keys)
    }

    /// Whether the current migration version still has phases to run on this
    /// device. Cheap enough to call from the background-transition path: it reads
    /// one integer instead of opening the cache store.
    nonisolated static var hasPendingMigrationWork: Bool {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        return defaults.integer(forKey: completedMigrationVersionKey)
            != StoreSplitMigrationService.migrationVersion
    }

    /// Whether the one-time cleanup that makes the legacy source authoritative
    /// has run. This remains separate from the paged migration version so a
    /// previously completed backfill can still repair destination-only rows.
    nonisolated static var hasPendingLegacyAuthoritativeReconciliationWork: Bool {
        guard StoreSplitReleasePhase.current == .dualSyncBackfill else {
            return false
        }
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        return defaults.integer(forKey: authoritativeReconciliationVersionKey)
            != authoritativeReconciliationVersion
    }

    /// Whether this install has ever rendered from the in-memory cache
    /// projection. Set by the projection itself, so a device that only ever used
    /// the durable store never runs the recovery pass.
    nonisolated static var deviceUsedInMemoryProjection: Bool {
        UserDefaults.standard.bool(forKey: usedInMemoryProjectionKey)
    }

    private func buildCompatibilityProjectionIfNeeded() async {
        guard Self.runtimeUsesCacheProjection,
              didBuildCompatibilityProjection == false,
              isBuildingCompatibilityProjection == false,
              let runtimeContainer = preparedContainer,
              let cacheContainer = preparedCacheContainer else {
            return
        }
        isBuildingCompatibilityProjection = true
        defer { isBuildingCompatibilityProjection = false }
        // Record that this install has rendered from the in-memory projection, so
        // a later durable-store launch knows the cache may hold feed data the
        // durable store never saw.
        UserDefaults.standard.set(true, forKey: Self.usedInMemoryProjectionKey)

        await prepareLegacyMigrationSourceIfNeeded(cacheContainer: cacheContainer)
        if let source = preparedLegacyMigrationContainer {
            let playlistFeeds = preparedUserStateContainer.map(
                playlistRecoveryFeedURLs
            ) ?? []
            _ = await Task.detached(priority: .utility) {
                let priorityCount = StoreSplitFeedCacheWriter.bootstrapPriorityFeeds(
                    playlistFeeds,
                    legacyContainer: source,
                    cacheContainer: cacheContainer,
                    limit: 50
                )
                StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
                    legacyContainer: source,
                    cacheContainer: cacheContainer,
                    limit: 200
                )
                return priorityCount
            }.value
        }
        let projection = await Task.detached(priority: .userInitiated) {
            StoreSplitCompatibilityProjectionService.rebuild(
                cacheContainer: cacheContainer,
                runtimeContainer: runtimeContainer
            )
        }.value
        didBuildCompatibilityProjection = projection.failed == 0
        CrashBreadcrumbs.shared.record(
            "store_split_compatibility_projection_completed",
            details: "podcasts=\(projection.podcasts),episodes=\(projection.episodes),failed=\(projection.failed)"
        )

        if let userStateContainer = preparedUserStateContainer {
            _ = await StoreSplitUserStateImporter.apply(
                legacyContainer: runtimeContainer,
                userStateContainer: userStateContainer,
                authoritativePlaylists: true,
                projectListeningHistoryToLegacy: true,
                episodeStateProjectionRecencyCutoff: StoreDevelopmentConfiguration
                    .episodeStateProjectionRecencyCutoff
            )
            await PlaySessionTrackerActor(
                modelContainer: runtimeContainer
            ).rebuildListeningStats()
        }
    }

    /// Reads only compact UserState rows and returns the feeds whose episodes
    /// must be present before the first playlist frame is projected. Rows are
    /// newest-first so a tombstone suppresses an older duplicate delivery.
    private func playlistRecoveryFeedURLs(
        _ userStateContainer: ModelContainer
    ) -> [URL] {
        let context = ModelContext(userStateContainer)
        var queueDescriptor = FetchDescriptor<QueueEntrySync>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        queueDescriptor.fetchLimit = 500
        var playlistDescriptor = FetchDescriptor<PlaylistEntrySync>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        playlistDescriptor.fetchLimit = 1_500

        var seenRecordIDs = Set<String>()
        var seenFeedKeys = Set<String>()
        var result: [URL] = []
        let rows: [(id: String, feedURL: String, isDeleted: Bool, deletedAt: Date?)] =
            ((try? context.fetch(queueDescriptor)) ?? []).map {
                ($0.id, $0.feedURL, $0.isDeleted, $0.deletedAt)
            } + ((try? context.fetch(playlistDescriptor)) ?? []).map {
                ($0.id, $0.feedURL, $0.isDeleted, $0.deletedAt)
            }
        for row in rows {
            guard seenRecordIDs.insert(row.id).inserted,
                  row.isDeleted == false,
                  row.deletedAt == nil,
                  let feed = URL(string: row.feedURL) else { continue }
            let key = PodcastFeedIdentity.normalizedFeedURLString(feed)
            guard seenFeedKeys.insert(key).inserted else { continue }
            result.append(feed)
            if result.count == 50 { break }
        }
        return result
    }

    private func prepareLegacyMigrationSourceIfNeeded(
        cacheContainer: ModelContainer
    ) async {
        guard preparedLegacyMigrationContainer == nil,
              let sourceURL = Self.sharedStoreURL,
              FileManager.default.fileExists(atPath: sourceURL.path),
              StoreSplitMigrationService.isMigrationVerified(
                  cacheContainer: cacheContainer
              ) == false else {
            return
        }
        do {
            let source = try await Task.detached(priority: .utility) {
                try Self.makeLegacyContainer(allowsSave: false)
            }.value
            preparedLegacyMigrationContainer = source
            CrashBreadcrumbs.shared.record("store_split_legacy_migration_source_ready")
        } catch {
            migrationError = error.localizedDescription
            CrashBreadcrumbs.shared.record(
                "store_split_legacy_migration_source_failed",
                details: error.localizedDescription
            )
        }
    }

    /// Queues the bounded backfill on the shared work coordinator. Safe to call
    /// repeatedly: the coordinator coalesces requests and the slice engine
    /// resumes from its persisted cursor.
    func scheduleStoreSplitMigrationIfNeeded() async {
#if DEBUG
        guard developmentResetRequiresRelaunch == false else {
            recordMigrationBlocker("Development reset requires a relaunch")
            return
        }
#endif
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            migrationError = nil
            currentSplitStoreJobDescription = nil
            pendingSplitStoreWorkReason = "paused for stability"
            migrationReadiness = .blocked
            migrationBlocker = "Paused by the migration safety switch"
            return
        }
        guard StoreDevelopmentConfiguration.splitStoresEnabled else {
            pendingSplitStoreWorkReason = "split-store work disabled"
            migrationReadiness = .blocked
            migrationBlocker = "Split-store work is disabled by the active configuration"
            return
        }
        // Foreground re-entry and BGProcessing can reach this method before the
        // launch task has finished opening the stores. Preparation is coalesced,
        // so awaiting it here turns “not prepared yet” into a real retryable
        // state instead of the old silent no-op.
        if preparedContainer == nil {
            await prepareContainer()
        }
        await prepareSplitStores()
        guard preparedContainer != nil else {
            let reason = initializationError ?? "Runtime library store is not ready"
            recordMigrationBlocker(reason)
            scheduleMigrationRetry(after: Self.exportBackpressureRetryDelay)
            return
        }
        guard preparedUserStateContainer != nil,
              preparedCacheContainer != nil else {
            let reason = userStateInitializationError
                ?? cacheInitializationError
                ?? "Split-store preparation is pending"
            recordMigrationBlocker(reason)
            scheduleMigrationRetry(after: Self.exportBackpressureRetryDelay)
            return
        }
        guard Self.hasPendingMigrationWork
            || Self.hasPendingLegacyAuthoritativeReconciliationWork else {
            pendingSplitStoreWorkReason = nil
            migrationReadiness = .complete
            migrationBlocker = nil
            migrationProgressSummary = "All \(StoreSplitMigrationService.slicePhaseOrder.count) migration phases complete"
            return
        }
        migrationReadiness = .ready
        migrationBlocker = nil
        pendingSplitStoreWorkReason = "migration queued"
        await splitStoreCoordinator.scheduleForegroundMigration()
    }

    func runLaunchStoreMaintenance() async {
#if DEBUG
        guard developmentResetRequiresRelaunch == false else {
            recordMigrationBlocker("Development reset requires a relaunch")
            return
        }
#endif
        // Refresh the remote kill switch before any work decision so a published
        // pause/rollback takes effect this launch (heavy work) and is cached for
        // the next launch's read-mode resolution.
        await StoreSplitRemoteConfigStore.refresh()
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            lastSplitStoreReconcileSummary = "Paused for stability"
            pendingSplitStoreWorkReason = "paused for stability"
            currentSplitStoreJobDescription = nil
            recordMigrationBlocker("Paused by the migration safety switch")
            return
        }
        await prepareSplitStores()
        guard StoreDevelopmentConfiguration.splitStoresEnabled else {
            recordMigrationBlocker("Split-store work is disabled by the active configuration")
            return
        }
        let repairedLegacyPlaylists = await repairLegacyPlaylistsIfNeeded()
        if repairedLegacyPlaylists {
            _ = await performSplitStoreReconcile(
                authoritativePlaylists: false,
                force: true,
                refreshMissingFeeds: true,
                reason: "legacy_playlist_repair"
            )
        }
        if let userStateContainer = preparedUserStateContainer {
            await StoreSplitPlaylistPresenceStore.publish(
                modelContainer: userStateContainer
            )
        }
        // Runs in every configuration. The rollout only decides read authority —
        // in DEBUG the manual store-mode picker still wins — but it is also what
        // drives the bounded backfill, so skipping it in debug builds meant the
        // migration only ever advanced when someone pressed a button.
        await resolveStoreSplitRolloutIfNeeded()
        await prunePlayedPlaylistEntries()
        await splitStoreCoordinator.scheduleLaunchWork()
        await bootstrapFeedCacheIfNeeded(feedLimit: 15)
#if canImport(UIKit)
        // Arm the overnight charging pass now rather than waiting for a clean
        // background transition, which a force-quit never delivers.
        AppDelegate.scheduleStoreSplitMigrationProcessingIfNeeded()
#endif
    }

    /// A one-time additive repair for devices that completed rollout before all
    /// legacy playlist/queue rows had reached the split store. This runs before
    /// rollout resolution so repaired rows can be projected immediately, while
    /// the version-verification path independently decides whether a full
    /// migration backfill must resume.
    private func repairLegacyPlaylistsIfNeeded() async -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.playlistRepairVersionKey)
                < Self.playlistRepairVersion,
              let legacyContainer = legacyMigrationSourceContainer,
              let userStateContainer = preparedUserStateContainer else {
            return false
        }

        CrashBreadcrumbs.shared.record("store_split_playlist_repair_started")
        let result = await StoreSplitPlaylistRepairService.repair(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )
        let details = "playlists=\(result.playlistCount),entries=\(result.playlistEntryCount),queue=\(result.queueEntryCount),missing=\(result.missingRecordCount)"

        if result.isComplete {
            defaults.set(
                Self.playlistRepairVersion,
                forKey: Self.playlistRepairVersionKey
            )
            CrashBreadcrumbs.shared.record(
                "store_split_playlist_repair_completed",
                details: details
            )
            return result.playlistEntryCount > 0 || result.queueEntryCount > 0
        } else {
            CrashBreadcrumbs.shared.record(
                "store_split_playlist_repair_incomplete",
                details: details
            )
            return false
        }
    }

    /// Copy or upgrade a bounded number of legacy feed projections in the
    /// local-only cache store. Runs off-main and is idempotent; the per-feed cache
    /// schema version is the checkpoint. Runtime projection and repositories
    /// consume the cache directly after each committed page.
    func bootstrapFeedCacheIfNeeded(feedLimit: Int) async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false,
              StoreDevelopmentConfiguration.splitStoresEnabled,
              // Only the cache-projection mode needs a complete feed mirror. With
              // the durable library store authoritative this pass would rewrite
              // the whole library into a second SQLite file for nothing.
              Self.runtimeUsesCacheProjection else { return }
        await prepareSplitStores()
        guard let legacyContainer = legacyMigrationSourceContainer,
              let cacheContainer = preparedCacheContainer else { return }
        let copied = await Task.detached(priority: .utility) {
            StoreSplitFeedCacheWriter.bootstrapMissingFeeds(
                legacyContainer: legacyContainer,
                cacheContainer: cacheContainer,
                limit: feedLimit
            )
        }.value
        let defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
        defaults.set(Date(), forKey: "storeSplit.cacheBootstrapLastAt")
        defaults.set(copied, forKey: "storeSplit.cacheBootstrapLastCopied")
        if copied > 0 {
            CrashBreadcrumbs.shared.record(
                "store_split_feed_cache_bootstrap",
                details: "feeds=\(copied)"
            )
        }
    }

#if DEBUG
    func splitStoreCacheDevelopmentStatus() async throws -> StoreSplitCacheDevelopmentStatus {
        await prepareSplitStores()
        guard let cacheContainer = preparedCacheContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        let legacyContainer: ModelContainer
        if let prepared = legacyMigrationSourceContainer {
            legacyContainer = prepared
        } else {
            legacyContainer = try await Task.detached(priority: .utility) {
                try Self.makeLegacyContainer(allowsSave: false)
            }.value
        }
        return await Task.detached(priority: .utility) {
            StoreSplitCacheDevelopmentStatus.read(
                legacyContainer: legacyContainer,
                cacheContainer: cacheContainer
            )
        }.value
    }
#endif

    /// Entry point for the overnight `BGProcessingTask`. Prepares the split
    /// stores and advances the rollout (which runs the bounded migration for
    /// existing users). Runs in both DEBUG and release builds so the task can be
    /// exercised on a debug device.
    func runStoreSplitMigrationBackgroundPass() async {
        await withBackgroundProcessingWindow {
            await StoreSplitRemoteConfigStore.refresh()
            guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
                recordMigrationBlocker("Paused by the migration safety switch")
#if DEBUG
                StoreSplitMigrationDebugLog.record(
                    "background pass skipped",
                    details: "split-store work is paused"
                )
#endif
                return
            }
            await prepareSplitStores()
            guard StoreDevelopmentConfiguration.splitStoresEnabled else {
                recordMigrationBlocker("Split-store work is disabled by the active configuration")
#if DEBUG
                StoreSplitMigrationDebugLog.record(
                    "background pass skipped",
                    details: "split stores disabled in this mode"
                )
#endif
                return
            }
            await resolveStoreSplitRolloutIfNeeded()
            await bootstrapFeedCacheIfNeeded(feedLimit: 200)
        }
    }

    /// Advances the on-device rollout: classifies new vs existing installs, runs
    /// the bounded migration for existing users, and switches them to split-store
    /// reads once the migration has fully completed.
    func resolveStoreSplitRolloutIfNeeded() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            recordMigrationBlocker("Paused by the migration safety switch")
            return
        }
        switch StoreSplitRollout.state {
        case .newStoreReads:
            await resumeMigrationAfterVersionUpgradeIfNeeded()
        case .unclassified:
            await classifyStoreSplitRollout()
        case .migrating:
            await advanceStoreSplitRolloutAfterMigration()
        }
    }

    /// A device may already be marked `newStoreReads` by an older migration
    /// version. A version bump must still backfill newly required fields before
    /// relying on UserState; otherwise an update can temporarily hide local
    /// playlists that still exist in SharedDatabase.
    private func resumeMigrationAfterVersionUpgradeIfNeeded() async {
        await prepareSplitStores()
        guard let cacheContainer = preparedCacheContainer else {
            recordMigrationBlocker("Migration cache store is unavailable")
            return
        }
        guard StoreSplitMigrationService.isSliceMigrationComplete(
            cacheContainer: cacheContainer
        ) == false else {
            markMigrationCompleted(hadFailures: false)
            return
        }
        guard let legacyContainer = legacyMigrationSourceContainer else {
            if Self.sharedStoreURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                recordMigrationBlocker("Legacy migration source could not be opened")
                scheduleMigrationRetry(after: Self.exportBackpressureRetryDelay)
            } else {
                // A genuinely new install has nothing to backfill. Persist that
                // fact so the App Store background task does not wake forever for
                // a migration that can never have any rows.
                completeMigrationWithoutSource(cacheContainer)
            }
            return
        }
        guard legacyHasMigrationData(legacyContainer) else {
            completeMigrationWithoutSource(cacheContainer)
            return
        }
        StoreSplitRollout.set(.migrating)
        CrashBreadcrumbs.shared.record(
            "store_split_rollout_version_upgrade_backfill",
            details: "version=\(StoreSplitMigrationService.migrationVersion)"
        )
        await advanceStoreSplitRolloutAfterMigration()
    }

    /// Split-first classification: always read the cache/UserState projection;
    /// classify whether an existing local legacy source still needs backfill.
    private func classifyStoreSplitRollout() async {
        await prepareSplitStores()

        let legacyHasData = legacyMigrationSourceContainer
            .map(legacyHasMigrationData) ?? false
        let splitHasData = preparedUserStateContainer
            .map(splitUserStateHasData) ?? false
        // Migration is "not applicable" (treated as complete) when there is no
        // legacy data to back-fill from.
        // Completing every migration phase is what makes UserState safe to read
        // from. Lossless *verification* stays a separate, stricter gate for
        // physically retiring the legacy file: making reads wait for it left
        // devices stuck behind a single unmigratable row forever.
        let migrationComplete = !legacyHasData || (preparedCacheContainer.map {
            StoreSplitMigrationService.isSliceMigrationComplete(cacheContainer: $0)
        } ?? false)

        // Prefer split reads whenever it is safe: the split store has data and
        // either this device's legacy data is fully migrated or there is none.
        if splitHasData && migrationComplete {
            StoreSplitRollout.set(.newStoreReads)
            if let cacheContainer = preparedCacheContainer, legacyHasData == false {
                completeMigrationWithoutSource(cacheContainer)
            } else {
                markMigrationCompleted(hadFailures: false)
            }
            CrashBreadcrumbs.shared.record(
                "store_split_rollout_classified",
                details: "split_first,legacy=\(legacyHasData)"
            )
            return
        }

        // Split store empty or not yet backfilled: keep projected reads active
        // and migrate, but only if the local source actually has data.
        if legacyHasData {
            StoreSplitRollout.set(.migrating)
            CrashBreadcrumbs.shared.record(
                "store_split_rollout_classified",
                details: "migration_source_present,split_has_data=\(splitHasData)"
            )
            await advanceStoreSplitRolloutAfterMigration()
            return
        }

        // Nothing locally in either store: give CloudKit a few launches to
        // deliver data before committing a brand-new install to split reads.
        let importSettled = cloudKitLegacyImportSettled()
        let exhaustedGrace = StoreSplitRollout.incrementUnclassifiedLaunches()
            >= StoreSplitRollout.maxUnclassifiedLaunches
        if StoreDevelopmentConfiguration.legacyCloudSyncEnabled == false
            || importSettled
            || exhaustedGrace {
            StoreSplitRollout.set(.newStoreReads)
            if let cacheContainer = preparedCacheContainer {
                completeMigrationWithoutSource(cacheContainer)
            } else {
                recordMigrationBlocker("Migration cache store is unavailable")
            }
            CrashBreadcrumbs.shared.record(
                "store_split_rollout_classified",
                details: "new,import_settled=\(importSettled),grace_exhausted=\(exhaustedGrace)"
            )
        }
    }

    private func advanceStoreSplitRolloutAfterMigration() async {
        await prepareSplitStores()
        guard let cacheContainer = preparedCacheContainer else {
            recordMigrationBlocker("Migration cache store is unavailable")
            return
        }
        if StoreSplitMigrationService.isSliceMigrationComplete(
            cacheContainer: cacheContainer
        ) == false {
            _ = await runMigrationSliceLoop()
        } else if StoreSplitMigrationService.isMigrationVerified(
            cacheContainer: cacheContainer
        ) == false,
                  let legacyContainer = legacyMigrationSourceContainer,
                  let userStateContainer = preparedUserStateContainer {
            _ = StoreSplitMigrationVerifier.verify(
                legacyContainer: legacyContainer,
                userStateContainer: userStateContainer,
                cacheContainer: cacheContainer
            )
        }
        // Verification above is recorded for the cleanup gate and telemetry; the
        // read cutover only requires every phase to have completed.
        guard let cacheContainer = preparedCacheContainer,
              StoreSplitMigrationService.isSliceMigrationComplete(
                  cacheContainer: cacheContainer
              ) else {
            recordMigrationBlocker("Migration did not reach a completed checkpoint")
            return
        }
        StoreSplitRollout.set(.newStoreReads)
        CrashBreadcrumbs.shared.record(
            "store_split_rollout_migration_complete",
            details: "verified=\(StoreSplitMigrationService.isMigrationVerified(cacheContainer: cacheContainer))"
        )
    }

    /// A legacy store can contain portable settings, an empty custom playlist,
    /// or listening summaries without a current subscription. Treat every
    /// independently migratable root as evidence; podcast count alone is not a
    /// lossless upgrade classifier.
    private func legacyHasMigrationData(_ container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        func hasAny<Model: PersistentModel>(_ type: Model.Type) -> Bool {
            ((try? context.fetchCount(FetchDescriptor<Model>())) ?? 0) > 0
        }
        return hasAny(Podcast.self)
            || hasAny(Playlist.self)
            || hasAny(PodcastSettings.self)
            || hasAny(PlaySession.self)
            || hasAny(PlaySessionSummary.self)
    }

    /// Whether the synced user-state store holds any user-owned data — meaning it
    /// was migrated here previously or delivered by CloudKit from another device.
    private func splitUserStateHasData(_ container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        func hasAny<Model: PersistentModel>(_ type: Model.Type) -> Bool {
            ((try? context.fetchCount(FetchDescriptor<Model>())) ?? 0) > 0
        }
        return hasAny(SubscriptionSync.self)
            || hasAny(EpisodeStateSync.self)
            || hasAny(PlaylistSync.self)
            || hasAny(PlaylistEntrySync.self)
            || hasAny(QueueEntrySync.self)
            || hasAny(BookmarkSync.self)
            || hasAny(PodcastPreferenceSync.self)
            || hasAny(ListeningHistorySync.self)
            || hasAny(ListeningBaselineSync.self)
    }

    private func cloudKitLegacyImportSettled() -> Bool {
        guard StoreDevelopmentConfiguration.legacyCloudSyncEnabled else { return true }
        if case .succeeded = SyncMonitor.default.importState { return true }
        return false
    }

    /// Promotes devices that already finished the current split-store migration
    /// before the launch-time store mode is frozen. This covers users upgrading
    /// from a build that created/backfilled the split stores while still reading
    /// the legacy graph.
    @discardableResult
    nonisolated static func promoteRolloutForCompletedSplitStoreMigrationIfNeeded(
        cacheContainer providedCacheContainer: ModelContainer? = nil
    ) -> Bool {
        guard StoreSplitRollout.state != .newStoreReads else {
            return false
        }

        let cacheContainer: ModelContainer
        if let providedCacheContainer {
            cacheContainer = providedCacheContainer
        } else {
            do {
                cacheContainer = try makeCacheContainer()
            } catch {
                CrashBreadcrumbs.shared.record(
                    "store_split_rollout_preflight_failed",
                    details: error.localizedDescription
                )
                return false
            }
        }

        guard StoreSplitMigrationService.isSliceMigrationComplete(
            cacheContainer: cacheContainer
        ) else {
            return false
        }

        StoreSplitRollout.set(.newStoreReads)
        CrashBreadcrumbs.shared.record("store_split_rollout_preflight_promoted")
        return true
    }

#if DEBUG
    /// Runs the rollout resolution on demand from the development settings so the
    /// automatic release-build behaviour can be exercised on a debug device.
    func resolveStoreSplitRolloutForDevelopment() async {
        await resolveStoreSplitRolloutIfNeeded()
    }

    func resetStoreSplitRolloutForDevelopment() {
        StoreSplitRollout.resetForDevelopment()
    }

    var storeSplitRolloutStateDescription: String {
        StoreSplitRollout.state.rawValue
    }
#endif

    func pauseSplitStoreWorkForBackground() {
        // Everything stops on backgrounding. Letting the backfill continue on the
        // audio session's process time looked attractive, but the loop it kept
        // alive ran at ~98% CPU for hours and the process was killed by the CPU
        // limit. Background progress belongs to the metered `BGProcessingTask`,
        // which has a budget and an expiration handler.
        migrationTask?.cancel()
        userStateImportTask?.cancel()
        aiContentImportTask?.cancel()
        Task {
            await splitStoreCoordinator.pauseForBackground()
        }
        pendingSplitStoreWorkReason = "paused while app is in background"
        CrashBreadcrumbs.shared.record("store_split_work_background_cancel_requested")
    }

    /// Whether heavy split-store work may run given where the app currently is.
    /// Backgrounded without playback means the process can be suspended at any
    /// moment — and is metered against the 80%-of-60s background CPU limit — so
    /// queued work waits for the foreground instead of spending the process's
    /// budget where nobody is watching.
    ///
    /// A `BGProcessingTask` is the exception: the app is backgrounded but iOS has
    /// granted an explicit time budget and will call the expiration handler
    /// before reclaiming it. Without this the overnight pass would break out of
    /// the loop on its very first check and do nothing at all.
    var heavyStoreWorkMayRunInCurrentAppState: Bool {
        if isRunningBackgroundProcessingTask { return true }
#if canImport(UIKit)
        return UIApplication.shared.applicationState != .background
#else
        return true
#endif
    }

    /// Ordinary model writes are not allowed to begin after the app has entered
    /// the background. A granted BGProcessingTask is the only background escape
    /// hatch; recovery snapshots remain available through Player's defaults
    /// cache and do not use this gate.
    var mayStartOrdinaryStoreWrite: Bool {
        heavyStoreWorkMayRunInCurrentAppState
    }

    /// Admission control for writes that create CloudKit persistent-history
    /// work. Recovery snapshots deliberately do not use this gate.
    var mayStartCloudKitBackedStoreWrite: Bool {
        guard mayStartOrdinaryStoreWrite,
              optionalSplitStoreWritesSuspended == false else { return false }
        return cloudKitExportInProgress() == false
    }

    var isCloudKitExportInProgress: Bool {
        cloudKitExportInProgress()
    }

    /// Small, store-specific counters captured around Core Data CloudKit import
    /// events. They intentionally describe the rows that matter for diagnosing
    /// a stale queue rather than pretending to be exact CloudKit transfer
    /// progress.
    func cloudKitStoreCounts(
        for storeKind: StoreCloudKitActivityMonitor.StoreKind
    ) -> StoreCloudKitActivityMonitor.StoreCounts? {
        switch storeKind {
        case .legacy:
            guard let preparedContainer else { return nil }
            return StoreCloudKitActivityMonitor.StoreCounts(
                legacyPlaylistEntryCount: try? preparedContainer.mainContext
                    .fetchCount(FetchDescriptor<PlaylistEntry>()),
                userStateQueueEntryCount: nil
            )
        case .userState:
            guard let preparedUserStateContainer else { return nil }
            return StoreCloudKitActivityMonitor.StoreCounts(
                legacyPlaylistEntryCount: nil,
                userStateQueueEntryCount: try? preparedUserStateContainer.mainContext
                    .fetchCount(FetchDescriptor<QueueEntrySync>())
            )
        case .other:
            return nil
        }
    }

    func resumeSplitStoreWorkForForeground() {
        optionalSplitStoreWritesSuspended = false
        exporterPressureEvents = 0
        exportWasInProgress = false
        if legacyCloudImportReconcilePending {
            Task { [weak self] in
                await self?.reconcileLegacyStoreAfterCloudKitImport()
            }
        }
    }

    /// Whether the slice loop may keep going. Same rule as every other heavy
    /// split-store pass.
    private func migrationMayContinueInCurrentAppState() -> Bool {
        heavyStoreWorkMayRunInCurrentAppState
    }

    /// Runs `body` inside a declared background-processing window, so the slice
    /// loop knows it may keep working while the app is not in the foreground.
    func withBackgroundProcessingWindow(_ body: () async -> Void) async {
        isRunningBackgroundProcessingTask = true
        defer { isRunningBackgroundProcessingTask = false }
        await body()
    }

    func storeSplitMigrationStatus() -> StoreSplitMigrationStatus? {
        guard let cacheContainer = preparedCacheContainer,
              let userStateContainer = preparedUserStateContainer else {
            return StoreSplitMigrationDiagnostics.unavailableStatus(
                readiness: migrationReadiness,
                blocker: migrationBlocker ?? pendingSplitStoreWorkReason,
                isRunning: isMigratingSplitStores,
                lastSliceStatus: migrationLastSliceStatus,
                lastSliceProcessed: migrationLastSliceProcessed,
                lastSliceError: migrationLastSliceError,
                currentJob: currentSplitStoreJobDescription,
                pendingReason: pendingSplitStoreWorkReason
            )
        }
        return StoreSplitMigrationDiagnostics.migrationStatus(
            cacheContext: cacheContainer.mainContext,
            userStateContext: userStateContainer.mainContext,
            isRunning: isMigratingSplitStores,
            readiness: migrationReadiness,
            blocker: migrationBlocker,
            lastSliceStatus: migrationLastSliceStatus,
            lastSliceProcessed: migrationLastSliceProcessed,
            lastSliceError: migrationLastSliceError,
            currentJob: currentSplitStoreJobDescription,
            pendingReason: pendingSplitStoreWorkReason
        )
    }

#if DEBUG
    /// Runs the additive cache→durable-store recovery on demand, bypassing both
    /// the projection-mode marker and the one-shot version key. Still limited to
    /// actively subscribed feeds, so it cannot resurrect deleted podcasts.
    func recoverCacheOnlyLibraryDataForDevelopment() async
        -> StoreSplitCompatibilityProjectionResult {
        await prepareSplitStores()
        return await recoverCacheOnlyLibraryDataIfNeeded(force: true)
    }

    /// One-off recovery of listening history that exists only in the split
    /// stores. Rebuilds the hourly statistics afterwards so the Statistics screen
    /// reflects the restored sessions immediately.
    func recoverListeningHistoryForDevelopment() async throws
        -> StoreSplitUserStateImportResult {
        await prepareSplitStores()
        guard let legacyContainer = preparedContainer,
              let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        guard isMigratingSplitStores == false, userStateImportTask == nil else {
            throw StoreSplitDevelopmentResetError.workInProgress
        }

        StoreSplitMigrationDebugLog.record("listening history recovery started")
        let result = await StoreSplitUserStateImporter.applyListeningHistoryOnly(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )
        if result.listeningHistoryApplied > 0 {
            await PlaySessionTrackerActor(
                modelContainer: legacyContainer
            ).rebuildListeningStats()
        }
        StoreSplitMigrationDebugLog.record(
            "listening history recovery finished",
            details: "history=\(result.listeningHistoryApplied), failed=\(result.failed)"
        )
        return result
    }

    func importAvailableSplitStoreStateNow() async throws {
        await splitStoreCoordinator.runManualReconcile(authoritativePlaylists: true)
    }

    func runStoreSplitMigrationNowForDevelopment() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            recordMigrationBlocker("Paused by the migration safety switch")
            return
        }
        guard StoreDevelopmentConfiguration.legacyMigrationEnabled else {
            recordMigrationBlocker("Automatic migration is disabled by the active configuration")
            return
        }
        let defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
        defaults.removeObject(forKey: Self.lastMigrationCompletedAtKey)
        defaults.removeObject(forKey: Self.lastMigrationHadFailuresKey)
        lastMigrationCompletedAt = nil
        await splitStoreCoordinator.runManualMigration()
    }

    /// Runs exactly one bounded slice on demand. Explicit developer action, so it
    /// bypasses the auto-run gate but still respects the heavy-work pause.
    @discardableResult
    func runOneMigrationSliceForDevelopment() async -> StoreSplitMigrationSliceResult {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            recordMigrationBlocker("Paused by the migration safety switch")
            return .deferred("Paused by the migration safety switch")
        }
        guard StoreDevelopmentConfiguration.legacyMigrationEnabled else {
            let reason = "Automatic migration is disabled by the active configuration"
            recordMigrationBlocker(reason)
            return .deferred(reason)
        }
        if preparedContainer == nil {
            await prepareContainer()
        }
        await prepareSplitStores()
        guard let legacyContainer = legacyMigrationSourceContainer,
              let userStateContainer = preparedUserStateContainer,
              let cacheContainer = preparedCacheContainer else {
            let reason = migrationBlocker
                ?? userStateInitializationError
                ?? cacheInitializationError
                ?? initializationError
                ?? "Migration stores are not ready"
            recordMigrationBlocker(reason)
            scheduleMigrationRetry(after: Self.exportBackpressureRetryDelay)
            return .deferred(reason)
        }
        guard isMigratingSplitStores == false else {
            migrationLastSliceResult = "Blocked: a migration run is already in progress"
            migrationBlocker = "A migration run is already in progress"
            return .deferred("A migration run is already in progress")
        }
        guard cloudKitExportInProgress() == false else {
            let reason = "Waiting for CloudKit export to drain"
            recordMigrationBlocker(reason)
            scheduleMigrationRetry(after: Self.exportBackpressureRetryDelay)
            return .deferred(reason)
        }

        isMigratingSplitStores = true
        migrationError = nil
        let exportBefore = cloudKitExportInProgress()
        let report = await StoreSplitMigrationService.runSlice(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer,
            shouldContinue: { true }
        )
        applyMigrationSliceTelemetry(
            report,
            cloudKitExportInProgressBefore: exportBefore,
            exporterWaitDuration: 0
        )
        if report.status == .completed {
            markMigrationCompleted(hadFailures: report.error != nil)
        }
        isMigratingSplitStores = false
        updateMigrationReadiness()
        switch report.status {
        case .advanced:
            return .advanced(phase: report.phase, processed: report.processed)
        case .phaseCompleted:
            return .phaseCompleted(phase: report.phase, processed: report.processed)
        case .completed:
            return .allComplete
        case .failed:
            return .failed(report.error ?? "Migration slice failed")
        case .cancelled:
            return .deferred("Migration slice cancelled")
        }
    }
#endif

    func reconcileAvailableSplitStoreState(
        authoritativePlaylists: Bool = false,
        force: Bool = false,
        reason: String = "manual"
    ) async {
        _ = await performSplitStoreReconcile(
            authoritativePlaylists: authoritativePlaylists,
            force: force,
            refreshMissingFeeds: true,
            reason: reason
        )
    }

    enum SplitStoreReconcileOutcome: Equatable {
        case completed
        case deferredForPlayback
        case skipped
    }

    func performSplitStoreReconcile(
        authoritativePlaylists: Bool = false,
        force: Bool = false,
        refreshMissingFeeds: Bool = false,
        reason: String = "manual"
    ) async -> SplitStoreReconcileOutcome {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            lastSplitStoreReconcileSummary = "Paused for stability"
            pendingSplitStoreWorkReason = "paused for stability"
            currentSplitStoreJobDescription = nil
            return .skipped
        }
        guard cloudKitExportInProgress() == false else {
            pendingSplitStoreWorkReason = "waiting for CloudKit export to drain"
            return .skipped
        }
        // The importer walks the whole library. Running it while the app is
        // backgrounded without a granted budget is what the background CPU limit
        // kills the process for, so it waits for the foreground — every caller
        // re-arms on the next `.active` transition.
        guard heavyStoreWorkMayRunInCurrentAppState else {
            lastSplitStoreReconcileSummary = "Deferred until the app is in the foreground"
            pendingSplitStoreWorkReason = "waiting for the foreground"
            CrashBreadcrumbs.shared.record(
                "store_split_reconcile_deferred_for_background",
                details: "reason=\(reason)"
            )
            return .skipped
        }
        await prepareSplitStores()
        guard let legacyContainer = preparedContainer,
              let userStateContainer = preparedUserStateContainer,
              let cacheContainer = preparedCacheContainer else {
            return .skipped
        }
        guard shouldRunUserStateImport(
            force: force || authoritativePlaylists,
            reason: reason
        ) else {
            if Player.shared.isPlaying {
                lastSplitStoreReconcileSummary = "Deferred while playback was active"
                return .deferredForPlayback
            }
            lastSplitStoreReconcileSummary = "Skipped reconcile: \(reason)"
            return .skipped
        }
        let result = await applySyncedUserStateIfPossible(
            authoritativePlaylists: authoritativePlaylists,
            refreshMissingFeeds: refreshMissingFeeds
        )
        lastSplitStoreReconcileAt = .now
        lastSplitStoreReconcileSummary =
            "Reconciled subscriptions \(result.subscriptionsApplied), states \(result.episodeStatesApplied), playlists \(result.playlistsApplied), bookmarks \(result.bookmarksApplied), history \(result.listeningHistoryApplied)"
        // An import is the one moment when playlist entries authored elsewhere —
        // including records that predate the tombstone rules — land in the local
        // queue. Re-assert "a played episode is not a queue member" right after.
        await prunePlayedPlaylistEntries()
        if reason.contains("cloud_import") || authoritativePlaylists {
            let summary = lastSplitStoreReconcileSummary
                ?? "User State import completed"
            StoreCloudKitActivityMonitor.shared.recordReconciliation(
                for: .userState,
                succeeded: result.failed == 0 && result.interruptedByPlayback == false,
                summary: summary
            )
        }
        _ = legacyContainer
        _ = userStateContainer
        _ = cacheContainer
        return result.interruptedByPlayback ? .deferredForPlayback : .completed
    }

    /// Legacy is the visible queue authority during `dualSyncBackfill`. A
    /// successful import there does not need the UserState projector, but it
    /// does need the projections outside SwiftData refreshed so a dormant Mac
    /// converges without a relaunch.
    func reconcileLegacyStoreAfterCloudKitImport() async {
        guard StoreSplitReleasePhase.current == .dualSyncBackfill,
              StoreDevelopmentConfiguration.legacyCloudSyncEnabled else {
            return
        }
        guard heavyStoreWorkMayRunInCurrentAppState else {
            legacyCloudImportReconcilePending = true
            StoreCloudKitActivityMonitor.shared.recordReconciliation(
                for: .legacy,
                succeeded: false,
                summary: "Deferred until the app returns to the foreground"
            )
            return
        }
        guard let container = preparedContainer else {
            StoreCloudKitActivityMonitor.shared.recordReconciliation(
                for: .legacy,
                succeeded: false,
                summary: "Legacy store is not ready for playlist reconciliation"
            )
            return
        }

        let count = cloudKitStoreCounts(for: .legacy)?.legacyPlaylistEntryCount ?? 0
        legacyCloudImportReconcilePending = false
        CrashBreadcrumbs.shared.record(
            "legacy_cloudkit_import_reconcile_started",
            details: "playlist_entries=\(count)"
        )
        await PlayNextWidgetSync.refresh(using: container)
        WatchSyncCoordinator.refreshSoon(force: true)
        await Player.shared.reloadPlaybackStateFromPersistenceIfNeeded()
        StoreCloudKitActivityMonitor.shared.recordReconciliation(
            for: .legacy,
            succeeded: true,
            summary: "Legacy playlist projection refreshed (\(count) entries)"
        )
        CrashBreadcrumbs.shared.record(
            "legacy_cloudkit_import_reconcile_finished",
            details: "playlist_entries=\(count)"
        )
    }

    /// Removes finished episodes that are still queued, and tombstones them so the
    /// removal survives the next CloudKit round trip.
    func prunePlayedPlaylistEntries() async {
        guard let legacyContainer = legacyMigrationSourceContainer else { return }
        await PlayedEpisodePlaylistPruner(legacyContainer: legacyContainer).prune()
    }

#if DEBUG
    // MARK: - Incident recovery (development builds only)
    //
    // Deduplication, tombstone recovery and store export exist to repair a
    // library that a CloudKit re-attach merged. Keeping them out of shipping
    // builds is safe only while nothing a user can install is able to detach or
    // re-attach the legacy store — today that is true, because the attachment is
    // decided solely by `StoreSplitReleasePhase.current`, the remote kill switch
    // cannot reach it, and no released build has ever changed it. The moment the
    // cutover ships, a release build can detach; these have to ship with it.

    /// Recomputes the hourly buckets and every `PlaySessionSummary` from the raw
    /// `PlaySession` rows.
    ///
    /// This is the analytics rebuild to reach for after a bad merge, and since
    /// the synced store stopped carrying aggregates it is the only thing that
    /// recomputes them: summaries are now a purely local derivation.
    func rebuildAnalyticsFromRawSessions() async throws {
        guard let legacyContainer = legacyMigrationSourceContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        await PlaySessionTrackerActor(modelContainer: legacyContainer)
            .rebuildListeningStats()
    }

    /// Collapses duplicate podcasts/episodes and repairs playlist membership.
    /// `dryRun` reports what would change without writing.
    func deduplicateLibrary(dryRun: Bool) async throws -> LibraryDeduplicationReport {
        guard let legacyContainer = legacyMigrationSourceContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        return await LibraryDeduplicationService(legacyContainer: legacyContainer)
            .run(dryRun: dryRun)
    }

    /// Reports where the queue currently lives, across both stores, plus the
    /// rollout state that decides which of them the app reads.
    func playlistTombstoneReport() async throws -> [String] {
        await prepareSplitStores()
        guard let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        var lines = ["Rollout: \(storeSplitRolloutStateDescription)"]
        lines += await PlaylistTombstoneRecoveryService(
            userStateContainer: userStateContainer
        ).diagnosticsReport(legacyContainer: legacyMigrationSourceContainer)
        return lines
    }

    /// Clears playlist-entry tombstones stamped inside `window` and re-imports, so
    /// the queue is rebuilt from the UserState records that survived the removal.
    func restorePlaylistTombstones(
        deletedOnOrAfter cutoff: Date
    ) async throws -> PlaylistTombstoneRecoveryResult {
        await prepareSplitStores()
        guard let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        let result = await PlaylistTombstoneRecoveryService(
            userStateContainer: userStateContainer
        ).restoreTombstones(deletedOnOrAfter: cutoff)
        guard result.restoredEntryCount + result.restoredQueueEntryCount > 0 else {
            return result
        }
        try await importAvailableSplitStoreStateNow()
        return result
    }
#endif

#if DEBUG
    func republishLegacyStateToCloudKit(
        scope: StoreSplitDevelopmentRepublishScope
    ) async throws
        -> StoreSplitDevelopmentRepublishResult {
        await prepareSplitStores()
        guard let legacyContainer = legacyMigrationSourceContainer,
              let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        return await StoreSplitDevelopmentRepublishService.republish(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            scope: scope
        )
    }

    func rebuildListeningSummariesForDevelopment() async throws
        -> StoreSplitMigrationPhaseResult {
        await prepareSplitStores()
        guard let legacyContainer = legacyMigrationSourceContainer,
              let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        return await Task.detached(priority: .utility) {
            StoreSplitMigrationService.rebuildListeningSummaries(
                legacyContainer: legacyContainer,
                userStateContainer: userStateContainer
            )
        }.value
    }

    func splitStoreDevelopmentCounts() async throws
        -> StoreSplitDevelopmentStoreCounts {
        await prepareSplitStores()
        guard let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        return await Task.detached(priority: .utility) {
            StoreSplitDevelopmentStoreCounts.read(from: userStateContainer)
        }.value
    }

    func splitStoreDevelopmentObjectCounts() async throws
        -> [StoreSplitDevelopmentDatabaseCounts] {
        await prepareSplitStores()
        guard let legacyContainer = legacyMigrationSourceContainer ?? preparedContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        let userStateContainer = preparedUserStateContainer
        let cacheContainer = preparedCacheContainer
        return await Task.detached(priority: .utility) {
            StoreSplitDevelopmentDatabaseCounts.read(
                legacyContainer: legacyContainer,
                userStateContainer: userStateContainer,
                cacheContainer: cacheContainer
            )
        }.value
    }

    func resetSplitStoreDevelopmentData() async throws -> StoreSplitDevelopmentResetResult {
        guard isMigratingSplitStores == false,
              migrationTask == nil,
              aiContentImportTask == nil,
              userStateImportTask == nil else {
            throw StoreSplitDevelopmentResetError.workInProgress
        }

        await prepareSplitStores()
        guard let userStateContainer = preparedUserStateContainer,
              let cacheContainer = preparedCacheContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }

        developmentResetRequiresRelaunch = true
        do {
            let result = try await StoreSplitDevelopmentResetService.reset(
                userStateContainer: userStateContainer,
                cacheContainer: cacheContainer
            )
            let defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
            defaults.removeObject(forKey: Self.lastMigrationCompletedAtKey)
            defaults.removeObject(forKey: Self.lastMigrationHadFailuresKey)
            lastMigrationCompletedAt = nil
            lastAIContentImportAt = nil
            migrationError = nil
            CrashBreadcrumbs.shared.record(
                "store_split_development_reset_completed",
                details: "user_state=\(result.userStateRecordsDeleted),cache=\(result.cacheRecordsDeleted)"
            )
            return result
        } catch {
            developmentResetRequiresRelaunch = false
            CrashBreadcrumbs.shared.record(
                "store_split_development_reset_failed",
                details: error.localizedDescription
            )
            throw error
        }
    }
#endif

    func performSplitStoreMigrationIfNeeded() async -> StoreSplitMigrationExecutionResult {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            pendingSplitStoreWorkReason = "paused for stability"
            currentSplitStoreJobDescription = nil
            recordMigrationBlocker("Paused by the migration safety switch")
            return .blocked("Paused by the migration safety switch")
        }
        await prepareSplitStores()
        guard StoreDevelopmentConfiguration.legacyMigrationEnabled else {
            let reason = "Automatic migration is disabled by the active configuration"
            recordMigrationBlocker(reason)
            return .blocked(reason)
        }
        if Self.hasPendingMigrationWork {
            let migrationResult = await runMigrationSliceLoop()
            guard case .completed = migrationResult else {
                return migrationResult
            }
        }
        return await runLegacyAuthoritativeReconciliationIfNeeded()
    }

    /// During the dual-sync release, SharedDatabase is the authority. Run the
    /// deletion reconciliation once after the upsert migration, including for
    /// installs whose paged migration had already completed before this repair
    /// shipped.
    private func runLegacyAuthoritativeReconciliationIfNeeded()
        async -> StoreSplitMigrationExecutionResult {
        guard Self.hasPendingLegacyAuthoritativeReconciliationWork else {
            return .completed
        }
        guard StoreDevelopmentConfiguration.legacyMigrationEnabled,
              StoreSplitReleasePhase.current == .dualSyncBackfill else {
            return .completed
        }
        guard let userStateContainer = preparedUserStateContainer else {
            let reason = "Authoritative UserState reconciliation stores are not ready"
            recordMigrationBlocker(reason)
            scheduleMigrationRetry(after: Self.exportBackpressureRetryDelay)
            return .blocked(reason)
        }
        guard let legacyContainer = legacyMigrationSourceContainer else {
            // A genuinely new install has no SharedDatabase authority to
            // reconcile against. Do not delete UserState rows in that case;
            // simply consume this repair marker so the launch queue does not
            // wake forever. An existing but unreadable legacy file remains a
            // blocker and is retried below through the normal preparation path.
            let legacyStoreExists = Self.sharedStoreURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } == true
            guard legacyStoreExists == false else {
                let reason = "Authoritative UserState reconciliation source could not be opened"
                recordMigrationBlocker(reason)
                scheduleMigrationRetry(after: Self.exportBackpressureRetryDelay)
                return .blocked(reason)
            }
            let defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
            defaults.set(
                Self.authoritativeReconciliationVersion,
                forKey: Self.authoritativeReconciliationVersionKey
            )
            lastSplitStoreReconcileSummary = "Authoritative cleanup skipped: no legacy store"
            migrationReadiness = .complete
            migrationBlocker = nil
            pendingSplitStoreWorkReason = nil
            return .completed
        }
        guard cloudKitExportInProgress() == false else {
            pendingSplitStoreWorkReason = "waiting for CloudKit export to drain"
            scheduleMigrationRetry(after: Self.exportBackpressureRetryDelay)
            return .deferred("Waiting for CloudKit export to drain")
        }

        let result = await StoreSplitAuthoritativeReconciliationService.reconcile(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer
        )
        guard result.failed == 0 else {
            let reason = result.error ?? "Authoritative UserState reconciliation failed"
            recordMigrationBlocker(reason)
            scheduleMigrationRetry(after: Self.exportBackpressureRetryDelay)
            return .failed(reason)
        }

        let defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
        defaults.set(
            Self.authoritativeReconciliationVersion,
            forKey: Self.authoritativeReconciliationVersionKey
        )
        migrationReadiness = .complete
        migrationBlocker = nil
        migrationLastSliceError = nil
        lastSplitStoreReconcileAt = .now
        lastSplitStoreReconcileSummary = result.changedCount == 0
            ? "Authoritative cleanup found no destination-only rows"
            : "Authoritative reconciliation republished \(result.republishedCount) source rows and tombstoned/deleted \(result.cleanupCount) destination-only rows"
        pendingSplitStoreWorkReason = nil
        CrashBreadcrumbs.shared.record(
            "store_split_authoritative_reconciliation_completed",
            details: "republished=\(result.republishedCount),cleanup=\(result.cleanupCount),subscriptions_republished=\(result.subscriptionsRepublished),states_republished=\(result.episodeStatesRepublished),preferences_republished=\(result.preferencesRepublished),subscriptions=\(result.subscriptionsTombstoned),playlists=\(result.playlistsTombstoned),entries=\(result.playlistEntriesTombstoned),queue=\(result.queueEntriesTombstoned),bookmarks=\(result.bookmarksTombstoned),preferences=\(result.preferencesDeleted),states=\(result.episodeStatesDeleted),history_preserved=\(result.listeningHistoryPreserved)"
        )
        return .completed
    }

    /// Drives the slice engine one bounded slice at a time. Between slices it
    /// yields to cancellation, playback, the live pause switch, and CloudKit
    /// export backpressure so the migration never overwhelms memory or the
    /// outbound CloudKit queue.
    private func runMigrationSliceLoop() async -> StoreSplitMigrationExecutionResult {
        if let migrationTask {
            _ = await migrationTask.value
            return .deferred("A migration run is already in progress")
        }
        guard let legacyContainer = legacyMigrationSourceContainer,
              let userStateContainer = preparedUserStateContainer,
              let cacheContainer = preparedCacheContainer else {
            let reason = "Migration stores are not ready"
            recordMigrationBlocker(reason)
            scheduleMigrationRetry(after: Self.exportBackpressureRetryDelay)
            return .blocked(reason)
        }

        migrationError = nil
        migrationReadiness = .running
        migrationBlocker = nil
        isMigratingSplitStores = true
#if DEBUG
        StoreSplitMigrationDebugLog.record(
            "migration run started",
            details: storeSplitMigrationStatus().map {
                "phase \($0.completedPhaseCount)/\($0.totalPhaseCount), scanned \($0.scannedItemCount)"
            }
        )
#endif
        let task = Task { @MainActor in
#if DEBUG
            var stopReason = "loop exited"
#endif
            var executionResult: StoreSplitMigrationExecutionResult =
                .deferred("Migration yielded before completion")
            defer {
                isMigratingSplitStores = false
                migrationTask = nil
                updateMigrationReadiness()
#if DEBUG
                StoreSplitMigrationDebugLog.record(
                    "migration run ended",
                    details: stopReason
                )
#endif
            }
            var exportWaitCount = 0
            var sliceCount = 0
            let deadline = Date().addingTimeInterval(
                self.isRunningBackgroundProcessingTask
                    ? Self.backgroundRunBudgetSeconds
                    : Self.foregroundRunBudgetSeconds
            )
            sliceLoop: while true {
                if Task.isCancelled {
                    CrashBreadcrumbs.shared.record("store_split_migration_cancelled")
                    executionResult = .deferred("Migration cancelled")
#if DEBUG
                    stopReason = "cancelled"
#endif
                    break
                }
                if StoreDevelopmentConfiguration.migrationSlicePaused {
                    pendingSplitStoreWorkReason = "migration paused"
                    recordMigrationBlocker("Paused by the migration safety switch")
                    executionResult = .blocked("Paused by the migration safety switch")
#if DEBUG
                    stopReason = "paused by the migration switch"
#endif
                    break
                }
                // Hard wall-clock budget. A slice is bounded in rows, but the
                // number of slices is not, and an unbudgeted loop saturated a
                // CPU for hours and was killed by the 80%-over-60s limit.
                if Date() >= deadline {
                    pendingSplitStoreWorkReason = "budget reached, continuing later"
                    scheduleMigrationRetry(after: Self.budgetExhaustedRetryDelay)
                    executionResult = .progressed
#if DEBUG
                    stopReason = "run budget reached after \(sliceCount) slices"
#endif
                    break
                }
                if Player.shared.isPlaying {
                    pendingSplitStoreWorkReason = "waiting for playback to stop"
                    executionResult = .deferred("Waiting for playback to stop")
#if DEBUG
                    stopReason = "playback started"
#endif
                    break
                }
                if migrationMayContinueInCurrentAppState() == false {
                    pendingSplitStoreWorkReason = "paused while app is in background"
                    executionResult = .deferred("Waiting for the app to return to the foreground")
#if DEBUG
                    stopReason = "app backgrounded"
#endif
                    break
                }
                if cloudKitExportInProgress() {
                    exportWaitCount += 1
                    pendingSplitStoreWorkReason = "waiting for CloudKit export to drain"
                    // Cap the wait so a stuck export does not pin a background
                    // task. Yielding here is common during the first big upload,
                    // so schedule our own retry rather than waiting for the next
                    // launch — otherwise a busy export could stall the backfill
                    // until the user happens to relaunch.
                    if exportWaitCount > 20 {
                        scheduleMigrationRetry(after: Self.exportBackpressureRetryDelay)
                        executionResult = .deferred("Waiting for CloudKit export to drain")
#if DEBUG
                        stopReason = "yielded to CloudKit export, retrying in \(Int(Self.exportBackpressureRetryDelay))s"
#endif
                        break
                    }
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                exportWaitCount = 0

                let exportBefore = cloudKitExportInProgress()
                let report = await StoreSplitMigrationService.runSlice(
                    legacyContainer: legacyContainer,
                    userStateContainer: userStateContainer,
                    cacheContainer: cacheContainer,
                    shouldContinue: { Task.isCancelled == false }
                )
                applyMigrationSliceTelemetry(
                    report,
                    cloudKitExportInProgressBefore: exportBefore,
                    exporterWaitDuration: 0
                )

                switch report.status {
                case .completed:
                    markMigrationCompleted(hadFailures: report.error != nil)
                    executionResult = .completed
#if DEBUG
                    stopReason = "all phases complete"
#endif
                    break sliceLoop
                case .failed:
                    if let error = report.error {
                        migrationError = error
                    }
                    let reason = report.error ?? "Migration slice failed"
                    recordMigrationBlocker(reason)
                    scheduleMigrationRetry(after: Self.exportBackpressureRetryDelay)
                    executionResult = .failed(reason)
#if DEBUG
                    stopReason = "slice failed: \(report.error ?? "unknown error")"
#endif
                    break sliceLoop
                case .cancelled:
                    executionResult = .deferred("Migration slice cancelled")
#if DEBUG
                    stopReason = "slice cancelled"
#endif
                    break sliceLoop
                case .advanced, .phaseCompleted:
                    executionResult = .progressed
                    sliceCount += 1
                    await Task.yield()
                    // Deliberate idle time between slices. Without it the loop
                    // ran back-to-back SwiftData saves at ~98% CPU until iOS
                    // killed the process.
                    try? await Task.sleep(for: .seconds(Self.sliceSpacingSeconds))
                }
            }
            return executionResult
        }
        migrationTask = task
        return await task.value
    }

    /// Re-queues the backfill after a delay, so a run that yielded to CloudKit
    /// backpressure resumes on its own instead of waiting for the next launch.
    private func scheduleMigrationRetry(after delay: TimeInterval) {
        guard Self.hasPendingMigrationWork
            || Self.hasPendingLegacyAuthoritativeReconciliationWork else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard Task.isCancelled == false else { return }
            await self?.scheduleStoreSplitMigrationIfNeeded()
        }
    }

    private func recordMigrationBlocker(_ reason: String) {
        migrationReadiness = .blocked
        migrationBlocker = reason
        pendingSplitStoreWorkReason = reason
        migrationLastSliceResult = "Blocked: \(reason)"
        CrashBreadcrumbs.shared.record(
            "store_split_migration_blocked",
            details: reason
        )
    }

    private func completeMigrationWithoutSource(_ cacheContainer: ModelContainer) {
        StoreSplitMigrationService.markMigrationCompleteWithoutSource(
            cacheContainer: cacheContainer
        )
        markMigrationCompleted(hadFailures: false)
    }

    private func updateMigrationReadiness() {
        guard preparedCacheContainer != nil,
              preparedUserStateContainer != nil else {
            migrationReadiness = .unavailable
            if migrationBlocker == nil {
                migrationBlocker = "Waiting for migration stores"
            }
            return
        }
        if isMigratingSplitStores {
            migrationReadiness = .running
            return
        }
        if Self.hasPendingMigrationWork {
            if migrationReadiness != .blocked {
                migrationReadiness = .ready
            }
        } else {
            migrationReadiness = .complete
            migrationBlocker = nil
        }
    }

    private func cloudKitExportInProgress() -> Bool {
        guard StoreDevelopmentConfiguration.userStateCloudSyncEnabled
            || StoreDevelopmentConfiguration.legacyCloudSyncEnabled else {
            return false
        }
        // SyncMonitor.default.exportState is an aggregate UI summary and can
        // report UserState's completion while SharedDatabase is still exporting.
        // Scheduling decisions must use the store-aware Core Data event monitor.
        let inProgress = StoreCloudKitActivityMonitor.shared.isAnyStoreExporting
        if inProgress, exportWasInProgress == false {
            exporterPressureEvents += 1
            if exporterPressureEvents >= 3 {
                optionalSplitStoreWritesSuspended = true
                CrashBreadcrumbs.shared.record(
                    "cloudkit_export_pressure_safety_valve_closed",
                    details: "observations=\(exporterPressureEvents)"
                )
            }
        }
        exportWasInProgress = inProgress
        return inProgress
    }

    private func applyMigrationSliceTelemetry(
        _ report: StoreSplitSliceReport,
        cloudKitExportInProgressBefore: Bool = false,
        exporterWaitDuration: TimeInterval = 0
    ) {
        migrationCurrentPhase = report.phase
        migrationLastSliceStatus = report.status
        migrationLastSliceProcessed = report.processed
        migrationLastSliceResult = report.phase.map {
            "\($0): \(report.status.rawValue), \(report.processed) item(s)"
        } ?? report.status.rawValue
        migrationFootprintSummary =
            "\(MemoryFootprint.formatted(report.footprintAfter)) (\(report.footprintDeltaDescription))"
        let cloudKitExportInProgressAfter = cloudKitExportInProgress()
        StoreSplitMigrationDiagnostics.recordHealth(
            StoreSplitMigrationHealthRecord(
                operation: "migration_slice",
                appState: heavyStoreWorkMayRunInCurrentAppState
                    ? "foreground_or_granted_background_processing"
                    : "background",
                playbackActive: Player.shared.isPlaying,
                rowsScanned: report.processed,
                rowsMutated: report.mutations,
                modelContextSaveCount: report.saveCount,
                modelContextSaveDurationMilliseconds: Int(report.saveDuration * 1_000),
                targetStores: "UserState.sqlite,PodcastCache.sqlite",
                cloudKitExportInProgressBefore: cloudKitExportInProgressBefore,
                cloudKitExportInProgressAfter: cloudKitExportInProgressAfter,
                exporterWaitDurationMilliseconds: Int(exporterWaitDuration * 1_000),
                nextRetryAt: pendingSplitStoreWorkReason == nil
                    ? nil
                    : Date().addingTimeInterval(Self.exportBackpressureRetryDelay),
                recordedAt: .now
            )
        )
        if let error = report.error {
            migrationLastSliceError = error
        } else {
            migrationLastSliceError = nil
        }
        if let status = storeSplitMigrationStatus() {
            migrationProgressSummary =
                "Phase \(status.completedPhaseCount)/\(status.totalPhaseCount), scanned \(status.scannedItemCount)"
            if let phase = report.phase,
               let cursor = status.phases.first(where: { $0.id == phase })?.cursor {
                migrationCursorSummary = StoreSplitMigrationService.cursorDisplay(cursor)
            }
        }
#if DEBUG
        // Per-slice timing and footprint, so an expensive phase is identifiable
        // from the log instead of from a resource-exhaustion report.
        if let phase = report.phase {
            StoreSplitMigrationDebugLog.recordSlice(
                phase: phase,
                processed: report.processed,
                status: "\(report.status)",
                footprint: migrationFootprintSummary
            )
        }
        // Central hook: every path that runs a slice — the loop, the overnight
        // pass, and the single-slice development button — reports through here.
        if report.status == .phaseCompleted, let phase = report.phase {
            StoreSplitMigrationDebugLog.recordPhaseFinished(
                phase,
                progress: migrationProgressSummary
            )
        }
        if report.status == .failed {
            StoreSplitMigrationDebugLog.record(
                "slice failed",
                details: report.error ?? "unknown error"
            )
        }
#endif
    }

    private func markMigrationCompleted(hadFailures: Bool) {
        let defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
        let completedAt = Date()
        lastMigrationCompletedAt = completedAt
        defaults.set(completedAt, forKey: Self.lastMigrationCompletedAtKey)
        defaults.set(hadFailures, forKey: Self.lastMigrationHadFailuresKey)
        StoreSplitMigrationDiagnostics.recordMigrationRun(at: completedAt)
        if let cacheContainer = preparedCacheContainer {
            let cacheContext = ModelContext(cacheContainer)
            StoreSplitMigrationDiagnostics.recordFailedItems(
                StoreSplitMigrationService.failedItemKeysForDiagnostics(from: cacheContext)
            )
        }
        // Lets the background-task scheduler decide whether to re-arm without
        // opening a container on the app's background-transition path.
        defaults.set(
            StoreSplitMigrationService.migrationVersion,
            forKey: Self.completedMigrationVersionKey
        )
        pendingSplitStoreWorkReason = nil
        currentSplitStoreJobDescription = nil
        migrationReadiness = .complete
        migrationBlocker = nil
        migrationLastSliceResult = hadFailures
            ? "Completed with item failures"
            : "Completed successfully"
#if DEBUG
        StoreSplitMigrationDebugLog.record(
            "migration complete",
            details: "version \(StoreSplitMigrationService.migrationVersion), failures=\(hadFailures)"
        )
#endif
        if let cacheContainer = preparedCacheContainer,
           StoreSplitMigrationService.isMigrationVerified(
               cacheContainer: cacheContainer
           ) {
            StoreDevelopmentConfiguration.markLegacyCloudMirrorQuarantineEligible()
            // Close the disk source as soon as lossless verification succeeds.
            // The SQLite files stay untouched until the independent cleanup gate.
            preparedLegacyMigrationContainer = nil
        }
    }

    private func applySyncedUserStateIfPossible(
        authoritativePlaylists: Bool = false,
        refreshMissingFeeds: Bool = false
    ) async -> StoreSplitUserStateImportResult {
        let emptyResult = StoreSplitUserStateImportResult()
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            return emptyResult
        }
        guard StoreDevelopmentConfiguration.userStateImportEnabled else { return emptyResult }
        guard cloudKitExportInProgress() == false else {
            pendingSplitStoreWorkReason = "waiting for CloudKit export to drain"
            return emptyResult
        }
        if let userStateImportTask {
            _ = await userStateImportTask.value
        }
        guard let legacyContainer = preparedContainer,
              let userStateContainer = preparedUserStateContainer else {
            return emptyResult
        }

        // Each synchronized stream has its own cursor. Playback progress must
        // not unlock subscription, playlist, bookmark, preference, or history
        // projections, and a no-op CloudKit notification must not walk the whole
        // library again.
        let changeStamps = latestUserStateChangeStamps(userStateContainer)
        let changedStreams = StoreSplitImportCursorStore.changedStreams(
            current: changeStamps,
            force: authoritativePlaylists
        )
        if changedStreams.isEmpty {
            CrashBreadcrumbs.shared.record(
                "store_split_user_state_import_skipped",
                details: "no_user_state_changes"
            )
#if DEBUG
            StoreSplitMigrationDebugLog.record(
                "reconcile skipped",
                details: "no UserState changes since the last import"
            )
#endif
            return emptyResult
        }

        lastUserStateImportAt = .now
        CrashBreadcrumbs.shared.record(
            "store_split_user_state_import_started",
            details: "streams=\(changedStreams.map(\.rawValue).sorted().joined(separator: ",")),authoritative_playlists=\(authoritativePlaylists),refresh_missing_feeds=\(refreshMissingFeeds)"
        )
        let task = Task {
            // The importer's SQLite write is the checkpoint-critical section, so
            // the background-task assertion is held ONLY around it: a mid-reconcile
            // backgrounding still reaches a safe checkpoint and releases the
            // shared-container lock (instead of 0xdead10cc). Network feed
            // bootstrapping is deliberately not covered by the assertion and is
            // skipped once the task is cancelled (i.e. backgrounded), so the
            // assertion is never held for tens of seconds in the background.
            func runImport() async -> StoreSplitUserStateImportResult {
                await self.withUserStateImportAssertion {
                    await StoreSplitUserStateImporter.apply(
                        legacyContainer: legacyContainer,
                        userStateContainer: userStateContainer,
                        authoritativePlaylists: authoritativePlaylists,
                        projectListeningHistoryToLegacy: StoreDevelopmentConfiguration
                            .projectsListeningHistoryToLegacy,
                        episodeStateProjectionRecencyCutoff: StoreDevelopmentConfiguration
                            .episodeStateProjectionRecencyCutoff,
                        changedStreams: changedStreams
                    )
                }
            }

            let result = await runImport()

            // Only bootstrap missing feeds over the network while foreground and
            // not cancelled; otherwise defer to the next foreground reconcile.
            guard refreshMissingFeeds,
                  result.feedsToBootstrap.isEmpty == false,
                  Task.isCancelled == false else {
                return result
            }

            // Playlist entries are not renderable until their episode feed is
            // present in the legacy UI graph. Prioritize those feeds over the
            // much larger episode-state backlog, while retaining a strict cap.
            let priorityFeeds = result.playlistFeedsToBootstrap
            let maxFeedsPerPass = priorityFeeds.isEmpty
                ? 5
                : min(15, max(5, priorityFeeds.count))
            let retryInterval: TimeInterval = 60 * 15
            let now = Date()
            var seenFeedKeys = Set<String>()
            let dueFeeds = (priorityFeeds + result.feedsToBootstrap).filter { feed in
                let key = PodcastFeedIdentity.normalizedFeedURLString(feed)
                guard seenFeedKeys.insert(key).inserted else { return false }
                guard let lastAttempt = self.missingFeedRefreshAttempts[key] else {
                    return true
                }
                return now.timeIntervalSince(lastAttempt) >= retryInterval
            }
            let feedsToRefresh = Array(dueFeeds.prefix(maxFeedsPerPass))

            var didRefreshAny = false
            for feed in feedsToRefresh {
                if Task.isCancelled { break }
                let key = PodcastFeedIdentity.normalizedFeedURLString(feed)
                self.missingFeedRefreshAttempts[key] = now
                do {
                    let refreshed = try await PodcastModelActor(
                        modelContainer: legacyContainer
                    ).updatePodcast(feed, force: true, silent: true)
                    didRefreshAny = true
                    if refreshed == false {
                        self.missingFeedRefreshAttempts.removeValue(forKey: key)
                    }
                } catch {
                    self.missingFeedRefreshAttempts.removeValue(forKey: key)
                }
            }
            if didRefreshAny, Task.isCancelled == false {
                return await runImport()
            }
            return result
        }
        userStateImportTask = task
        let result = await task.value
        userStateImportTask = nil
        // Only rebuild the hourly statistics when history actually moved.
        // Rebuilding after every reconcile rewrote the whole stats table for no
        // reason and was a large part of the write volume.
        if result.listeningHistoryApplied > 0 {
            await PlaySessionTrackerActor(
                modelContainer: legacyContainer
            ).rebuildListeningStats()
        }
        await StoreSplitPlaylistPresenceStore.publish(
            modelContainer: userStateContainer
        )
        if result.failed == 0, result.interruptedByPlayback == false {
            StoreSplitImportCursorStore.commit(
                latestUserStateChangeStamps(userStateContainer),
                streams: changedStreams
            )
        }
#if DEBUG
        StoreSplitMigrationDebugLog.record(
            "reconcile finished",
            details: "subscriptions=\(result.subscriptionsApplied), states=\(result.episodeStatesApplied), playlists=\(result.playlistsApplied), history=\(result.listeningHistoryApplied), failed=\(result.failed)"
        )
#endif
        return result
    }

    /// Newest timestamp for each synchronized stream. Keeping these separate is
    /// important: a two-second episode-position update must not invalidate the
    /// cursor for every other stream.
    private func latestUserStateChangeStamps(
        _ container: ModelContainer
    ) -> [StoreSplitUserStateStream: StoreSplitUserStateChangeSnapshot] {
        let context = ModelContext(container)
        func snapshot<Model>(
            latest: () -> Model?,
            date: (Model) -> Date,
            idsAtDate: (Date) -> [String]
        ) -> StoreSplitUserStateChangeSnapshot {
            guard let latest = latest() else {
                return StoreSplitUserStateChangeSnapshot(date: nil, recordIDsAtTimestamp: [])
            }
            let latestDate = date(latest)
            return StoreSplitUserStateChangeSnapshot(
                date: latestDate,
                recordIDsAtTimestamp: idsAtDate(latestDate).sorted()
            )
        }

        func latest<Model: PersistentModel>(
            _ type: Model.Type,
            sort: SortDescriptor<Model>
        ) -> Model? {
            var descriptor = FetchDescriptor<Model>(sortBy: [sort])
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }

        return [
            .subscriptions: snapshot(
                latest: { latest(SubscriptionSync.self, sort: SortDescriptor(\SubscriptionSync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    (try? context.fetch(FetchDescriptor<SubscriptionSync>(predicate: #Predicate { $0.updatedAt == date })))?.map(\.id) ?? []
                }
            ),
            .episodeState: snapshot(
                latest: { latest(EpisodeStateSync.self, sort: SortDescriptor(\EpisodeStateSync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    (try? context.fetch(FetchDescriptor<EpisodeStateSync>(predicate: #Predicate { $0.updatedAt == date })))?.map(\.id) ?? []
                }
            ),
            .playlists: snapshot(
                latest: { latest(PlaylistSync.self, sort: SortDescriptor(\PlaylistSync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    (try? context.fetch(FetchDescriptor<PlaylistSync>(predicate: #Predicate { $0.updatedAt == date })))?.map(\.id) ?? []
                }
            ),
            .playlistEntries: snapshot(
                latest: { latest(PlaylistEntrySync.self, sort: SortDescriptor(\PlaylistEntrySync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    (try? context.fetch(FetchDescriptor<PlaylistEntrySync>(predicate: #Predicate { $0.updatedAt == date })))?.map(\.id) ?? []
                }
            ),
            .queueEntries: snapshot(
                latest: { latest(QueueEntrySync.self, sort: SortDescriptor(\QueueEntrySync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    (try? context.fetch(FetchDescriptor<QueueEntrySync>(predicate: #Predicate { $0.updatedAt == date })))?.map(\.id) ?? []
                }
            ),
            .bookmarks: snapshot(
                latest: { latest(BookmarkSync.self, sort: SortDescriptor(\BookmarkSync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    (try? context.fetch(FetchDescriptor<BookmarkSync>(predicate: #Predicate { $0.updatedAt == date })))?.map(\.id) ?? []
                }
            ),
            .preferences: snapshot(
                latest: { latest(PodcastPreferenceSync.self, sort: SortDescriptor(\PodcastPreferenceSync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    (try? context.fetch(FetchDescriptor<PodcastPreferenceSync>(predicate: #Predicate { $0.updatedAt == date })))?.map(\.id) ?? []
                }
            ),
            .listeningHistory: snapshot(
                latest: { latest(ListeningHistorySync.self, sort: SortDescriptor(\ListeningHistorySync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    (try? context.fetch(FetchDescriptor<ListeningHistorySync>(predicate: #Predicate { $0.updatedAt == date })))?.map(\.id) ?? []
                }
            ),
            .listeningBaseline: snapshot(
                latest: { latest(ListeningBaselineSync.self, sort: SortDescriptor(\ListeningBaselineSync.capturedAt, order: .reverse)) },
                date: { $0.capturedAt },
                idsAtDate: { date in
                    (try? context.fetch(FetchDescriptor<ListeningBaselineSync>(predicate: #Predicate { $0.capturedAt == date })))?.map(\.id) ?? []
                }
            )
        ]
    }

    /// Runs `body` while holding a UIKit background-task assertion named
    /// `StoreSplitUserStateImport`, ending it as soon as `body` returns. Scoping
    /// the assertion to just the SQLite-critical import keeps it from being held
    /// for tens of seconds (and risking termination) during background network work.
    private func withUserStateImportAssertion<T>(
        _ body: () async -> T
    ) async -> T {
#if canImport(UIKit)
        let backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "StoreSplitUserStateImport"
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.userStateImportTask?.cancel()
            }
        }
        defer {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }
        return await body()
#else
        return await body()
#endif
    }

    private func shouldRunUserStateImport(
        force: Bool,
        reason: String
    ) -> Bool {
        if force {
            return true
        }

        if Player.shared.isPlaying {
            CrashBreadcrumbs.shared.record(
                "store_split_user_state_import_skipped",
                details: "\(reason):player_session_active"
            )
            return false
        }

        if let lastUserStateImportAt,
           Date().timeIntervalSince(lastUserStateImportAt)
            < minimumForegroundUserStateImportInterval {
            CrashBreadcrumbs.shared.record(
                "store_split_user_state_import_skipped",
                details: "\(reason):recently_ran"
            )
            return false
        }

        return true
    }

    func performSplitStoreAIImportIfPossible() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            pendingSplitStoreWorkReason = "paused for stability"
            currentSplitStoreJobDescription = nil
            return
        }
        guard cloudKitExportInProgress() == false else {
            pendingSplitStoreWorkReason = "waiting for CloudKit export to drain"
            currentSplitStoreJobDescription = nil
            return
        }
        await applyCachedAIContentIfPossible()
    }

    private func applyCachedAIContentIfPossible() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            return
        }
        if let aiContentImportTask {
            await aiContentImportTask.value
            return
        }
        guard let legacyContainer = preparedContainer,
              let cacheContainer = preparedCacheContainer else {
            return
        }
        if let lastAIContentImportAt,
           Date().timeIntervalSince(lastAIContentImportAt) < minimumAIContentImportInterval {
            return
        }

        let task = Task {
            _ = await StoreSplitAIContentImporter.apply(
                legacyContainer: legacyContainer,
                cacheContainer: cacheContainer
            )
        }
        aiContentImportTask = task
        await task.value
        lastAIContentImportAt = .now
        aiContentImportTask = nil
    }

    func updateSplitStoreCoordinatorState(
        currentJob: String?,
        pendingReason: String?
    ) {
        currentSplitStoreJobDescription = currentJob
        pendingSplitStoreWorkReason = pendingReason
    }

    private func apply(
        _ result: Result<ModelContainer, Error>,
        to containerKeyPath: ReferenceWritableKeyPath<ModelContainerManager, ModelContainer?>,
        error errorKeyPath: ReferenceWritableKeyPath<ModelContainerManager, String?>,
        storeName: String
    ) {
        switch result {
        case let .success(container):
            self[keyPath: containerKeyPath] = container
            CrashBreadcrumbs.shared.record("store_split_container_ready", details: storeName)
        case let .failure(error):
            self[keyPath: errorKeyPath] = error.localizedDescription
            CrashBreadcrumbs.shared.record(
                "store_split_container_initialization_failed",
                details: "\(storeName):\(error.localizedDescription)"
            )
        }
    }

    nonisolated static func makeLegacyContainer(
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration
        // Only a container that actually opened tells us what the store is
        // attached to. Recording before the open would let a failed launch leave
        // behind a decision the store never saw, which is enough to disarm the
        // re-attach guard on the following launch.
        var legacyCloudSyncToRecord: Bool?
        if isStoredInMemoryOnly {
            configuration = ModelConfiguration(
                "Legacy",
                isStoredInMemoryOnly: true,
                allowsSave: allowsSave,
                cloudKitDatabase: .none
            )
        } else if let sharedContainerURL = sharedContainerURL {
            // The library graph keeps its CloudKit mirror through the
            // `dualSyncBackfill` release, so existing users' cross-device
            // behaviour is untouched while UserState is being built up. Ship #2
            // flips `StoreSplitReleasePhase.current` and this becomes `.none`,
            // which is the change that actually shrinks the iCloud payload.
            let legacyCloudSyncApplied =
                StoreDevelopmentConfiguration.legacyCloudSyncEnabled
            legacyCloudSyncToRecord = legacyCloudSyncApplied
            let storeURL = sharedContainerURL
                .appendingPathComponent("SharedDatabase.sqlite")
            // Must run before the container opens: SwiftData applies `#Index`
            // only when it creates a store, so every install that predates the
            // index declarations needs them created directly.
            if allowsSave {
                LegacyStoreIndexBackfill.run(storeURL: storeURL)
            }
            configuration = ModelConfiguration(
                "Legacy",
                url: storeURL,
                allowsSave: allowsSave,
                cloudKitDatabase: legacyCloudSyncApplied ? .automatic : .none
            )
        } else {
            configuration = ModelConfiguration(
                "Legacy",
                isStoredInMemoryOnly: true,
                allowsSave: allowsSave,
                cloudKitDatabase: .none
            )
        }

        let container = try ModelContainer(
            for: Podcast.self,
                PodcastMetaData.self,
                Episode.self,
                EpisodeMetaData.self,
                Playlist.self,
                PlaylistEntry.self,
                Marker.self,
                Bookmark.self,
                RateSegment.self,
                PlaySession.self,
                ListeningStat.self,
                PlaySessionSummary.self,
                TranscriptionRecord.self,
            configurations: configuration
        )
        // Remember what was actually applied, so the next launch can tell an
        // off→on re-attach from a store that has always been mirrored.
        if let legacyCloudSyncToRecord {
            StoreDevelopmentConfiguration.recordLegacyCloudSyncDecision(
                legacyCloudSyncToRecord
            )
        }
        return container
    }

    nonisolated static func makeRuntimeContainer() throws -> ModelContainer {
        try makeLegacyContainer(isStoredInMemoryOnly: runtimeUsesCacheProjection)
    }

    nonisolated static func makeUserStateContainer(
        isStoredInMemoryOnly: Bool = false
    ) throws -> ModelContainer {
        let schema = Schema([
            SubscriptionSync.self,
            EpisodeStateSync.self,
            QueueEntrySync.self,
            PlaylistSync.self,
            PlaylistEntrySync.self,
            BookmarkSync.self,
            PodcastPreferenceSync.self,
            ListeningBaselineSync.self,
            ListeningHistorySync.self
        ])
        let configuration: ModelConfiguration

        if isStoredInMemoryOnly {
            configuration = ModelConfiguration(
                "UserState",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        } else if let userStateStoreURL {
            configuration = ModelConfiguration(
                "UserState",
                schema: schema,
                url: userStateStoreURL,
                cloudKitDatabase: StoreDevelopmentConfiguration.userStateCloudSyncEnabled
                    ? .automatic
                    : .none
            )
        } else {
            configuration = ModelConfiguration(
                "UserState",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        }

        return try ModelContainer(for: schema, configurations: configuration)
    }

    nonisolated static func makeCacheContainer(
        isStoredInMemoryOnly: Bool = false
    ) throws -> ModelContainer {
        let schema = Schema([
            StoreSplitMigrationCheckpoint.self,
            StoreSplitMigrationVerification.self,
            CachedFeedExtensionElement.self,
            AppliedAIContentRevision.self,
            CachedPodcast.self,
            CachedEpisode.self,
            CachedChapter.self,
            CachedTranscriptLine.self,
            CachedTranscriptionRecord.self,
            CachedDownloadRecord.self,
            CachedPlaySession.self,
            CachedRateSegment.self,
            CachedHourlyListeningStat.self,
            AITranscriptSync.self,
            AITranscriptChunkSync.self,
            AIChapterSetSync.self,
            FeedAlias.self
        ])
        let configuration: ModelConfiguration

        if isStoredInMemoryOnly {
            configuration = ModelConfiguration(
                "PodcastCache",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        } else if let cacheStoreURL {
            configuration = ModelConfiguration(
                "PodcastCache",
                schema: schema,
                url: cacheStoreURL,
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                "PodcastCache",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        }

        return try ModelContainer(for: schema, configurations: configuration)
    }
}

#if DEBUG
enum StoreSplitDevelopmentResetError: LocalizedError {
    case workInProgress
    case storesUnavailable

    var errorDescription: String? {
        switch self {
        case .workInProgress:
            "Migration or synchronization work is still running. Try again in a moment."
        case .storesUnavailable:
            "The split stores could not be opened."
        }
    }
}
#endif

private struct SplitStoreContainers: @unchecked Sendable {
    let userState: Result<ModelContainer, Error>?
    let cache: Result<ModelContainer, Error>?
}
