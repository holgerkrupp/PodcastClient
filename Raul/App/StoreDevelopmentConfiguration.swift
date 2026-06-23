import Foundation

enum DevelopmentStoreMode: String, CaseIterable, Identifiable {
    case legacyOnly
    case splitStores
    case splitStoreReads
    case newStoresOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .legacyOnly:
            "Legacy store only"
        case .splitStores:
            "Split stores (dual-write)"
        case .splitStoreReads:
            "New-store reads (dual-write)"
        case .newStoresOnly:
            "New stores only (local projection)"
        }
    }
}

struct StoreDevelopmentConfiguration: Equatable {
    static let modeKey = "development.database.storeMode"
    static let legacyCloudSyncEnabledKey = "development.database.legacyCloudSyncEnabled"
    static let userStateCloudSyncEnabledKey = "development.database.userStateCloudSyncEnabled"
    static let splitStoreWorkEnabledKey = "development.database.splitStoreWorkEnabled"
    static let resetLocalSplitStoresOnNextLaunchKey =
        "development.database.resetLocalSplitStoresOnNextLaunch"
    static let resetAllLocalStoresOnNextLaunchKey =
        "development.database.resetAllLocalStoresOnNextLaunch"
    /// When false (the default), the slice migration never starts automatically
    /// from foreground-active; it only runs via the explicit development controls.
    static let migrationAutoRunEnabledKey =
        "development.database.migrationAutoRunEnabled"
    /// Pauses the slice migration loop without disabling the rest of split-store
    /// work. Read live (not frozen at launch) so the toggle takes effect at once.
    static let migrationPausedKey =
        "development.database.migrationPaused"

    let mode: DevelopmentStoreMode
    let legacyCloudSyncEnabled: Bool
    let userStateCloudSyncEnabled: Bool
    let splitStoreWorkEnabled: Bool

    static let launch = loadCurrent()

    static var current: StoreDevelopmentConfiguration {
        loadCurrent()
    }

    static var splitStoresEnabled: Bool {
        launch.splitStoresEnabled
    }

    static var newStoreReadsEnabled: Bool {
        launch.newStoreReadsEnabled
    }

    static var legacyMigrationEnabled: Bool {
        launch.legacyMigrationEnabled
    }

    static var legacyCloudSyncEnabled: Bool {
        launch.effectiveLegacyCloudSyncEnabled
    }

    static var userStateCloudSyncEnabled: Bool {
        launch.effectiveUserStateCloudSyncEnabled
    }

    static var cloudSyncSettingsAvailable: Bool {
        launch.cloudSyncSettingsAvailable
    }

    static var usesLegacyLocalProjection: Bool {
        launch.mode != .legacyOnly
    }

    static var projectsListeningHistoryToLegacy: Bool {
        switch launch.mode {
        case .legacyOnly, .splitStores:
            true
        case .splitStoreReads, .newStoresOnly:
            false
        }
    }

    static var episodeStateProjectionRecencyCutoff: Date? {
        switch launch.mode {
        case .legacyOnly, .splitStores:
            nil
        case .splitStoreReads, .newStoresOnly:
            Calendar.current.date(byAdding: .day, value: -180, to: .now)
        }
    }

    static var modeAllowsDuplicateCleanupDuringProjection: Bool {
        switch launch.mode {
        case .legacyOnly, .splitStores:
            true
        case .splitStoreReads, .newStoresOnly:
            false
        }
    }

    static var splitStoreHeavyWorkPaused: Bool {
#if DEBUG
        launch.splitStoreHeavyWorkPaused
#else
        false
#endif
    }

    /// Whether foreground-active is allowed to start the slice migration loop.
    /// Defaults to disabled so migration only runs via explicit dev controls.
    static var migrationAutoRunEnabled: Bool {
#if DEBUG
        UserDefaults.standard.object(forKey: migrationAutoRunEnabledKey) as? Bool ?? false
#else
        false
#endif
    }

    /// Live pause switch for the slice migration loop (read each slice).
    static var migrationSlicePaused: Bool {
#if DEBUG
        UserDefaults.standard.bool(forKey: migrationPausedKey)
#else
        false
#endif
    }

    private static func loadCurrent() -> StoreDevelopmentConfiguration {
#if DEBUG
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: modeKey)
            .flatMap(DevelopmentStoreMode.init(rawValue:))
            ?? .splitStores
        let legacyCloudSyncEnabled = defaults.object(
            forKey: legacyCloudSyncEnabledKey
        ) as? Bool ?? true
        let userStateCloudSyncEnabled = defaults.object(
            forKey: userStateCloudSyncEnabledKey
        ) as? Bool ?? false
        let splitStoreWorkEnabled = defaults.object(
            forKey: splitStoreWorkEnabledKey
        ) as? Bool ?? true
        return StoreDevelopmentConfiguration(
            mode: mode,
            legacyCloudSyncEnabled: legacyCloudSyncEnabled,
            userStateCloudSyncEnabled: userStateCloudSyncEnabled,
            splitStoreWorkEnabled: splitStoreWorkEnabled
        )
#else
        // Release builds follow the on-device rollout: existing users read the
        // legacy store while migrating; new and migrated users read the split
        // store. Both stores keep syncing through CloudKit during the transition.
        return StoreDevelopmentConfiguration(
            mode: StoreSplitRollout.resolvedMode,
            legacyCloudSyncEnabled: true,
            userStateCloudSyncEnabled: true,
            splitStoreWorkEnabled: true
        )
#endif
    }
}

extension StoreDevelopmentConfiguration {
    var splitStoreHeavyWorkPaused: Bool {
        splitStoreWorkEnabled == false
    }

    var splitStoresEnabled: Bool {
        splitStoreHeavyWorkPaused == false && mode != .legacyOnly
    }

    var newStoreReadsEnabled: Bool {
        splitStoreHeavyWorkPaused == false
            && (mode == .splitStoreReads || mode == .newStoresOnly)
    }

    var legacyMigrationEnabled: Bool {
        splitStoreHeavyWorkPaused == false
            && (mode == .splitStores || mode == .splitStoreReads)
    }

    var cloudSyncSettingsAvailable: Bool {
        mode == .splitStores || mode == .splitStoreReads
    }

    var effectiveLegacyCloudSyncEnabled: Bool {
        cloudSyncSettingsAvailable && legacyCloudSyncEnabled
    }

    var effectiveUserStateCloudSyncEnabled: Bool {
        cloudSyncSettingsAvailable && userStateCloudSyncEnabled
    }
}
