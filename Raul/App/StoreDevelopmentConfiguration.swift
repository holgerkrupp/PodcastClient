import Foundation
import SQLite3

/// Core Data reports CloudKit events using the persistent store UUID, not its
/// filename. Read only the small metadata row; never open a mirrored container
/// just to identify a store or decide whether it is safe to launch one.
enum CloudKitStoreIdentity {
    static func identifier(at url: URL?) -> String? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "SELECT Z_UUID FROM Z_METADATA LIMIT 1", -1, &statement, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let rawUUID = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: rawUUID)
    }

    static func isLegacy(_ identifier: String, legacyUUID: String?) -> Bool {
        let normalized = identifier.lowercased()
        let matchesUUID = legacyUUID.map {
            identifier.caseInsensitiveCompare($0) == .orderedSame
        } ?? false
        return normalized.contains("shareddatabase")
            || normalized.contains("legacy")
            || matchesUUID
    }
}

struct StoreSplitLaunchHealthState: Codable, Sendable, Equatable {
    /// Retained under its original persisted field name for migration
    /// compatibility. This now counts launches without a runtime-ready marker;
    /// it is not proof of a crash.
    var consecutiveUnhealthyLaunches = 0
    var lastLaunchStartedAt: Date?
    var lastHealthyAt: Date?
    var lastRuntimeReadyAt: Date?
}

enum StoreSplitLaunchHealth {
    static let stateKey = "storeSplit.launchHealth.v1"
    static let recoverySuggestedKey = "storeSplit.legacyRecoverySuggested.v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    @discardableResult
    static func beginLaunch(now: Date = .now) -> Bool {
        var state = read()
        let previousLaunchWasUnhealthy: Bool
        if let lastLaunchStartedAt = state.lastLaunchStartedAt {
            // Runtime readiness is distinct from the 75-second exporter
            // observation window. A user who backgrounds a usable app before
            // that window ends must not be counted as a failed launch.
            previousLaunchWasUnhealthy = state.lastRuntimeReadyAt.map {
                lastLaunchStartedAt > $0
            } ?? true
        } else {
            previousLaunchWasUnhealthy = false
        }
        if previousLaunchWasUnhealthy {
            state.consecutiveUnhealthyLaunches += 1
        } else {
            state.consecutiveUnhealthyLaunches = 0
        }
        state.lastLaunchStartedAt = now
        write(state)
        if state.consecutiveUnhealthyLaunches >= 2 {
            // Keep the recovery action visible even if a later foreground
            // session lasts long enough to clear the consecutive counter.
            defaults.set(true, forKey: recoverySuggestedKey)
        }

        // iOS does not provide a reliable previous-process termination reason,
        // so a missing foreground checkpoint is a diagnostic signal and a
        // recovery offer, never proof of a crash.
        CrashBreadcrumbs.shared.record(
            "store_split_launch_started",
            details: "previous_incomplete=\(previousLaunchWasUnhealthy),consecutive=\(state.consecutiveUnhealthyLaunches)"
        )
        return false
    }

    /// Call as soon as the primary runtime container has opened successfully.
    /// This is a startup-readiness checkpoint, not a claim that CloudKit export
    /// has been quiet or that the process passed a long-running health window.
    static func markRuntimeReady(now: Date = .now) {
        var state = read()
        state.consecutiveUnhealthyLaunches = 0
        state.lastRuntimeReadyAt = now
        state.lastHealthyAt = now
        write(state)
        CrashBreadcrumbs.shared.record("store_split_runtime_ready")
    }

    static func markHealthy(now: Date = .now) {
        var state = read()
        state.consecutiveUnhealthyLaunches = 0
        state.lastHealthyAt = now
        state.lastRuntimeReadyAt = now
        write(state)
    }

    static var current: StoreSplitLaunchHealthState { read() }

    static var shouldOfferLegacyRecovery: Bool {
        defaults.bool(forKey: recoverySuggestedKey)
            || current.consecutiveUnhealthyLaunches >= 2
    }

    private static func read() -> StoreSplitLaunchHealthState {
        guard let data = defaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(
                  StoreSplitLaunchHealthState.self,
                  from: data
              ) else {
            return StoreSplitLaunchHealthState()
        }
        return state
    }

    private static func write(_ state: StoreSplitLaunchHealthState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }
}

/// Which step of the store split a shipped build performs.
///
/// The split is delivered in two releases rather than one. Cutting straight to
/// `userStateAuthority` means the update simultaneously stops syncing the legacy
/// graph and starts trusting a store that has never been exercised in
/// production — and it opens a divergence window for anyone whose second device
/// has not updated yet. `dualSyncBackfill` ships the risky half first, with
/// nothing user-visible riding on it.
enum StoreSplitReleasePhase: Equatable {
    /// Ship #1. The legacy library graph stays exactly as it shipped before:
    /// primary source of truth, CloudKit-backed, unchanged cross-device
    /// behaviour. `UserState.sqlite` is populated in the background and synced,
    /// but nothing reads it. This proves the schema, the CloudKit payload, and
    /// the migration itself against real libraries with no way to lose data.
    case dualSyncBackfill

