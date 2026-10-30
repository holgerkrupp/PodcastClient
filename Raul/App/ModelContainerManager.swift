import SwiftData
import SwiftUI
import Synchronization
import CloudKitSyncMonitor
import CoreData
#if canImport(UIKit)
import UIKit
#endif

enum StoreBootstrapMode: String, Sendable, Equatable {
    case freshSplitInstall
    case legacyUpgrade
    case existingLibraryUnavailable

    var usesInMemoryRuntimeProjection: Bool {
        switch self {
        case .freshSplitInstall: true
        case .legacyUpgrade, .existingLibraryUnavailable: false
        }
    }

    static func resolve(
        legacyStoreExists: Bool,
        installationWasPreviouslyInitialized: Bool = false
    ) -> StoreBootstrapMode {
        if legacyStoreExists { return .legacyUpgrade }
        return installationWasPreviouslyInitialized
            ? .existingLibraryUnavailable
            : .freshSplitInstall
    }

}

enum StoreBootstrapEvidence {
    static let persistentLibraryOpenedKey = "storeSplit.persistentLibraryOpened.v1"
    static let freshSplitInstallReadyKey = "storeSplit.freshSplitInstallReady.v1"

    static func hasFreshSplitInstallRecord(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: freshSplitInstallReadyKey)
    }

    static func mayHaveExistingLibrary(
        standardDefaults: UserDefaults,
        appGroupDefaults: UserDefaults?,
        files: Set<String>
    ) -> Bool {
        if standardDefaults.bool(forKey: persistentLibraryOpenedKey)
            || standardDefaults.bool(forKey: "didCompleteOnboarding") {
            return true
        }
        if appGroupDefaults?.object(
            forKey: StoreDevelopmentConfiguration.legacyCloudSyncLastStateKey
        ) != nil {
            return true
        }
        return files.contains {
            $0 == "SharedDatabase.sqlite" || $0 == "SharedDatabase.sqlite-wal"
                || $0 == "SharedDatabase.sqlite-shm" || $0 == "UserState.sqlite"
                || $0 == "PodcastCache.sqlite"
        }
    }
}

enum StoreBootstrapError: LocalizedError {
    case existingLibraryUnavailable
    case persistentStoreUnavailable

    var errorDescription: String? {
        switch self {
        case .existingLibraryUnavailable:
            return "Up Next could not access this installation’s existing library. Startup did not delete or replace it. Keep Up Next installed and try again when storage is available."
        case .persistentStoreUnavailable:
            return "Up Next could not access persistent storage. Startup did not reset or replace a store. Keep Up Next installed and try again when storage is available."
        }
    }
}

/// Bridges cancellation from a background operation to an unstructured worker
/// that owns bounded store work.
enum StoreSplitTaskCancellation {
    /// Admission check for the next store operation after an asynchronous
    /// boundary. BGProcessing expiration can cancel the caller while a remote
    /// configuration request is suspended; callers must re-check before
    /// opening stores or starting a new database operation.
    static func shouldBeginStoreWork(isCancelled: Bool) -> Bool {
        isCancelled == false
    }

    static func awaitValue<Value: Sendable>(
        of task: Task<Value, Never>
    ) async -> Value {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Keeps an import request made while a previous pass is running from being
/// cleared by that pass: a pass acknowledges only the generation it started
/// with.
enum StoreSplitPendingImportLedger {
    private static let lock = NSLock()
    private static let pendingKey = "storeSplit.userStateImportPending.v1"
    private static let generationKey = "storeSplit.userStateImportGeneration.v1"

    static func request(in defaults: UserDefaults, newGeneration: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        if newGeneration || defaults.string(forKey: generationKey) == nil {
            defaults.set(UUID().uuidString, forKey: generationKey)
        }
        defaults.set(true, forKey: pendingKey)
    }

    static func snapshot(in defaults: UserDefaults) -> (pending: Bool, generation: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (defaults.bool(forKey: pendingKey), defaults.string(forKey: generationKey))
    }

    @discardableResult
    static func acknowledge(_ generation: String?, in defaults: UserDefaults) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard defaults.string(forKey: generationKey) == generation else { return false }
        defaults.set(false, forKey: pendingKey)
        return true
    }
}

/// Absence must be established by a successful directory read, not fileExists
/// (which also returns false for protected/unavailable storage).
enum StoreLineage {
    static let key = "storeSplit.openedPersistentStores.v1"

    static func directoryContentsWithRetry(
        directory: () -> URL?,
        expected: [String],
        attempts: Int = 3
    ) throws -> Set<String> {
        var lastError: Error = PlaylistPersistenceError.storageUnavailable
        for attempt in 0..<max(1, attempts) {
            do {
                guard let directory = directory() else { throw PlaylistPersistenceError.storageUnavailable }
                let files = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
                try validate(files: files, expected: expected)
                return files
            } catch {
                lastError = error
                guard attempt + 1 < max(1, attempts) else { break }
                // Startup already runs off the main actor. Keep this short and
                // bounded to absorb transient App Group/filesystem availability.
                Thread.sleep(forTimeInterval: attempt == 0 ? 0.12 : 0.28)
            }
        }
        throw lastError
    }

    static func validate(directory: URL?, expected: [String]) throws {
        guard let directory else { throw PlaylistPersistenceError.storageUnavailable }
        try validate(
            files: Set(FileManager.default.contentsOfDirectory(atPath: directory.path)),
            expected: expected
        )
    }

    private static func validate(files: Set<String>, expected: [String]) throws {
        for name in expected where !files.contains(name) {
            throw PlaylistPersistenceError.storageUnavailable
        }
        if !files.contains("SharedDatabase.sqlite"),
           files.contains("SharedDatabase.sqlite-wal") || files.contains("SharedDatabase.sqlite-shm") {
            throw PlaylistPersistenceError.storageUnavailable
        }
    }
}

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
        let failureReport: CloudKitFailureAnalyzer.Report?
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
        let lastImportSucceeded: Bool?
        let lastSuccessfulImportAt: Date?
        let lastImportErrorCode: Int?
        let lastImportCountsBefore: StoreCounts?
        let lastImportCountsAfter: StoreCounts?
        let lastExportEndedAt: Date?
        let lastExportStartedAt: Date?
        let lastExportEventID: UUID?
        let lastExportSucceeded: Bool?
        let lastSuccessfulExportAt: Date?
        let lastExportErrorCode: Int?
        let lastExportFailureReport: CloudKitFailureAnalyzer.Report?
        let failedExportCount: Int
        let lastReconciliation: Reconciliation?

        var id: String { storeKind.rawValue }

        var importStatus: ImportStatus {
            if activeImportCount > 0 { return .syncing }
            guard let lastImportSucceeded else { return .notObserved }
            return lastImportSucceeded ? .complete : .failed
        }

        var hasUnresolvedExportFailure: Bool {
            lastExportSucceeded == false
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
        let failureReport: CloudKitFailureAnalyzer.Report?
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
    private var processCPUAtEventStart: [UUID: ProcessCPUSample] = [:]
    private var reconciliations: [StoreKind: Reconciliation] = [:]
    private var observer: NSObjectProtocol?
    private var legacyStoreUUID: String?
    private var userStateStoreUUID: String?

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
        refreshStoreIdentifiers()
    }

    func refreshStoreIdentifiers() {
        Task.detached(priority: .utility) { [weak self] in
            let legacy = CloudKitStoreIdentity.identifier(at: ModelContainerManager.sharedStoreURL)
            let userState = CloudKitStoreIdentity.identifier(at: ModelContainerManager.userStateStoreURL)
            await MainActor.run { [weak self] in
                self?.registerStoreIdentifiers(legacy: legacy, userState: userState)
            }
        }
    }

    var isAnyStoreExporting: Bool {
        activeEvents.contains { $0.type == .export }
    }

    var activeExportEvents: [ActiveEvent] {
        activeEvents.filter { $0.type == .export }
    }

