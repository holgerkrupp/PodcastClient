import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Durable, local repair journal for portable writes that could not enter the
/// normal outbox. This reports local repair progress only; it is not evidence
/// that CloudKit has exported the resulting UserState records.
@MainActor
final class PortableWriteFailureMonitor: ObservableObject {
    static let shared = PortableWriteFailureMonitor()

    nonisolated static var hasPendingRepairOnDisk: Bool {
        (UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard)
            .bool(forKey: "portableWriteRecoveryPending")
    }

    private static let key = "portableWriteRecoveryState.v2"
    private static let maximumFallbackOperations = 512

    struct Incident: Codable, Sendable {
        let id: UUID
        let operationKind: String
        let failureStage: String
        let errorCategory: String
        let occurredAt: Date
    }

    struct PendingOperation: Codable, Sendable, Identifiable {
        let id: UUID
        let operation: StoreSplitPortableWriteOutbox.Operation
        let recordedAt: Date
    }

    struct State: Codable, Sendable {
        var repairNeeded = false
        var requiresReconstruction = false
        var incidents: [Incident] = []
        var pendingOperations: [PendingOperation] = []
        var firstRetryAt: Date?
        var lastRetryAt: Date?
        var lastSuccessfulRepairAt: Date?
        var lastDrainAttemptAt: Date?
        var lastDrainSucceededAt: Date?
        var lastDrainFailedAt: Date?
        var latestDrainFailureCategory: String?
        var latestQueueCount: Int?
        var latestQueueCapacity: Int = 512
        var latestQueueOldestAgeSeconds: Int?

        var status: Status {
            if repairNeeded {
                if requiresReconstruction { return .requiresAttention }
                return pendingOperations.isEmpty ? .pending : .recovering
            }
            if lastSuccessfulRepairAt != nil { return .recovered }
            return .idle
        }
    }

    enum Status: String, Codable, Sendable, Equatable {
        case idle
        case pending
        case recovering
        case requiresAttention
        case recovered
    }

    private let defaults: UserDefaults
    @Published private(set) var state: State
    var needsRecovery: Bool { state.repairNeeded }

