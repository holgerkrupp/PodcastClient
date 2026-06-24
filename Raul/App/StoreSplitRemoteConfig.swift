import CloudKit
import Foundation

/// Remotely-controlled rollout overrides for the legacy → split-store transition.
///
/// The flags are hosted as a single record in the CloudKit **public** database so
/// the rollout can be paused or rolled back from the CloudKit Dashboard without an
/// App Store release. CloudKit therefore remains the only network dependency.
///
/// The automatic per-install rollout in `StoreSplitRollout` stays authoritative —
/// these flags only *override* it when set, and normal automatic behaviour resumes
/// once they are cleared. The override is applied at the mode/heavy-work layer, not
/// by mutating the stored rollout state, so lifting a kill never re-triggers a
/// migration that had already completed.
struct StoreSplitRemoteConfig: Sendable, Equatable {
    /// When `false`, all split-store heavy work (slice migration, reconcile, AI
    /// import, background scheduling) is paused **live** on the next gated check.
    /// The legacy store keeps reading and syncing, so this is a safe hard stop.
    var migrationEnabled: Bool

    /// When `true`, launches resolve to legacy reads regardless of the stored
    /// rollout state. Because the read source is fixed when the containers are
    /// created, this takes effect on the **next launch**, not mid-session.
    var forceLegacyReads: Bool

    /// Builds whose `CFBundleVersion` is below this are forced to the safe state
    /// (migration paused + legacy reads). `0` disables the check.
    var minSupportedBuild: Int

    /// Fail-safe default used before the first successful fetch and whenever no
    /// value has ever been cached: permissive, i.e. the automatic rollout runs.
    static let permissive = StoreSplitRemoteConfig(
        migrationEnabled: true,
        forceLegacyReads: false,
        minSupportedBuild: 0
    )
}

/// Fetches and caches `StoreSplitRemoteConfig`. The cached value is read live by
/// the rollout gates so a fetch that lands mid-session pauses heavy work at once.
enum StoreSplitRemoteConfigStore {
    /// CloudKit record type and the fixed record name every device shares.
    static let recordType = "RolloutConfig"
    static let recordName = "store-split-rollout-config"
    private static let containerID = "iCloud.de.holgerkrupp.PodcastClient"

    private static let migrationEnabledKey = "storeSplit.remoteConfig.migrationEnabled"
    private static let forceLegacyReadsKey = "storeSplit.remoteConfig.forceLegacyReads"
    private static let minSupportedBuildKey = "storeSplit.remoteConfig.minSupportedBuild"
    private static let hasCachedValueKey = "storeSplit.remoteConfig.hasCachedValue"
    private static let lastFetchedAtKey = "storeSplit.remoteConfig.lastFetchedAt"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
    }

    /// The currently effective config: the last cached value if one exists,
    /// otherwise the permissive default. Read live on every access.
    static var current: StoreSplitRemoteConfig {
        guard defaults.bool(forKey: hasCachedValueKey) else { return .permissive }
        return StoreSplitRemoteConfig(
            migrationEnabled: defaults.object(forKey: migrationEnabledKey) as? Bool ?? true,
            forceLegacyReads: defaults.bool(forKey: forceLegacyReadsKey),
            minSupportedBuild: defaults.integer(forKey: minSupportedBuildKey)
        )
    }

    static var lastFetchedAt: Date? {
        defaults.object(forKey: lastFetchedAtKey) as? Date
    }

    /// `true` when this build is below the remote minimum supported build.
    static var isBuildUnsupported: Bool {
        let minBuild = current.minSupportedBuild
        guard minBuild > 0 else { return false }
        return currentBuildNumber() < minBuild
    }

    /// `true` when split-store heavy work should be paused per remote config.
    static var migrationPausedRemotely: Bool {
        current.migrationEnabled == false || isBuildUnsupported
    }

    /// `true` when reads should be forced back to legacy per remote config.
    static var forcesLegacyReads: Bool {
        current.forceLegacyReads || isBuildUnsupported
    }

    /// Fetches the config record from the public database and caches it.
    /// - A missing record is treated as permissive, but only when nothing has
    ///   been cached yet — a previously received kill is never clobbered by a
    ///   later "record absent" result. To lift a kill, set the record fields back
    ///   to permissive values; do not delete the record.
    /// - A network/other failure leaves the cache untouched and returns `nil`.
    @discardableResult
    static func refresh() async -> StoreSplitRemoteConfig? {
        let database = CKContainer(identifier: containerID).publicCloudDatabase
        let recordID = CKRecord.ID(recordName: recordName)
        do {
            let record = try await database.record(for: recordID)
            let config = StoreSplitRemoteConfig(
                migrationEnabled: boolValue(record["migrationEnabled"], default: true),
                forceLegacyReads: boolValue(record["forceLegacyReads"], default: false),
                minSupportedBuild: intValue(record["minSupportedBuild"])
            )
            cache(config)
            CrashBreadcrumbs.shared.record(
                "store_split_remote_config_fetched",
                details: "migration=\(config.migrationEnabled),legacyReads=\(config.forceLegacyReads),minBuild=\(config.minSupportedBuild)"
            )
            return config
        } catch let error as CKError where error.code == .unknownItem {
            if defaults.bool(forKey: hasCachedValueKey) == false {
                cache(.permissive)
            }
            CrashBreadcrumbs.shared.record("store_split_remote_config_absent")
            return current
        } catch {
            CrashBreadcrumbs.shared.record(
                "store_split_remote_config_fetch_failed",
                details: error.localizedDescription
            )
            return nil
        }
    }

    private static func cache(_ config: StoreSplitRemoteConfig) {
        defaults.set(config.migrationEnabled, forKey: migrationEnabledKey)
        defaults.set(config.forceLegacyReads, forKey: forceLegacyReadsKey)
        defaults.set(config.minSupportedBuild, forKey: minSupportedBuildKey)
        defaults.set(true, forKey: hasCachedValueKey)
        defaults.set(Date(), forKey: lastFetchedAtKey)
    }

    private static func boolValue(_ value: CKRecordValue?, default fallback: Bool) -> Bool {
        guard let number = value as? Int64 else { return fallback }
        return number != 0
    }

    private static func intValue(_ value: CKRecordValue?) -> Int {
        Int(value as? Int64 ?? 0)
    }

    private static func currentBuildNumber() -> Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

#if DEBUG
    /// Clears the cached value so DEBUG builds can re-test the pre-fetch path.
    static func resetCacheForDevelopment() {
        defaults.removeObject(forKey: migrationEnabledKey)
        defaults.removeObject(forKey: forceLegacyReadsKey)
        defaults.removeObject(forKey: minSupportedBuildKey)
        defaults.removeObject(forKey: hasCachedValueKey)
        defaults.removeObject(forKey: lastFetchedAtKey)
    }
#endif
}