    /// A BGProcessingTask's own SwiftData work can finish before Core Data's
    /// asynchronous export does. Keep the granted task alive through a short
    /// quiet interval, but never wait without a bound for a stalled exporter.
    func waitForExportQuiescence(
        maximumDuration: TimeInterval = 15,
        quietDuration: TimeInterval = 1
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(maximumDuration)
        var idleSince: Date?
        while Date() < deadline && Task.isCancelled == false {
            if isAnyStoreExporting {
                idleSince = nil
            } else {
                if idleSince == nil { idleSince = .now }
                if let idleSince,
                   Date().timeIntervalSince(idleSince) >= quietDuration {
                    return true
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        CrashBreadcrumbs.shared.record(
            "cloudkit_export_background_drain_unsettled",
            details: "active=\(activeExportEvents.map { $0.id.uuidString }.joined(separator: ","))"
        )
        return false
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
            errorCode: event.error.map { ($0 as NSError).code },
            failureReport: event.error.map(CloudKitFailureAnalyzer.analyze)
        )
    }

    private func handle(_ event: EventPayload) {

        let eventKind = event.type
        if eventKind == .export {
            StoreMaintenanceResourceBudget.shared.setCloudKitExport(
                eventID: event.id,
                active: event.endDate == nil
            )
        }
        let storeKind = storeKind(for: event.storeIdentifier)
        let id = event.id
        if let endedAt = event.endDate {
            let cpuAtEnd = SystemProcessCPUTimeSource().sample()
            let cpuDelta = processCPUAtEventStart.removeValue(forKey: id).map {
                max(0, cpuAtEnd.cpuTime - $0.cpuTime)
            }
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
                failureReport: event.failureReport,
                countsBefore: countsBefore,
                countsAfter: countsAfter
            )
            SupportDiagnosticsRecorder.shared.record(
                "CloudKit \(storeKind.title) \(eventKind.rawValue)",
                detail: event.succeeded
                    ? "completed"
                    : "failed" + (event.failureReport.map { ": \($0.summary)" } ?? "")
            )
            if let retryAfter = event.failureReport?.groups
                .compactMap(\.retryAfterSeconds)
                .min() {
                SupportDiagnosticsRecorder.shared.record(
                    "CloudKit retry hint observed",
                    detail: "\(storeKind.title) after \(Int(ceil(retryAfter))) seconds"
                )
            }
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
                + ",store_id=" + event.storeIdentifier
                + ",event_id=" + id.uuidString
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
            AppDiagnostics.log(
                "cloudkit_store_event_finished store=\(storeKind.rawValue) type=\(eventKind.rawValue) duration_ms=\(Int(endedAt.timeIntervalSince(event.startDate) * 1_000)) process_cpu_seconds_delta=\(cpuDelta.map { String(format: "%.2f", $0) } ?? "unavailable") memory_footprint_bytes=\(MemoryFootprint.current()) audio_active=\(Player.hasActivePlaybackInProcess || Player.shared.isPlaying) background_processing_active=\(ModelContainerManager.shared.isRunningBackgroundProcessingTask)"
            )
            if eventKind == .export {
                Task {
                    await StoreSplitWorkCoordinator.shared.resumeAfterCloudKitExport()
#if canImport(UIKit)
                    AppDelegate.scheduleStoreSplitBackgroundProcessingIfNeeded()
#endif
                }
            }
        } else {
            processCPUAtEventStart[id] = SystemProcessCPUTimeSource().sample()
            let active = ActiveEvent(
                id: id,
                storeIdentifier: event.storeIdentifier,
                storeKind: storeKind,
                type: eventKind,
                startedAt: event.startDate
            )
            activeByID[id] = active
            SupportDiagnosticsRecorder.shared.record(
                "CloudKit \(storeKind.title) \(eventKind.rawValue)",
                detail: "started"
            )
            if eventKind == .importEvent {
                importCountsByID[id] = ModelContainerManager.shared
                    .cloudKitStoreCounts(for: storeKind)
            }
            CrashBreadcrumbs.shared.record(
                "cloudkit_store_event_started",
                details: "store=" + storeKind.rawValue
                    + ",store_id=" + event.storeIdentifier
                    + ",event_id=" + id.uuidString
                    + ",type=" + eventKind.rawValue
            )
            AppDiagnostics.log(
                "cloudkit_store_event_started store=\(storeKind.rawValue) type=\(eventKind.rawValue) memory_footprint_bytes=\(MemoryFootprint.current()) audio_active=\(Player.hasActivePlaybackInProcess || Player.shared.isPlaying) background_processing_active=\(ModelContainerManager.shared.isRunningBackgroundProcessingTask)"
            )
        }
        activeEvents = activeByID.values.sorted { $0.startedAt < $1.startedAt }
        StoreSplitCloudKitExportGate.shared.setActive(
            activeEvents.contains { $0.type == .export }
        )
        rebuildDiagnostics()
    }

    private func storeKind(for identifier: String) -> StoreKind {
        if CloudKitStoreIdentity.isLegacy(identifier, legacyUUID: legacyStoreUUID) {
            return .legacy
        }
        if let userStateStoreUUID,
           identifier.caseInsensitiveCompare(userStateStoreUUID) == .orderedSame {
            return .userState
        }
        return StoreKind(storeIdentifier: identifier)
    }

    private func registerStoreIdentifiers(legacy: String?, userState: String?) {
        legacyStoreUUID = legacy ?? legacyStoreUUID
        userStateStoreUUID = userState ?? userStateStoreUUID
        activeByID = activeByID.mapValues { event in
            ActiveEvent(
                id: event.id, storeIdentifier: event.storeIdentifier,
                storeKind: storeKind(for: event.storeIdentifier),
                type: event.type, startedAt: event.startedAt
            )
        }
        lastCompletedEvents = lastCompletedEvents.map { event in
            CompletedEvent(
                id: event.id, storeIdentifier: event.storeIdentifier,
                storeKind: storeKind(for: event.storeIdentifier),
                type: event.type, startedAt: event.startedAt,
                endedAt: event.endedAt, succeeded: event.succeeded,
                errorCode: event.errorCode, failureReport: event.failureReport,
                countsBefore: event.countsBefore,
                countsAfter: event.countsAfter
            )
        }
        activeEvents = activeByID.values.sorted { $0.startedAt < $1.startedAt }
        latestCompletedImport = lastCompletedEvents.first { $0.type == .importEvent }
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
            let failedExports = lastCompletedEvents.filter {
                $0.storeKind == kind && $0.type == .export && !$0.succeeded
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
                lastImportSucceeded: lastImport?.succeeded,
                lastSuccessfulImportAt: successfulImport?.endedAt,
                lastImportErrorCode: lastImport?.succeeded == false
                    ? lastImport?.errorCode
                    : nil,
                lastImportCountsBefore: lastImport?.countsBefore,
                lastImportCountsAfter: lastImport?.countsAfter,
                lastExportEndedAt: lastExport?.endedAt,
                lastExportStartedAt: lastExport?.startedAt,
                lastExportEventID: lastExport?.id,
                lastExportSucceeded: lastExport?.succeeded,
                lastSuccessfulExportAt: successfulExport?.endedAt,
                lastExportErrorCode: lastExport?.succeeded == false
                    ? lastExport?.errorCode
                    : nil,
                lastExportFailureReport: lastExport?.succeeded == false
                    ? lastExport?.failureReport
                    : nil,
                failedExportCount: failedExports.count,
                lastReconciliation: reconciliations[kind]
            )
        }
    }