    init(defaults: UserDefaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            // Migrate the historical one-way warning into a quiet repair marker.
            let oldWarning = defaults.bool(forKey: "portableWriteRecoveryWarning")
            let detectedAt = Date()
            state = State(
                repairNeeded: oldWarning,
                requiresReconstruction: oldWarning,
                incidents: oldWarning ? [Incident(
                    id: UUID(), operationKind: "unknown", failureStage: "legacy_marker_migration",
                    errorCategory: "original_cause_unavailable", occurredAt: detectedAt
                )] : [],
                firstRetryAt: oldWarning ? detectedAt : nil
            )
            persist()
        }
    }

    @discardableResult
    func reportFailure(
        operation: StoreSplitPortableWriteOutbox.Operation,
        error: Error,
        stage: String = "enqueue"
    ) -> Bool {
        let now = Date()
        let kind = Self.operationKind(operation)
        let category = Self.errorCategory(error)
        state.repairNeeded = true
        state.incidents.append(Incident(
            id: UUID(), operationKind: kind, failureStage: stage,
            errorCategory: category, occurredAt: now
        ))
        state.incidents = Array(state.incidents.suffix(64))
        if state.pendingOperations.count >= Self.maximumFallbackOperations {
            state.requiresReconstruction = true
            persist()
            return false
        }
        state.pendingOperations.append(PendingOperation(id: UUID(), operation: operation, recordedAt: now))
        if state.firstRetryAt == nil { state.firstRetryAt = now }
        persist()
#if canImport(UIKit)
        AppDelegate.scheduleStoreSplitBackgroundProcessingIfNeeded()
#endif
        return true
    }

    /// Compatibility entry point for callers that only know an incident
    /// occurred. Without its durable payload it must stay marked for repair.
    func reportFailure() {
        let now = Date()
        state.repairNeeded = true
        state.requiresReconstruction = true
        state.incidents.append(Incident(
            id: UUID(), operationKind: "unknown", failureStage: "unspecified",
            errorCategory: "unknown", occurredAt: now
        ))
        state.incidents = Array(state.incidents.suffix(64))
        persist()
    }

    func pendingOperations() -> [PendingOperation] { state.pendingOperations }

    func acknowledgeFallbackOperation(_ id: UUID) {
        state.pendingOperations.removeAll { $0.id == id }
        state.lastRetryAt = .now
        persist()
    }

    func recordDrainAttempt(queueCount: Int?, oldestAge: TimeInterval?) {
        state.lastDrainAttemptAt = .now
        state.latestQueueCount = queueCount
        state.latestQueueCapacity = 512
        state.latestQueueOldestAgeSeconds = oldestAge.map { max(0, Int($0)) }
        persist()
    }

    func recordDrainFailure(_ error: Error) {
        let now = Date()
        let category = Self.errorCategory(error)
        state.repairNeeded = true
        state.lastDrainFailedAt = now
        state.latestDrainFailureCategory = category
        state.lastRetryAt = now
        state.incidents.append(Incident(
            id: UUID(), operationKind: "unknown", failureStage: "maintenance",
            errorCategory: category, occurredAt: now
        ))
        state.incidents = Array(state.incidents.suffix(64))
        persist()
    }

    func recordDrainFailures(operationKinds: [String], categories: [String]) {
        let now = Date()
        state.repairNeeded = true
        if categories.contains("outbox_invalid_entry") { state.requiresReconstruction = true }
        for (index, category) in categories.prefix(32).enumerated() {
            state.incidents.append(Incident(
                id: UUID(), operationKind: operationKinds.indices.contains(index) ? operationKinds[index] : "unknown",
                failureStage: "drain", errorCategory: category, occurredAt: now
            ))
        }
        state.incidents = Array(state.incidents.suffix(64))
        if let latest = categories.last { state.latestDrainFailureCategory = latest }
        state.lastDrainFailedAt = now
        persist()
    }

    func recordDrainSuccess(succeeded: Int, failed: Int, hasPending: Bool, queueCount: Int) {
        let now = Date()
        state.latestQueueCount = queueCount
        state.lastRetryAt = now
        if failed > 0 { state.lastDrainFailedAt = now }
        else if succeeded > 0 { state.lastDrainSucceededAt = now }
        if state.pendingOperations.isEmpty && !hasPending && failed == 0 && !state.requiresReconstruction {
            state.repairNeeded = false
            state.lastSuccessfulRepairAt = now
            state.firstRetryAt = nil
            state.latestDrainFailureCategory = nil
        }
        persist()
    }

    func refresh() {
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
        defaults.set(state.repairNeeded || !state.pendingOperations.isEmpty, forKey: "portableWriteRecoveryPending")
        // Keep old clients from observing a permanent legacy latch.
        defaults.removeObject(forKey: "portableWriteRecoveryWarning")
        state = state
    }

    static func operationKind(_ operation: StoreSplitPortableWriteOutbox.Operation) -> String {
        switch operation {
        case .episodeState: "episode_state"
        case .bookmarkUpsert: "bookmark_upsert"
        case .bookmarkDeletionAfterLocalCommit: "bookmark_deletion"
        case .listeningHistory: "listening_history"
        }
    }

    static func errorCategory(_ error: Error) -> String {
        if let error = error as? StoreSplitPortableWriteOutbox.OutboxError {
            return switch error {
            case .storageUnavailable: "outbox_storage_unavailable"
            case .busy: "outbox_lock_busy"
            case .full: "outbox_capacity_reached"
            case .invalidEntry: "outbox_invalid_entry"
            case .localDeletionPending: "bookmark_local_delete_unconfirmed"
            }
        } else {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain { return "cocoa_\(error.code)" }
            if error.domain == NSPOSIXErrorDomain { return "posix_\(error.code)" }
            return "other_\(error.code)"
        }
    }
}