    /// Ship #2. Legacy CloudKit sync is turned off and `UserState.sqlite`
    /// becomes the authority for user-owned state — the payload win. Safe only
    /// once phase one has converged across the population.
    case userStateAuthority

    /// The phase this build ships. Changing this constant is the cutover.
    static let current: StoreSplitReleasePhase = .userStateAuthority

    /// The authority release is a source-level switch, but it must not be
    /// flipped on the strength of one device's local checkpoint. This gate is
    /// deliberately pure so release tooling and end-to-end upgrade tests can
    /// evaluate the exact same rule before changing `current`.
    static func canSwitchToUserStateAuthority(
        gate: StoreSplitCutoverGate
    ) -> Bool {
        gate.isSatisfied
    }
}

/// Population-level evidence required before the release phase can stop
/// syncing the legacy store. Local migration completion is necessary, but it is
/// not enough: another device may still be on the old build or a delayed
/// CloudKit delivery may still be in flight.
struct StoreSplitCutoverGate: Equatable, Sendable {
    let localBackfillComplete: Bool
    let localVerificationPassed: Bool
    let podcastCacheReady: Bool
    let allDevicesConverged: Bool
    let delayedCloudImportsSettled: Bool
    /// Evidence that the current implementation cannot yet establish. An empty
    /// list must be earned by durable verification, not supplied by a count or
    /// a completed schema marker.
    let unresolvedEvidence: [String]

    var isSatisfied: Bool {
        localBackfillComplete
            && localVerificationPassed
            && podcastCacheReady
            && allDevicesConverged
            && delayedCloudImportsSettled
            && unresolvedEvidence.isEmpty
    }

    var blockers: [String] {
        var result: [String] = []
        if localBackfillComplete == false { result.append("local backfill incomplete") }
        if localVerificationPassed == false { result.append("local verification incomplete") }
        if podcastCacheReady == false { result.append("PodcastCache is not ready") }
        if allDevicesConverged == false { result.append("devices have not converged") }
        if delayedCloudImportsSettled == false { result.append("delayed CloudKit imports are unsettled") }
        result.append(contentsOf: unresolvedEvidence)
        return result
    }
}

/// Every build runs the final two-store runtime: `UserState.sqlite` (synced)
/// and `PodcastCache.sqlite` (local) with an in-memory legacy-model graph. The
/// one-time move off `SharedDatabase.sqlite` is owned by `StoreCutoverCoordinator`.
enum StoreDevelopmentConfiguration {
    /// Only `UserState.sqlite` is ever mirrored to CloudKit.
    static let userStateCloudSyncEnabled = true
    static let cloudSyncSettingsAvailable = true
    static let splitStoresEnabled = true
    static let newStoreReadsEnabled = true
    static let userStateImportEnabled = true
    static let projectsListeningHistoryToLegacy = true
    static let modeAllowsDuplicateCleanupDuringProjection = true
    /// A state hidden from the runtime graph gets overwritten with defaults on
    /// its next write, so every state must be projected.
    static let episodeStateProjectionRecencyCutoff: Date? = nil
    /// The cache and UserState are the only durable stores now, so nothing may
    /// pause their writes: a pause would silently lose local data.
    static let splitStoreHeavyWorkPaused = false

    /// The legacy library store is never attached to CloudKit again.
    static let legacyCloudSyncEnabled = false
    /// Kept only for callers that still ask; there is no mirror to quarantine.
    static let legacyCloudMirrorQuarantined = false

    static let resetLocalSplitStoresOnNextLaunchKey =
        "development.database.resetLocalSplitStoresOnNextLaunch"
    static let resetAllLocalStoresOnNextLaunchKey =
        "development.database.resetAllLocalStoresOnNextLaunch"

    /// Last CloudKit decision recorded by older builds for the legacy store. A
    /// present value is evidence that this installation had a library.
    static let legacyCloudSyncLastStateKey =
        "storeSplit.legacyCloudSyncLastEnabled"
    /// Persisted by the cutover so the app and its extensions agree that
    /// SharedDatabase has been detached.
    static let legacyCloudCutoverCompletedKey =
        "storeSplit.legacyCloudCutoverCompleted.v1"

    private static var legacyAttachmentDefaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    static var legacyCloudCutoverCompleted: Bool {
        legacyAttachmentDefaults.bool(forKey: legacyCloudCutoverCompletedKey)
    }

    /// Records the irreversible production boundary.
    static func markLegacyCloudCutoverCompleted() {
        let defaults = legacyAttachmentDefaults
        defaults.set(true, forKey: legacyCloudCutoverCompletedKey)
        defaults.removeObject(forKey: "storeSplit.legacyCloudReattachApproved")
        defaults.set(false, forKey: legacyCloudSyncLastStateKey)
    }
}