    private func isAttached(_ storeKind: StoreKind) -> Bool {
        switch storeKind {
        // The legacy library store is local-only and never attaches CloudKit.
        case .legacy: return false
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
    @Published private(set) var preparedUserStateContainer: ModelContainer?
    @Published private(set) var preparedCacheContainer: ModelContainer?
    @Published private(set) var initializationError: String?
    @Published var playlistSaveFailed = false
    @Published private(set) var bootstrapMode: StoreBootstrapMode = .freshSplitInstall
    @Published private(set) var userStateInitializationError: String?
    @Published private(set) var cacheInitializationError: String?
    @Published private(set) var isInitializing = false
    @Published private(set) var isPreparingSplitStores = false
    enum RuntimeStoreReadiness: Equatable {
        case unopened
        case settling
        case ready
        case failed
    }
    private enum RuntimeGraphPreparationResult: Sendable, Equatable {
        case ready
        case interrupted
        case failed
    }
    @Published private(set) var runtimeStoreReadiness: RuntimeStoreReadiness = .unopened
    @Published private(set) var requiresInitialCloudImport = false
    @Published private(set) var currentSplitStoreJobDescription: String?
    @Published private(set) var pendingSplitStoreWorkReason: String?
    @Published private(set) var lastSplitStoreReconcileSummary: String?
    @Published private(set) var lastSplitStoreReconcileAt: Date?
    @Published private(set) var migrationReadiness: StoreSplitMigrationReadiness = .unavailable
    @Published private(set) var migrationBlocker: String?
#if DEBUG
    @Published private(set) var developmentResetRequiresRelaunch = false
#endif
    private var preparationTask: Task<RuntimeContainerPreparation, Error>?
    /// Non-nil while the one-time migration is the thing blocking startup.
    @Published private(set) var cutoverProgress: StoreCutoverProgress?
    private var pendingRuntimeContainer: ModelContainer?
    private var libraryFillTask: Task<Bool, Never>?
    private var openedExistingProjection = false
    @Published private(set) var isDeferredMigrationRunning = false
    /// Categories and counts only, for the launch diagnostics report.
    private(set) var lastHydrationSummary: String?
    private var deferredMigrationTask: Task<StoreCutoverOutcome, Never>?
    private var splitStorePreparationTask: Task<SplitStoreContainers, Never>?
    /// Set while a `BGProcessingTask` is driving store maintenance. iOS has
    /// granted a time budget in that window, so the "app is backgrounded" stop
    /// condition must not apply.
    private(set) var isRunningBackgroundProcessingTask = false
    private var didBuildCompatibilityProjection = false
    private var compatibilityProjectionTask: Task<RuntimeGraphPreparationResult, Never>?
#if DEBUG
    private var isRuntimeGraphFixture = false
#else
    private let isRuntimeGraphFixture = false
#endif
    private var aiContentImportTask: Task<StoreSplitAIContentImportResult, Never>?
    private var userStateImportTask: Task<StoreSplitUserStateImportResult, Never>?
    private var missingFeedRefreshAttempts: [String: Date] = [:]
    private var lastAIContentImportAt: Date?
    private var lastUserStateImportAt: Date?
    private var exportWasInProgress = false
    private var exporterPressureEvents = 0
    private var optionalSplitStoreWritesSuspended = false
    private var pendingSplitRuntimePlaylistReconciliation = false
    private let minimumAIContentImportInterval: TimeInterval = 60 * 15
    private let minimumForegroundUserStateImportInterval: TimeInterval = 60 * 10
    private let splitStoreCoordinator = StoreSplitWorkCoordinator.shared
    nonisolated private static let cacheRecoveryVersion = 1
    nonisolated private static let cacheRecoveryVersionKey =
        "storeSplit.cacheOnlyLibraryRecoveryVersion"
    nonisolated private static let usedInMemoryProjectionKey =
        "storeSplit.usedInMemoryLibraryProjection"

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

#if DEBUG
    /// In-memory fixture entrypoint for startup hydration regression tests.
    /// Does not reset or replace any shared on-disk stores.
    init(
        runtimeContainer: ModelContainer,
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer
    ) {
        preparedContainer = runtimeContainer
        preparedUserStateContainer = userStateContainer
        preparedCacheContainer = cacheContainer
        bootstrapMode = .freshSplitInstall
        runtimeStoreReadiness = .settling
        isRuntimeGraphFixture = true
    }
#endif

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

    var runtimeProjectsFromCache: Bool {
        bootstrapMode.usesInMemoryRuntimeProjection
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
        let bootstrapMode: StoreBootstrapMode
        var projectionReady = false
        var userStateContainer: ModelContainer? = nil
        var cacheContainer: ModelContainer? = nil
    }

    /// Holds the open started by `startEagerContainerPreparation` until
    /// `prepareContainer` adopts it. Deliberately not main-actor state: the
    /// point is to start the open while the main thread is still busy.
    nonisolated private static let eagerPreparationTask =
        Mutex<Task<RuntimeContainerPreparation, Error>?>(nil)
    nonisolated private static let didRecordLaunchHealth = Mutex(false)

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

    /// The order inside this task is load-bearing: the "is this a fresh
    /// install" check is only meaningful while the store file does not exist
    /// yet, so it comes before the open itself.
    nonisolated private static func makeRuntimeContainerPreparationTask(
    ) -> Task<RuntimeContainerPreparation, Error> {
        Task.detached(priority: .userInitiated) {
            // This runs before the stores open, which is the earliest
            // point at which Core Data can resume a persisted CloudKit export.
            // A repeated unhealthy-launch sequence can therefore quarantine the
            // legacy mirror before the exporter is reopened.
            let firstPreparationThisProcess = didRecordLaunchHealth.withLock { recorded in
                defer { recorded = true }
                return recorded == false
            }
            if firstPreparationThisProcess {
                _ = StoreSplitLaunchHealth.beginLaunch()
            }
            CrashBreadcrumbs.shared.record("model_container_initialization_started")
            var expectedStores = UserDefaults.standard.stringArray(forKey: StoreLineage.key) ?? []
            let lineageDefaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
            // Older builds already recorded this only after a successful disk
            // open. Preserve that lineage on the first launch of this fix.
            if lineageDefaults.object(forKey: StoreDevelopmentConfiguration.legacyCloudSyncLastStateKey) != nil,
               !expectedStores.contains("SharedDatabase.sqlite") {
                expectedStores.append("SharedDatabase.sqlite")
            }
            // Read the App Group directory successfully before making any
            // store-selection decision. `fileExists` returns false for several
            // inaccessible-storage cases, so it cannot establish a fresh install.
            let files: Set<String>
            do {
                files = try StoreLineage.directoryContentsWithRetry(
                    directory: { Self.sharedContainerURL },
                    expected: expectedStores
                )
            } catch {
                throw StoreBootstrapError.persistentStoreUnavailable
            }
            let appGroupDefaults = UserDefaults(suiteName: Self.appGroupID)
            let hasFreshSplitInstallRecord = StoreBootstrapEvidence.hasFreshSplitInstallRecord(
                defaults: .standard
            )
            let hasExistingLibraryEvidence = StoreBootstrapEvidence.mayHaveExistingLibrary(
                standardDefaults: .standard,
                appGroupDefaults: appGroupDefaults,
                files: files
            )
            let legacyStoreExists = files.contains("SharedDatabase.sqlite")
            let bootstrapMode = StoreBootstrapMode.resolve(
                legacyStoreExists: legacyStoreExists,
                installationWasPreviouslyInitialized: hasExistingLibraryEvidence
                    && !hasFreshSplitInstallRecord
            )
            CrashBreadcrumbs.shared.record("store_bootstrap_classified", details: "mode=\(bootstrapMode.rawValue),legacy_present=\(legacyStoreExists),existing_evidence=\(hasExistingLibraryEvidence),fresh_split_record=\(hasFreshSplitInstallRecord),known_stores=\(expectedStores.count)")
            guard bootstrapMode != .existingLibraryUnavailable else {
                throw StoreBootstrapError.existingLibraryUnavailable
            }
            // A projection is usable only after its durable backing stores
            // opened. Never expose a writable empty runtime on opening failure.
            await MainActor.run {
                SupportDiagnosticsRecorder.shared.record("Opening User State store")
            }
            let userState = try Self.makeUserStateContainerWithRetry()
            await MainActor.run {
                SupportDiagnosticsRecorder.shared.record("Opening Podcast cache store")
            }
            let cache = try Self.makeCacheContainerWithRetry()
            if bootstrapMode == .legacyUpgrade {
                // The device's own library stays what the UI reads, local-only.
                guard let storeURL = Self.sharedStoreURL else {
                    throw StoreBootstrapError.persistentStoreUnavailable
                }
                LegacyStoreIndexBackfill.run(storeURL: storeURL)
                let library = try Self.makeContainerWithRetry(store: "legacy", attempts: 3) {
                    try Self.makeLegacyContainer(storageURL: storeURL)
                }
                StoreCutoverState.beginLocalLibrary()
                StoreRuntimeProjection.discardUnused()
                StoreSplitLaunchHealth.markRuntimeReady()
                return RuntimeContainerPreparation(
                    container: library,
                    requiresInitialCloudImport: false,
                    bootstrapMode: bootstrapMode,
                    projectionReady: true,
                    userStateContainer: userState,
                    cacheContainer: cache
                )
            }
            guard let runtimeURL = StoreRuntimeProjection.url else {
                throw StoreBootstrapError.persistentStoreUnavailable
            }
            let projectionReady = StoreRuntimeProjection.isReady
            let runtimeContainer = try StoreRuntimeProjection.open(
                at: runtimeURL,
                isCurrent: StoreRuntimeProjection.isFileCurrent
            )
            StoreSplitLaunchHealth.markRuntimeReady()
            return RuntimeContainerPreparation(
                container: runtimeContainer,
                // Read before opening created the file would be too late; the
                // directory listing above predates the open.
                requiresInitialCloudImport: StoreDevelopmentConfiguration.userStateCloudSyncEnabled
                    && bootstrapMode == .freshSplitInstall
                    && !files.contains("UserState.sqlite"),
                bootstrapMode: bootstrapMode,
                projectionReady: projectionReady && StoreRuntimeProjection.isReady,
                userStateContainer: userState,
                cacheContainer: cache
            )
        }
    }

    func prepareContainer() async {
        if preparedContainer != nil || pendingRuntimeContainer != nil {
            if runtimeStoreReadiness == .settling || runtimeStoreReadiness == .failed {
                await prepareSplitStores()
            }
            return
        }
        let task: Task<RuntimeContainerPreparation, Error>
        if let preparationTask {
            task = preparationTask
        } else {
            isInitializing = true
            initializationError = nil
            runtimeStoreReadiness = .settling
            let newTask = Self.takeEagerPreparationTask()
                ?? Self.makeRuntimeContainerPreparationTask()
            preparationTask = newTask
            task = newTask
        }

        do {
            let preparation = try await task.value
            let preparedContainer = preparation.container
            requiresInitialCloudImport = preparation.requiresInitialCloudImport
            bootstrapMode = preparation.bootstrapMode
            if let userState = preparation.userStateContainer { preparedUserStateContainer = userState }
            if let cache = preparation.cacheContainer { preparedCacheContainer = cache }
            if self.preparedContainer == nil, pendingRuntimeContainer == nil {
                if preparation.projectionReady {
                    // Already built on an earlier launch: open straight away.
                    didBuildCompatibilityProjection = true
                    openedExistingProjection = true
                    self.preparedContainer = preparedContainer
                } else {
                    // Never show a library that is still being built. This is
                    // the one-time step, on the same screen as the migration.
                    pendingRuntimeContainer = preparedContainer
                    cutoverProgress = StoreCutoverProgress(fraction: 0)
                }
                StoreCloudKitActivityMonitor.shared.refreshStoreIdentifiers()
                self.runtimeStoreReadiness = .settling
                SupportDiagnosticsRecorder.shared.record("Runtime library store opened")
                CrashBreadcrumbs.shared.record("model_container_initialization_completed")
            }
            // The in-memory graph is empty until it has been rebuilt.
            await prepareSplitStores()
        } catch {
            if initializationError == nil {
                initializationError = error.localizedDescription
                CrashBreadcrumbs.shared.record(
                    "model_container_initialization_failed",
                    details: error.localizedDescription
                )
            }
            runtimeStoreReadiness = .failed
        }

        preparationTask = nil
        isInitializing = false
    }

    /// Adds the remaining episodes and saved transcripts while the app is in use.
    /// Backgrounding stops it; the next launch or activation continues.
    func runLibraryBackfillIfNeeded() async {
        guard StoreRuntimeProjection.isLibraryBackfillPending,
              libraryFillTask == nil,
              runtimeStoreReadiness == .ready,
              heavyStoreWorkMayRunInCurrentAppState,
              let runtime = preparedContainer,
              let userState = preparedUserStateContainer,
              let cache = preparedCacheContainer else { return }
        StoreRuntimeProjection.fillUserStateContainer = userState
        let task = Task.detached(priority: .utility) { () -> Bool in
            guard await StoreRuntimeProjection.fillFromFeeds(runtime: runtime) else { return false }
            let finished = await StoreSplitCompatibilityProjectionService.backfillTranscripts(
                cacheContainer: cache,
                runtimeContainer: runtime,
                resumeAfter: StoreRuntimeProjection.libraryBackfillCursor,
                shouldContinue: { Task.isCancelled == false },
                checkpoint: { StoreRuntimeProjection.libraryBackfillCursor = $0 }
            )
            if finished {
                StoreSplitCompatibilityProjectionService.rebuildLocalAnalytics(
                    cacheContainer: cache,
                    runtimeContainer: runtime
                )
                await PlaySessionTrackerActor(modelContainer: runtime).rebuildListeningStats()
            }
            return finished
        }
        libraryFillTask = task
        let finished = await task.value
        libraryFillTask = nil
        if finished {
            StoreRuntimeProjection.isLibraryBackfillPending = false
            StoreRuntimeProjection.libraryBackfillCursor = nil
            SupportDiagnosticsRecorder.shared.record("Library fill finished")
            _ = await performSplitStoreReconcile(
                force: true,
                refreshMissingFeeds: false,
                reason: "library_backfill"
            )
        }
    }

    /// Moves listening history, baselines and AI content while the app is in
    /// use. Backgrounding stops it; the next launch or activation continues.
    func runDeferredMigrationIfNeeded() async {
        guard StoreCutoverState.isDeferredMigrationPending,
              deferredMigrationTask == nil,
              runtimeStoreReadiness == .ready,
              heavyStoreWorkMayRunInCurrentAppState,
              let library = preparedContainer,
              let userState = preparedUserStateContainer,
              let cache = preparedCacheContainer else { return }
        isDeferredMigrationRunning = true
        let task = Task.detached(priority: .utility) { () -> StoreCutoverOutcome in
            await StoreCutoverCoordinator.runDeferred(
                legacyContainer: library,
                userStateContainer: userState,
                cacheContainer: cache
            )
        }
        deferredMigrationTask = task
        let outcome = await task.value
        deferredMigrationTask = nil
        isDeferredMigrationRunning = false
        SupportDiagnosticsRecorder.shared.record(
            "Deferred library migration ended",
            detail: outcome.diagnosticSummary
        )
        if case .committed = outcome {
            // Only now is UserState complete enough to import back.
            _ = await performSplitStoreReconcile(
                force: true,
                refreshMissingFeeds: false,
                reason: "local_library_migration"
            )
        }
    }

    func prepareSplitStores() async {
        guard preparedContainer != nil || pendingRuntimeContainer != nil else {
            migrationReadiness = .unavailable
            migrationBlocker = "Runtime library store is not ready"
            return
        }
        if runtimeStoreReadiness == .failed {
            runtimeStoreReadiness = .settling
            initializationError = nil
            userStateInitializationError = nil
            cacheInitializationError = nil
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
        if runtimeStoreReadiness != .ready {
            migrationReadiness = .preparing
            migrationBlocker = nil
        }
        guard preparedUserStateContainer == nil || preparedCacheContainer == nil else {
            recordOpenedSplitStoreEvidenceIfNeeded()
            await finishRuntimeGraphPreparation(await buildRuntimeGraphIfNeeded())
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
                        ? Result { try Self.makeUserStateContainerWithRetry() }
                        : nil,
                    cache: needsCacheContainer
                        ? Result { try Self.makeCacheContainerWithRetry() }
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
            StoreCloudKitActivityMonitor.shared.refreshStoreIdentifiers()
            SupportDiagnosticsRecorder.shared.record(
                "User State store preparation",
                detail: preparedUserStateContainer == nil ? "open failed" : "opened"
            )
        }
        if let cache = result.cache {
            apply(
                cache,
                to: \.preparedCacheContainer,
                error: \.cacheInitializationError,
                storeName: "cache"
            )
            SupportDiagnosticsRecorder.shared.record(
                "Podcast cache store preparation",
                detail: preparedCacheContainer == nil ? "open failed" : "opened"
            )
        }

        splitStorePreparationTask = nil
        isPreparingSplitStores = false

        if runtimeProjectsFromCache {
            guard preparedUserStateContainer != nil, preparedCacheContainer != nil else {
                markRuntimeStoreInitializationFailed(
                    "Persistent storage is unavailable. Please try again."
                )
                return
            }
            recordOpenedSplitStoreEvidenceIfNeeded()
        }
        await finishRuntimeGraphPreparation(await buildRuntimeGraphIfNeeded())

        CrashBreadcrumbs.shared.record(
            "store_split_container_initialization_completed",
            details: "user_state=\(preparedUserStateContainer != nil),cache=\(preparedCacheContainer != nil)"
        )
    }

    private func recordOpenedSplitStoreEvidenceIfNeeded() {
        guard runtimeProjectsFromCache, isRuntimeGraphFixture == false else { return }
        if bootstrapMode == .freshSplitInstall {
            // Write only after both durable split stores opened. A process
            // interrupted before then must repeat fresh-install validation.
            UserDefaults.standard.set(
                true,
                forKey: StoreBootstrapEvidence.freshSplitInstallReadyKey
            )
        }
        var expected = UserDefaults.standard.stringArray(forKey: StoreLineage.key) ?? []
        for name in ["UserState.sqlite", "PodcastCache.sqlite"] where !expected.contains(name) {
            expected.append(name)
        }
        UserDefaults.standard.set(expected, forKey: StoreLineage.key)
    }

    private func markRuntimeStoreReady() {
        guard runtimeStoreReadiness != .ready else { return }
        if let pendingRuntimeContainer {
            StoreRuntimeProjection.markReady()
            preparedContainer = pendingRuntimeContainer
            self.pendingRuntimeContainer = nil
            cutoverProgress = nil
        }
        if openedExistingProjection {
            // Pick up what arrived while the app wasn't running.
            openedExistingProjection = false
            Self.requestBackgroundUserStateImport(newGeneration: false)
        }
        runtimeStoreReadiness = .ready
        migrationReadiness = .complete
        migrationBlocker = nil
        SupportDiagnosticsRecorder.shared.record("Runtime store ready")
        NotificationCenter.default.post(name: .splitRuntimeDidHydrate, object: nil)
        CrashBreadcrumbs.shared.record("runtime_store_ready")
        if pendingSplitRuntimePlaylistReconciliation {
            pendingSplitRuntimePlaylistReconciliation = false
            Task { [weak self] in
                await self?.reconcileSplitRuntimePlaylists()
            }
        }
        // This bounded repair is detached from launch readiness and yields to
        // playback, CloudKit export, cancellation, and resource pressure.
        guard isRuntimeGraphFixture == false else { return }
        Task { [weak self] in await self?.retryPortableWritesIfSafe() }
    }

    private func markRuntimeStoreInitializationFailed(_ message: String) {
        initializationError = message
        runtimeStoreReadiness = .failed
        migrationReadiness = .blocked
        migrationBlocker = message
        CrashBreadcrumbs.shared.record("runtime_store_initialization_failed")
    }

    private func finishRuntimeGraphPreparation(
        _ result: RuntimeGraphPreparationResult
    ) async {
        switch result {
        case .ready:
            markRuntimeStoreReady()
        case .failed:
            markRuntimeStoreInitializationFailed(
                "Stored library data could not be restored. Please try again."
            )
        case .interrupted:
            // A background transition cancels the owned worker. Leave readiness
            // settling so foreground entry can resume it without showing the
            // initialization failure UI for a recoverable pause.
            guard Task.isCancelled == false, heavyStoreWorkMayRunInCurrentAppState else {
                return
            }
            await prepareSplitStores()
        }
    }

    private func retryPortableWritesIfSafe() async {
        guard StoreDevelopmentConfiguration.splitStoresEnabled,
              StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false,
              let userStateContainer = preparedUserStateContainer,
              StoreSplitPlaybackGate.shared.isActive == false,
              StoreSplitCloudKitExportGate.shared.isActive == false else { return }
#if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return }
#endif
        let monitor = PortableWriteFailureMonitor.shared
        let fallbackWrites = monitor.pendingOperations()
        let due = StoreSplitPortableWriteOutbox.earliestDueOnDisk()
        guard !fallbackWrites.isEmpty || (due.map { $0 <= .now } ?? false),
              let permit = acquireMaintenancePermit(operation: "portable_write_retry_foreground") else { return }
        defer { permit.release() }

        do {
            for item in fallbackWrites {
                do {
                    try await StoreSplitPortableWriteOutbox.shared.enqueue(item.operation)
                    monitor.acknowledgeFallbackOperation(item.id)
                } catch {
                    monitor.recordDrainFailure(error)
                    return
                }
            }
            let before = try await StoreSplitPortableWriteOutbox.shared.queueDiagnostics()
            monitor.recordDrainAttempt(queueCount: before.count, oldestAge: before.oldestAge)
            let result = try await StoreSplitPortableWriteOutbox.shared.drain(
                userStateContainer: userStateContainer,
                legacyContainer: preparedContainer,
                limit: 8,
                shouldContinue: {
                    Task.isCancelled == false
                        && permit.yieldReason(
                            playbackActive: StoreSplitPlaybackGate.shared.isActive,
                            cloudKitExportActive: StoreSplitCloudKitExportGate.shared.isActive
                        ) == nil
                }
            )
            if result.failed > 0 {
                monitor.recordDrainFailures(
                    operationKinds: result.failureOperationKinds,
                    categories: result.failureCategories
                )
            }
            let after = try await StoreSplitPortableWriteOutbox.shared.queueDiagnostics()
            monitor.recordDrainSuccess(
                succeeded: result.succeeded, failed: result.failed,
                hasPending: result.hasPending, queueCount: after.count
            )
            if result.hasPending { AppDelegate.scheduleStoreSplitBackgroundProcessingIfNeeded() }
        } catch {
            monitor.recordDrainFailure(error)
        }
    }

    /// Application queries wait here instead of racing CloudKit metadata setup
    /// immediately after the runtime container object is returned.
    func waitUntilApplicationQueriesReady() async -> Bool {
        while runtimeStoreReadiness != .ready && runtimeStoreReadiness != .failed {
            guard Task.isCancelled == false else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return runtimeStoreReadiness == .ready
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
    private func buildRuntimeGraphIfNeeded() async -> RuntimeGraphPreparationResult {
        if runtimeProjectsFromCache {
            return await buildCompatibilityProjectionIfNeeded()
        } else {
            // The durable library is already the queryable runtime source.
            // Cache recovery is an additive optimization and runs after opening.
            Task(priority: .utility) { [weak self] in
                await self?.recoverCacheOnlyLibraryDataIfNeeded()
            }
            return .ready
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
        // Recovery walks the cache and can write a large legacy graph. It is
        // optional at launch and must never hitchhike on a BGProcessing grant
        // intended for bounded migration slices or feed updates.
        if force == false {
            guard isRunningBackgroundProcessingTask == false else { return empty }
#if canImport(UIKit)
            guard UIApplication.shared.applicationState != .background else { return empty }
#endif
        }
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

    /// Background work left on this device: undelivered portable writes, their
    /// repair journal, or a CloudKit import that has not reached the runtime.
    nonisolated static var hasPendingStoreSplitBackgroundWork: Bool {
        hasPendingBackgroundUserStateImport
            || StoreSplitPortableWriteOutbox.earliestDueOnDisk() != nil
            || PortableWriteFailureMonitor.hasPendingRepairOnDisk
    }

    /// A retry-only background request should not repeatedly launch before the
    /// oldest postponed item is due. Unknown or inaccessible markers remain
    /// immediately eligible so the background pass can report the failure.
    nonisolated static var nextStoreSplitBackgroundOpportunity: Date {
        guard hasPendingBackgroundUserStateImport == false else { return .now }
        var dates: [Date] = []
        if let outbox = StoreSplitPortableWriteOutbox.earliestDueOnDisk() { dates.append(outbox) }
        return max(.now, dates.min() ?? .now)
    }

    /// Persists cloud-import work and arms the metered maintenance executor.
    /// Callers may run during launch or a foreground CloudKit callback, but
    /// they must not start the whole-library projection themselves.
    nonisolated static func requestBackgroundUserStateImport(newGeneration: Bool = true) {
        StoreSplitPendingImportLedger.request(
            in: UserDefaults(suiteName: appGroupID) ?? .standard,
            newGeneration: newGeneration
        )
#if canImport(UIKit)
        Task { @MainActor in
            shared.updateSplitStoreCoordinatorState(
                currentJob: nil,
                pendingReason: "UserState reconcile scheduled for background processing"
            )
            AppDelegate.scheduleStoreSplitBackgroundProcessingIfNeeded()
        }
#endif
    }

    private nonisolated static var hasPendingBackgroundUserStateImport: Bool {
        StoreSplitPendingImportLedger.snapshot(
            in: UserDefaults(suiteName: appGroupID) ?? .standard
        ).pending
    }

    nonisolated static func clearPendingBackgroundUserStateImport(
        generation: String?
    ) {
        StoreSplitPendingImportLedger.acknowledge(
            generation, in: UserDefaults(suiteName: appGroupID) ?? .standard
        )
    }

    /// Whether this install has ever rendered from the in-memory cache
    /// projection. Set by the projection itself, so a device that only ever used
    /// the durable store never runs the recovery pass.
    nonisolated static var deviceUsedInMemoryProjection: Bool {
        UserDefaults.standard.bool(forKey: usedInMemoryProjectionKey)
    }

    private func buildCompatibilityProjectionIfNeeded() async -> RuntimeGraphPreparationResult {
        guard runtimeProjectsFromCache else { return .ready }
        if didBuildCompatibilityProjection { return .ready }
        if let compatibilityProjectionTask {
            return await compatibilityProjectionTask.value
        }
        guard let runtimeContainer = preparedContainer ?? pendingRuntimeContainer,
              let userStateContainer = preparedUserStateContainer,
              let cacheContainer = preparedCacheContainer else {
            return .failed
        }

        SupportDiagnosticsRecorder.shared.record("Runtime compatibility hydration started")
        CrashBreadcrumbs.shared.record("runtime_compatibility_hydration_started")
        // This task is manager-owned rather than a child of the launch view's
        // task, so dismissing/rebuilding that view cannot cancel local restore.
        let task = Task { [weak self] in
            guard let self else { return RuntimeGraphPreparationResult.interrupted }
            let result = await self.performCompatibilityProjection(
                runtimeContainer: runtimeContainer,
                userStateContainer: userStateContainer,
                cacheContainer: cacheContainer
            )
            switch result {
            case .ready:
                SupportDiagnosticsRecorder.shared.record("Runtime compatibility hydration finished")
                CrashBreadcrumbs.shared.record("runtime_compatibility_hydration_finished")
            case .interrupted:
                SupportDiagnosticsRecorder.shared.record("Runtime compatibility hydration interrupted")
                CrashBreadcrumbs.shared.record("runtime_compatibility_hydration_interrupted")
            case .failed:
                SupportDiagnosticsRecorder.shared.record("Runtime compatibility hydration failed")
                CrashBreadcrumbs.shared.record("runtime_compatibility_hydration_failed")
            }
            self.compatibilityProjectionTask = nil
            return result
        }
        compatibilityProjectionTask = task
        return await task.value
    }

    fileprivate func setRuntimeBuildProgress(_ fraction: Double, detail: String) {
        guard pendingRuntimeContainer != nil else { return }
        cutoverProgress = StoreCutoverProgress(fraction: fraction, detail: detail)
    }

    private func performCompatibilityProjection(
        runtimeContainer: ModelContainer,
        userStateContainer: ModelContainer,
        cacheContainer: ModelContainer
    ) async -> RuntimeGraphPreparationResult {
        // Record that this install has rendered from the in-memory projection, so
        // a later durable-store launch knows the cache may hold feed data the
        // durable store never saw.
        if isRuntimeGraphFixture == false {
            UserDefaults.standard.set(true, forKey: Self.usedInMemoryProjectionKey)
        }

        guard Task.isCancelled == false else { return .interrupted }
        let hydrationStartedAt = Date()
        let isFixture = isRuntimeGraphFixture
        let priority = isFixture ? [] : StoreSplitCompatibilityProjectionService.priorityEpisodeKeys(
            userState: userStateContainer,
            cache: cacheContainer
        )
        let resumeAfter = isFixture ? nil : StoreRuntimeProjection.cursor
        let showsProgress = pendingRuntimeContainer != nil
        let cancellation = StoreRuntimeBuildCancellation()
        if isFixture == false {
            StoreRuntimeProjection.isLibraryBackfillPending = true
            StoreRuntimeProjection.libraryBackfillCursor = nil
        }
        let worker = Task.detached(priority: .userInitiated) { () -> StoreSplitCompatibilityProjectionResult in
            StoreSplitCompatibilityProjectionService.rebuild(
                cacheContainer: cacheContainer,
                runtimeContainer: runtimeContainer,
                resumeAfter: resumeAfter,
                // Transcripts can be most of a library's rows. They fill in after
                // the app opens; only tests build them inline.
                includesTranscripts: isFixture,
                priorityEpisodes: isFixture ? nil : priority,
                shouldContinue: { cancellation.isCancelled == false },
                checkpoint: { feed in
                    if isFixture == false { StoreRuntimeProjection.cursor = feed }
                },
                progress: { done, total in
                    guard showsProgress else { return }
                    let detail = String(
                        localized: "\(done.formatted()) of \(total.formatted()) episodes"
                    )
                    let fraction = 0.9 * Double(done) / Double(max(1, total))
                    Task { @MainActor in
                        ModelContainerManager.shared.setRuntimeBuildProgress(fraction, detail: detail)
                    }
                }
            )
        }
        let projection = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            cancellation.cancel()
        }
        lastHydrationSummary = "rebuild \(Int(Date().timeIntervalSince(hydrationStartedAt))) s, podcasts=\(projection.podcasts), episodes=\(projection.episodes), chapters=\(projection.chapters), transcriptLines=\(projection.transcriptLines), sessions=\(projection.playSessions), failed=\(projection.failed), footprint=\(MemoryFootprint.current() / (1024 * 1024)) MB"
        CrashBreadcrumbs.shared.record(
            "store_split_compatibility_projection_completed",
            details: "podcasts=\(projection.podcasts),episodes=\(projection.episodes),failed=\(projection.failed)"
        )
        guard Task.isCancelled == false, projection.interrupted == false else { return .interrupted }
        guard projection.failed == 0 else { return .failed }
        if showsProgress {
            setRuntimeBuildProgress(0.92, detail: String(localized: "Restoring your playback progress and playlists"))
        }

        let result = await StoreSplitUserStateImporter.apply(
            legacyContainer: runtimeContainer,
            userStateContainer: userStateContainer,
            cacheContainer: cacheContainer,
            authoritativePlaylists: false,
            projectListeningHistoryToLegacy: true,
            episodeStateProjectionRecencyCutoff: StoreDevelopmentConfiguration
                .episodeStateProjectionRecencyCutoff,
            isInitialRuntimeHydration: true
        )
        guard Task.isCancelled == false else { return .interrupted }
        guard result.failed == 0, result.interruptedByPlayback == false else {
            return result.interruptedByPlayback ? .interrupted : .failed
        }

        if showsProgress {
            setRuntimeBuildProgress(0.97, detail: String(localized: "Updating your statistics"))
        }
        await PlaySessionTrackerActor(
            modelContainer: runtimeContainer
        ).rebuildListeningStats()
        guard Task.isCancelled == false else { return .interrupted }
        didBuildCompatibilityProjection = true
        return .ready
    }

    /// Reads only compact UserState rows and returns the feeds whose episodes
    /// must be present before the first playlist frame is projected. Rows are
    /// newest-first so a tombstone suppresses an older duplicate delivery.
    func priorityRecoveryFeedURLs(
        _ userStateContainer: ModelContainer,
        after cursor: String?,
        limit: Int
    ) -> (feeds: [URL], lastKey: String?, reachedEnd: Bool) {
        let context = ModelContext(userStateContainer)
        var queueDescriptor = FetchDescriptor<QueueEntrySync>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        queueDescriptor.fetchLimit = 500
        var playlistDescriptor = FetchDescriptor<PlaylistEntrySync>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        playlistDescriptor.fetchLimit = 1_500
        var bookmarkDescriptor = FetchDescriptor<BookmarkSync>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        bookmarkDescriptor.fetchLimit = 500
        var recentPlaybackDescriptor = FetchDescriptor<EpisodeStateSync>(
            sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)]
        )
        recentPlaybackDescriptor.fetchLimit = 500

        var seenRecordIDs = Set<String>()
        var seenFeedKeys = Set<String>()
        var result: [URL] = []
        typealias PriorityFeedReference = (
            id: String,
            feedURL: String,
            isDeleted: Bool,
            deletedAt: Date?
        )
        let queueRows: [PriorityFeedReference] =
            ((try? context.fetch(queueDescriptor)) ?? []).map {
                (id: "queue:\($0.id)", feedURL: $0.feedURL,
                 isDeleted: $0.isDeleted, deletedAt: $0.deletedAt)
            }
        let playlistRows: [PriorityFeedReference] =
            ((try? context.fetch(playlistDescriptor)) ?? []).map {
                (id: "playlist:\($0.id)", feedURL: $0.feedURL,
                 isDeleted: $0.isDeleted, deletedAt: $0.deletedAt)
            }
        let bookmarkRows: [PriorityFeedReference] =
            ((try? context.fetch(bookmarkDescriptor)) ?? []).map {
                (id: "bookmark:\($0.id)", feedURL: $0.feedURL,
                 isDeleted: $0.isDeleted, deletedAt: $0.deletedAt)
            }
        let recentPlaybackRows: [PriorityFeedReference] =
            ((try? context.fetch(recentPlaybackDescriptor)) ?? []).map {
                (id: "recent:\($0.id)", feedURL: $0.feedURL,
                 isDeleted: false, deletedAt: nil)
            }
        let rows = queueRows + playlistRows + bookmarkRows + recentPlaybackRows
        for row in rows {
            guard seenRecordIDs.insert(row.id).inserted,
                  row.isDeleted == false,
                  row.deletedAt == nil,
                  let feed = URL(string: row.feedURL) else { continue }
            let key = PodcastFeedIdentity.normalizedFeedURLString(feed)
            guard seenFeedKeys.insert(key).inserted else { continue }
            result.append(feed)
        }
        let ordered = result.sorted {
            PodcastFeedIdentity.normalizedFeedURLString($0)
                < PodcastFeedIdentity.normalizedFeedURLString($1)
        }
        let pending = ordered.filter {
            guard let cursor else { return true }
            return PodcastFeedIdentity.normalizedFeedURLString($0) > cursor
        }
        let selected = Array(pending.prefix(max(0, limit)))
        let lastKey = selected.last.map(PodcastFeedIdentity.normalizedFeedURLString)
        return (selected, lastKey, pending.count <= selected.count)
    }

    func runLaunchStoreMaintenance() async {
#if DEBUG
        // The unsigned simulator XCTest host has no usable CloudKit container.
        // Test cases create their own in-memory stores and must not start the
        // app's delayed iCloud maintenance in parallel with those stores.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            return
        }
        guard developmentResetRequiresRelaunch == false else {
            recordMigrationBlocker("Development reset requires a relaunch")
            return
        }
#endif
        await prepareSplitStores()
        if let userStateContainer = preparedUserStateContainer {
            await StoreSplitPlaylistPresenceStore.publish(
                modelContainer: userStateContainer
            )
        }
        await prunePlayedPlaylistEntries()
        await splitStoreCoordinator.scheduleLaunchWork()
        if let userState = preparedUserStateContainer {
            let library = runtimeProjectsFromCache ? nil : preparedContainer
            Task.detached(priority: .background) {
                ListeningTotalsDiagnostics.capture(userState: userState, library: library)
            }
        }
        Task(priority: .utility) { [weak self] in
            async let transcripts: Void? = self?.runLibraryBackfillIfNeeded()
            await self?.runDeferredMigrationIfNeeded()
            _ = await transcripts
        }
#if canImport(UIKit)
        // Arm the background pass now rather than waiting for a clean
        // background transition, which a force-quit never delivers.
        AppDelegate.scheduleStoreSplitBackgroundProcessingIfNeeded()
#endif
    }

#if DEBUG
    func splitStoreCacheDevelopmentStatus() async throws -> StoreSplitCacheDevelopmentStatus {
        await prepareSplitStores()
        guard let legacyContainer = preparedContainer,
              let cacheContainer = preparedCacheContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        return await Task.detached(priority: .utility) {
            StoreSplitCacheDevelopmentStatus.read(
                legacyContainer: legacyContainer,
                cacheContainer: cacheContainer
            )
        }.value
    }
#endif

    /// Entry point for the `BGProcessingTask` (the identifier is unchanged from
    /// the migration era). The one-time library migration now runs in the
    /// foreground; this pass only drains the portable-write outbox and repair
    /// journal and applies a pending CloudKit user-state import.
    func runStoreSplitBackgroundPass() async {
        await withBackgroundProcessingWindow {
            guard self.isRunningBackgroundProcessingTask,
                  Self.hasPendingStoreSplitBackgroundWork,
                  Player.hasActivePlaybackInProcess == false,
                  StoreSplitTaskCancellation.shouldBeginStoreWork(
                      isCancelled: Task.isCancelled
                  ) else {
                CrashBreadcrumbs.shared.record(
                    "store_split_background_pass_skipped",
                    details: "pending=\(Self.hasPendingStoreSplitBackgroundWork),playing=\(Player.hasActivePlaybackInProcess),background=\(self.isRunningBackgroundProcessingTask)"
                )
                return
            }
            await prepareContainer()
            guard preparedContainer != nil, Task.isCancelled == false else { return }
            // Let a CloudKit export that opening the stores resumed settle
            // before adding writes to the same SQLite/CloudKit backlog.
            guard await StoreCloudKitActivityMonitor.shared
                .waitForExportQuiescence(maximumDuration: 3) else {
                pendingSplitStoreWorkReason = "waiting for CloudKit export to settle"
                return
            }
            guard Task.isCancelled == false else { return }
            await prepareSplitStores()
            guard Task.isCancelled == false else { return }
            let recoveryMonitor = PortableWriteFailureMonitor.shared
            let fallbackWrites = recoveryMonitor.pendingOperations()
            let outboxDue = StoreSplitPortableWriteOutbox.earliestDueOnDisk()
            if (!fallbackWrites.isEmpty || (outboxDue.map { $0 <= .now } ?? false)),
               let userStateContainer = preparedUserStateContainer,
               let permit = acquireMaintenancePermit(operation: "portable_write_retry") {
                do {
                    // Move fallback payloads into the file-backed outbox before
                    // acknowledging them in the compact recovery journal.
                    for item in fallbackWrites {
                        do {
                            try await StoreSplitPortableWriteOutbox.shared.enqueue(item.operation)
                            recoveryMonitor.acknowledgeFallbackOperation(item.id)
                        } catch {
                            recoveryMonitor.recordDrainFailure(error)
                            break
                        }
                    }
                    let queueBeforeDrain = try await StoreSplitPortableWriteOutbox.shared.queueDiagnostics()
                    recoveryMonitor.recordDrainAttempt(
                        queueCount: queueBeforeDrain.count,
                        oldestAge: queueBeforeDrain.oldestAge
                    )
                    let result = try await StoreSplitPortableWriteOutbox.shared.drain(
                        userStateContainer: userStateContainer,
                        // Bookmark deletion intents confirm against the live
                        // runtime graph, which already applied the local delete.
                        legacyContainer: preparedContainer,
                        shouldContinue: {
                            Task.isCancelled == false
                                && permit.yieldReason(
                                    playbackActive: StoreSplitPlaybackGate.shared.isActive,
                                    cloudKitExportActive: StoreSplitCloudKitExportGate.shared.isActive
                                ) == nil
                        }
                    )
                    if result.failed > 0 {
                        recoveryMonitor.recordDrainFailures(
                            operationKinds: result.failureOperationKinds,
                            categories: result.failureCategories
                        )
                    }
                    CrashBreadcrumbs.shared.record(
                        "store_split_portable_write_retry",
                        details: "attempted=\(result.attempted),succeeded=\(result.succeeded),failed=\(result.failed),pending=\(result.hasPending),queue=\(queueBeforeDrain.count)/\(queueBeforeDrain.capacity)"
                    )
                    let queueAfterDrain = try await StoreSplitPortableWriteOutbox.shared.queueDiagnostics()
                    recoveryMonitor.recordDrainSuccess(
                        succeeded: result.succeeded,
                        failed: result.failed,
                        hasPending: result.hasPending,
                        queueCount: queueAfterDrain.count
                    )
                    if result.failed > 0 { pendingSplitStoreWorkReason = "Portable writes need retry" }
                } catch {
                    recoveryMonitor.recordDrainFailure(error)
                    pendingSplitStoreWorkReason = "Portable write retry is unavailable"
                    CrashBreadcrumbs.shared.record("store_split_portable_write_retry_failed")
                }
                permit.release()
            }
            guard Task.isCancelled == false else { return }
            let importRequest = StoreSplitPendingImportLedger.snapshot(
                in: UserDefaults(suiteName: Self.appGroupID) ?? .standard
            )
            if importRequest.pending,
               Player.hasActivePlaybackInProcess == false,
               Task.isCancelled == false {
                if let permit = acquireMaintenancePermit(operation: "user_state_reconciliation") {
                    let result = await performSplitStoreReconcile(
                        authoritativePlaylists: false,
                        force: true,
                        refreshMissingFeeds: true,
                        reason: "cloud_import_background"
                    )
                    permit.release()
                    if result == .completed {
                        Self.clearPendingBackgroundUserStateImport(
                            generation: importRequest.generation
                        )
                    }
                }
            }
        }
    }

    func pauseSplitStoreWorkForBackground() {
        // Everything stops on backgrounding. Letting the backfill continue on the
        // audio session's process time looked attractive, but the loop it kept
        // alive ran at ~98% CPU for hours and the process was killed by the CPU
        // limit. Background progress belongs to the metered `BGProcessingTask`,
        // which has a budget and an expiration handler.
        deferredMigrationTask?.cancel()
        libraryFillTask?.cancel()
        Task { await StoreSplitFeedCacheWriter.flushRequestedProjections() }
        userStateImportTask?.cancel()
        aiContentImportTask?.cancel()
        compatibilityProjectionTask?.cancel()
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
        Task(priority: .utility) { [weak self] in
            async let transcripts: Void? = self?.runLibraryBackfillIfNeeded()
            await self?.runDeferredMigrationIfNeeded()
            _ = await transcripts
        }
    }

    /// Runs `body` inside a declared background-processing window, so store
    /// maintenance knows it may keep working while the app is not in the
    /// foreground.
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
                isRunning: false,
                lastSliceStatus: nil,
                lastSliceProcessed: 0,
                lastSliceError: nil,
                currentJob: currentSplitStoreJobDescription,
                pendingReason: pendingSplitStoreWorkReason
            )
        }
        return StoreSplitMigrationDiagnostics.migrationStatus(
            cacheContext: cacheContainer.mainContext,
            userStateContext: userStateContainer.mainContext,
            legacyContext: preparedContainer.map { ModelContext($0) },
            isRunning: false,
            readiness: migrationReadiness,
            blocker: migrationBlocker,
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
        guard userStateImportTask == nil else {
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
        // The runtime graph has no other route for changes imported from other
        // devices, so this can't wait for a charging night. Heavy-work and
        // playback guards below still apply, and foreground callers are
        // throttled by `shouldRunUserStateImport`.
        guard StoreCutoverState.isDeferredMigrationPending == false else { return .skipped }
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            lastSplitStoreReconcileSummary = "Paused for stability"
            pendingSplitStoreWorkReason = "paused for stability"
            currentSplitStoreJobDescription = nil
            return .skipped
        }
        guard StoreSplitMaintenancePolicy.shouldYieldForCloudKitExport(
            exportInProgress: cloudKitExportInProgress()
        ) == false else {
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
        guard Task.isCancelled == false,
              StoreDevelopmentConfiguration.userStateImportEnabled else { return .skipped }
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
        if Task.isCancelled || result.failed > 0 || result.interruptedByPlayback {
            lastSplitStoreReconcileSummary = "User State import was interrupted or failed"
            pendingSplitStoreWorkReason = "User State import needs retry"
            if reason.contains("cloud_import") || authoritativePlaylists {
                StoreCloudKitActivityMonitor.shared.recordReconciliation(
                    for: .userState,
                    succeeded: false,
                    summary: "User State import was interrupted or failed"
                )
            }
            return result.interruptedByPlayback ? .deferredForPlayback : .skipped
        }
        // An import is the one moment when playlist entries authored elsewhere —
        // including records that predate the tombstone rules — land in the local
        // queue. Re-assert "a played episode is not a queue member" right after.
        await prunePlayedPlaylistEntries()
        guard Task.isCancelled == false else { return .skipped }
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

    /// Removes finished episodes that are still queued, and tombstones them so the
    /// removal survives the next CloudKit round trip.
    func prunePlayedPlaylistEntries() async {
        guard let legacyContainer = preparedContainer else { return }
        await PlayedEpisodePlaylistPruner(legacyContainer: legacyContainer).prune()
    }

#if DEBUG
    // MARK: - Incident recovery (development builds only)
    //
    // Deduplication, tombstone recovery and listening-statistics rebuilds
    // operate on the runtime library graph and the UserState store.

    /// Recomputes the hourly buckets and every `PlaySessionSummary` from the raw
    /// `PlaySession` rows.
    ///
    /// This is the analytics rebuild to reach for after a bad merge, and since
    /// the synced store stopped carrying aggregates it is the only thing that
    /// recomputes them: summaries are now a purely local derivation.
    func rebuildAnalyticsFromRawSessions() async throws {
        guard let legacyContainer = preparedContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        await PlaySessionTrackerActor(modelContainer: legacyContainer)
            .rebuildListeningStats()
    }

    /// Collapses duplicate podcasts/episodes and repairs playlist membership.
    /// `dryRun` reports what would change without writing.
    func deduplicateLibrary(dryRun: Bool) async throws -> LibraryDeduplicationReport {
        guard let legacyContainer = preparedContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        return await LibraryDeduplicationService(legacyContainer: legacyContainer)
            .run(dryRun: dryRun)
    }

    /// Reports where the queue currently lives, across both stores.
    func playlistTombstoneReport() async throws -> [String] {
        await prepareSplitStores()
        guard let userStateContainer = preparedUserStateContainer else {
            throw StoreSplitDevelopmentResetError.storesUnavailable
        }
        return await PlaylistTombstoneRecoveryService(
            userStateContainer: userStateContainer
        ).diagnosticsReport(legacyContainer: preparedContainer)
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

    func rebuildListeningSummariesForDevelopment() async throws
        -> StoreSplitMigrationPhaseResult {
        await prepareSplitStores()
        guard let legacyContainer = preparedContainer,
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
        guard let legacyContainer = preparedContainer else {
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
        guard aiContentImportTask == nil,
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
            lastAIContentImportAt = nil
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

    private func recordMigrationBlocker(_ reason: String) {
        migrationReadiness = .blocked
        migrationBlocker = reason
        pendingSplitStoreWorkReason = reason
        CrashBreadcrumbs.shared.record(
            "store_split_migration_blocked",
            details: reason
        )
    }

    private func cloudKitExportInProgress() -> Bool {
        guard StoreDevelopmentConfiguration.userStateCloudSyncEnabled else {
            return false
        }
        // SyncMonitor.default.exportState is an aggregate UI summary. Scheduling
        // decisions must use the store-aware Core Data event monitor.
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

    private func acquireMaintenancePermit(operation: String) -> StoreMaintenancePermit? {
        StoreMaintenanceResourceBudget.shared.acquire(
            operation: operation,
            playbackActive: Player.hasActivePlaybackInProcess
                || StoreSplitPlaybackGate.shared.isActive,
            cloudKitExportActive: cloudKitExportInProgress()
        )
    }

    /// Lightweight playlist hydration for split-only runtimes. Legacy upgrade
    /// reads retain their shipping authority and background migration policy.
    func reconcileSplitRuntimePlaylists() async {
        // Until this device's own data has reached UserState, the library is the
        // more complete record; the migration imports when it finishes.
        guard StoreCutoverState.isDeferredMigrationPending == false else { return }
        guard runtimeStoreReadiness == .ready,
              let runtime = preparedContainer,
              let userState = preparedUserStateContainer,
              let cache = preparedCacheContainer else {
            pendingSplitRuntimePlaylistReconciliation = true
            return
        }
        SupportDiagnosticsRecorder.shared.record("Playlist hydration started")
        guard await buildCompatibilityProjectionIfNeeded() == .ready else {
            pendingSplitRuntimePlaylistReconciliation = true
            return
        }
        if let userStateImportTask {
            pendingSplitRuntimePlaylistReconciliation = true
            _ = await userStateImportTask.value
            return
        }
        pendingSplitRuntimePlaylistReconciliation = false
        let task = Task {
            await StoreSplitUserStateImporter.apply(
                legacyContainer: runtime,
                userStateContainer: userState,
                cacheContainer: cache,
                authoritativePlaylists: false,
                projectListeningHistoryToLegacy: false,
                changedStreams: [.playlists]
            )
        }
        userStateImportTask = task
        let result = await task.value
        userStateImportTask = nil
        if result.failed > 0 {
            pendingSplitRuntimePlaylistReconciliation = true
        }
        NotificationCenter.default.post(name: .splitRuntimeDidHydrate, object: nil)
        SupportDiagnosticsRecorder.shared.record(
            "Playlist hydration finished",
            detail: result.failed == 0 ? "completed" : "deferred (local operation failed)"
        )
        CrashBreadcrumbs.shared.record("split_runtime_playlist_import", details: "failed=\(result.failed),pending_feeds=\(result.playlistFeedsToBootstrap.count)")
        if result.failed == 0, pendingSplitRuntimePlaylistReconciliation {
            pendingSplitRuntimePlaylistReconciliation = false
            await reconcileSplitRuntimePlaylists()
        }
    }

    private func applySyncedUserStateIfPossible(
        authoritativePlaylists: Bool = false,
        refreshMissingFeeds: Bool = false
    ) async -> StoreSplitUserStateImportResult {
        let emptyResult = StoreSplitUserStateImportResult()
        func deferredResult() -> StoreSplitUserStateImportResult {
            var result = emptyResult
            result.failed = 1
            return result
        }
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            return deferredResult()
        }
        guard StoreDevelopmentConfiguration.userStateImportEnabled else { return deferredResult() }
        guard StoreSplitMaintenancePolicy.shouldYieldForCloudKitExport(
            exportInProgress: cloudKitExportInProgress()
        ) == false else {
            pendingSplitStoreWorkReason = "waiting for CloudKit export to drain"
            return deferredResult()
        }
        if let userStateImportTask {
            _ = await userStateImportTask.value
        }
        guard Task.isCancelled == false,
              cloudKitExportInProgress() == false else { return deferredResult() }
        guard let legacyContainer = preparedContainer,
              let userStateContainer = preparedUserStateContainer,
              let cacheContainer = preparedCacheContainer else {
            return deferredResult()
        }

        // Each synchronized stream has its own cursor. Playback progress must
        // not unlock subscription, playlist, bookmark, preference, or history
        // projections, and a no-op CloudKit notification must not walk the whole
        // library again.
        let changeStamps: [StoreSplitUserStateStream: StoreSplitUserStateChangeSnapshot]
        do {
            changeStamps = try latestUserStateChangeStamps(userStateContainer)
        } catch {
            var result = emptyResult
            result.failed = 1
            CrashBreadcrumbs.shared.record("store_split_import_change_snapshot_failed")
            return result
        }
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
                        cacheContainer: cacheContainer,
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
            // An unresolved playlist/queue reference is stronger evidence than
            // the general missing-feed bootstrap preference: fetch that exact
            // feed so the referenced episode can be projected before the user
            // sees the membership as hydrated.
            let hasPlaylistEpisodeMisses = result.playlistFeedsToBootstrap.isEmpty == false
            guard result.failed == 0, result.interruptedByPlayback == false,
                  (refreshMissingFeeds || hasPlaylistEpisodeMisses),
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
                    ).updatePodcast(feed, policy: .validatedImport, silent: true)
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
        var result = await StoreSplitTaskCancellation.awaitValue(of: task)
        userStateImportTask = nil
        guard Task.isCancelled == false else {
            result.failed += 1
            return result
        }
        guard result.failed == 0, result.interruptedByPlayback == false else { return result }
        // Only rebuild the hourly statistics when history actually moved.
        // Rebuilding after every reconcile rewrote the whole stats table for no
        // reason and was a large part of the write volume.
        if result.listeningHistoryApplied > 0 {
            await PlaySessionTrackerActor(
                modelContainer: legacyContainer
            ).rebuildListeningStats()
            guard Task.isCancelled == false else {
                result.failed += 1
                return result
            }
        }
        await StoreSplitPlaylistPresenceStore.publish(
            modelContainer: userStateContainer
        )
        guard Task.isCancelled == false else {
            result.failed += 1
            return result
        }
        if result.failed == 0, result.interruptedByPlayback == false {
            let streamsToCommit = StoreSplitImportCursorStore.streamsEligibleForCommit(
                changedStreams: changedStreams,
                hasUnresolvedPlaylistEpisodes: result.playlistFeedsToBootstrap.isEmpty == false
            ).subtracting(result.unresolvedStreams)
            StoreSplitImportCursorStore.commit(
                changeStamps,
                streams: streamsToCommit
            )
            lastUserStateImportAt = .now
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
    func latestUserStateChangeStamps(
        _ container: ModelContainer
    ) throws -> [StoreSplitUserStateStream: StoreSplitUserStateChangeSnapshot] {
        let context = ModelContext(container)
        func snapshot<Model>(
            latest: () throws -> Model?,
            date: (Model) -> Date,
            idsAtDate: (Date) throws -> [String]
        ) throws -> StoreSplitUserStateChangeSnapshot {
            guard let latest = try latest() else {
                return StoreSplitUserStateChangeSnapshot(date: nil, recordIDsAtTimestamp: [])
            }
            let latestDate = date(latest)
            return StoreSplitUserStateChangeSnapshot(
                date: latestDate,
                recordIDsAtTimestamp: try idsAtDate(latestDate).sorted()
            )
        }

        func latest<Model: PersistentModel>(
            _ type: Model.Type,
            sort: SortDescriptor<Model>
        ) throws -> Model? {
            var descriptor = FetchDescriptor<Model>(sortBy: [sort])
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        }

        // A timestamp shared by an unusually large number of records cannot
        // be safely represented by the existing cursor without loading the
        // whole group. Leave the import pending instead of recording a partial
        // boundary that could hide later arrivals.
        func idsAtDate<Model: PersistentModel>(
            _ descriptor: FetchDescriptor<Model>, id: KeyPath<Model, String>
        ) throws -> [String] {
            var bounded = descriptor
            bounded.fetchLimit = 501
            let rows = try context.fetch(bounded)
            guard rows.count <= 500 else { throw PlaylistPersistenceError.storageUnavailable }
            return rows.map { $0[keyPath: id] }
        }

        return [
            .subscriptions: try snapshot(
                latest: { try latest(SubscriptionSync.self, sort: SortDescriptor(\SubscriptionSync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    try idsAtDate(FetchDescriptor<SubscriptionSync>(predicate: #Predicate { $0.updatedAt == date }), id: \.id)
                }
            ),
            .episodeState: try snapshot(
                latest: { try latest(EpisodeStateSync.self, sort: SortDescriptor(\EpisodeStateSync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    try idsAtDate(FetchDescriptor<EpisodeStateSync>(predicate: #Predicate { $0.updatedAt == date }), id: \.id)
                }
            ),
            .playlists: try snapshot(
                latest: { try latest(PlaylistSync.self, sort: SortDescriptor(\PlaylistSync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    try idsAtDate(FetchDescriptor<PlaylistSync>(predicate: #Predicate { $0.updatedAt == date }), id: \.id)
                }
            ),
            .playlistEntries: try snapshot(
                latest: { try latest(PlaylistEntrySync.self, sort: SortDescriptor(\PlaylistEntrySync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    try idsAtDate(FetchDescriptor<PlaylistEntrySync>(predicate: #Predicate { $0.updatedAt == date }), id: \.id)
                }
            ),
            .queueEntries: try snapshot(
                latest: { try latest(QueueEntrySync.self, sort: SortDescriptor(\QueueEntrySync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    try idsAtDate(FetchDescriptor<QueueEntrySync>(predicate: #Predicate { $0.updatedAt == date }), id: \.id)
                }
            ),
            .bookmarks: try snapshot(
                latest: { try latest(BookmarkSync.self, sort: SortDescriptor(\BookmarkSync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    try idsAtDate(FetchDescriptor<BookmarkSync>(predicate: #Predicate { $0.updatedAt == date }), id: \.id)
                }
            ),
            .preferences: try snapshot(
                latest: { try latest(PodcastPreferenceSync.self, sort: SortDescriptor(\PodcastPreferenceSync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    try idsAtDate(FetchDescriptor<PodcastPreferenceSync>(predicate: #Predicate { $0.updatedAt == date }), id: \.id)
                }
            ),
            .listeningHistory: try snapshot(
                latest: { try latest(ListeningHistorySync.self, sort: SortDescriptor(\ListeningHistorySync.updatedAt, order: .reverse)) },
                date: { $0.updatedAt },
                idsAtDate: { date in
                    try idsAtDate(FetchDescriptor<ListeningHistorySync>(predicate: #Predicate { $0.updatedAt == date }), id: \.id)
                }
            ),
            .listeningBaseline: try snapshot(
                latest: { try latest(ListeningBaselineSync.self, sort: SortDescriptor(\ListeningBaselineSync.capturedAt, order: .reverse)) },
                date: { $0.capturedAt },
                idsAtDate: { date in
                    try idsAtDate(FetchDescriptor<ListeningBaselineSync>(predicate: #Predicate { $0.capturedAt == date }), id: \.id)
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
        guard StoreSplitMaintenancePolicy.shouldYieldForCloudKitExport(
            exportInProgress: cloudKitExportInProgress()
        ) == false else {
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
            let result = await aiContentImportTask.value
            if result.failed > 0 {
                pendingSplitStoreWorkReason = "AI PodcastCache import has retryable failures"
            }
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
            await StoreSplitAIContentImporter.apply(
                legacyContainer: legacyContainer,
                cacheContainer: cacheContainer
            )
        }
        aiContentImportTask = task
        let result = await task.value
        aiContentImportTask = nil
        if result.failed > 0 {
            pendingSplitStoreWorkReason = "AI PodcastCache import has retryable failures"
        } else {
            lastAIContentImportAt = .now
            if pendingSplitStoreWorkReason == "AI PodcastCache import has retryable failures" {
                pendingSplitStoreWorkReason = nil
            }
        }
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

    /// The legacy-model container is never attached to CloudKit: it is either
    /// the in-memory runtime graph or an explicit, local file (the frozen
    /// backup being read for the one-time migration).
    nonisolated static func makeLegacyContainer(
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true,
        storageURL: URL? = nil
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if isStoredInMemoryOnly {
            configuration = ModelConfiguration(
                "Legacy",
                isStoredInMemoryOnly: true,
                allowsSave: allowsSave,
                cloudKitDatabase: .none
            )
        } else if let storageURL {
            configuration = ModelConfiguration(
                "Legacy",
                url: storageURL,
                allowsSave: allowsSave,
                cloudKitDatabase: .none
            )
        } else {
            throw PlaylistPersistenceError.storageUnavailable
        }

        let openStartedAt = ProcessInfo.processInfo.systemUptime
        let cpuStartedAt = SystemProcessCPUTimeSource().sample().cpuTime
        let container: ModelContainer
        do {
            container = try ModelContainer(
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
        } catch {
            AppDiagnostics.log(
                "model_container_open_failed store=legacy duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - openStartedAt) * 1_000))"
            )
            throw error
        }
        AppDiagnostics.log(
            "model_container_opened store=legacy duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - openStartedAt) * 1_000)) process_cpu_seconds_delta=\(String(format: "%.2f", max(0, SystemProcessCPUTimeSource().sample().cpuTime - cpuStartedAt))) cloudkit_attached=false"
        )
        return container
    }

    nonisolated private static func makeLegacyContainerWithRetry(
        isStoredInMemoryOnly: Bool
    ) throws -> ModelContainer {
        let attempts = isStoredInMemoryOnly ? 1 : 3
        return try makeContainerWithRetry(store: "legacy", attempts: attempts) {
            try makeLegacyContainer(isStoredInMemoryOnly: isStoredInMemoryOnly)
        }
    }

    nonisolated private static func makeUserStateContainerWithRetry() throws -> ModelContainer {
        try makeContainerWithRetry(store: "user_state", attempts: 3) {
            try makeUserStateContainer()
        }
    }

    nonisolated private static func makeCacheContainerWithRetry() throws -> ModelContainer {
        try makeContainerWithRetry(store: "cache", attempts: 3) {
            try makeCacheContainer()
        }
    }

    nonisolated private static func makeContainerWithRetry(
        store: String,
        attempts: Int,
        open: () throws -> ModelContainer
    ) throws -> ModelContainer {
        for attempt in 0..<max(1, attempts) {
            do { return try open() }
            catch {
                guard attempt + 1 < max(1, attempts) else { break }
                CrashBreadcrumbs.shared.record(
                    "model_container_open_retry",
                    details: "store=\(store),attempt=\(attempt + 1)"
                )
                Thread.sleep(forTimeInterval: attempt == 0 ? 0.12 : 0.28)
            }
        }
        AppDiagnostics.log("model_container_open_exhausted store=\(store)")
        throw StoreBootstrapError.persistentStoreUnavailable
    }

    nonisolated static func makeUserStateContainer(
        isStoredInMemoryOnly: Bool = false,
        storageURL: URL? = nil
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
        } else if let storageURL {
            configuration = ModelConfiguration("UserState", schema: schema, url: storageURL, cloudKitDatabase: .none)
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
            throw PlaylistPersistenceError.storageUnavailable
        }

        let openStartedAt = ProcessInfo.processInfo.systemUptime
        let cpuStartedAt = SystemProcessCPUTimeSource().sample().cpuTime
        do {
            let container = try ModelContainer(for: schema, configurations: configuration)
            AppDiagnostics.log(
                "model_container_opened store=user_state duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - openStartedAt) * 1_000)) process_cpu_seconds_delta=\(String(format: "%.2f", max(0, SystemProcessCPUTimeSource().sample().cpuTime - cpuStartedAt))) cloudkit_attached=\(StoreDevelopmentConfiguration.userStateCloudSyncEnabled)"
            )
            return container
        } catch {
            AppDiagnostics.log(
                "model_container_open_failed store=user_state duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - openStartedAt) * 1_000))"
            )
            throw error
        }
    }

    nonisolated static func makeCacheContainer(
        isStoredInMemoryOnly: Bool = false,
        storageURL: URL? = nil
    ) throws -> ModelContainer {
        let schema = Schema([
            StoreSplitMigrationCheckpoint.self,
            CachedMissingEpisodeReference.self,
            CachedListeningBaselineAggregate.self,
            CachedListeningBaselineSource.self,
            StoreSplitMigrationVerification.self,
            StoreSplitFeedCacheCheckpoint.self,
            CachedFeedExtensionElement.self,
            AppliedAIContentRevision.self,
            CachedPodcast.self,
            CachedEpisode.self,
            CachedChapter.self,
            CachedTranscriptLine.self,
            CachedTranscriptAlignment.self,
            CachedTranscriptSynchronizationJob.self,
            CachedTranscriptionRecord.self,
            CachedDownloadRecord.self,
            CachedPlaySession.self,
            CachedRateSegment.self,
            CachedHourlyListeningStat.self,
            CachedPodcastLocalSettings.self,
            CachedBookmarkDetail.self,
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
        } else if let storageURL {
            configuration = ModelConfiguration("PodcastCache", schema: schema, url: storageURL, cloudKitDatabase: .none)
        } else if let cacheStoreURL {
            configuration = ModelConfiguration(
                "PodcastCache",
                schema: schema,
                url: cacheStoreURL,
                cloudKitDatabase: .none
            )
        } else {
            throw PlaylistPersistenceError.storageUnavailable
        }

        let openStartedAt = ProcessInfo.processInfo.systemUptime
        let cpuStartedAt = SystemProcessCPUTimeSource().sample().cpuTime
        do {
            let container = try ModelContainer(for: schema, configurations: configuration)
            AppDiagnostics.log(
                "model_container_opened store=podcast_cache duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - openStartedAt) * 1_000)) process_cpu_seconds_delta=\(String(format: "%.2f", max(0, SystemProcessCPUTimeSource().sample().cpuTime - cpuStartedAt))) cloudkit_attached=false"
            )
            return container
        } catch {
            AppDiagnostics.log(
                "model_container_open_failed store=podcast_cache duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - openStartedAt) * 1_000))"
            )
            throw error
        }
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

private final class StoreRuntimeBuildCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private struct SplitStoreContainers: @unchecked Sendable {
    let userState: Result<ModelContainer, Error>?
    let cache: Result<ModelContainer, Error>?
}
