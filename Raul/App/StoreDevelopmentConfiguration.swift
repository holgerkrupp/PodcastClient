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
    static let resetLocalSplitStoresOnNextLaunchKey =
        "development.database.resetLocalSplitStoresOnNextLaunch"
    static let resetAllLocalStoresOnNextLaunchKey =
        "development.database.resetAllLocalStoresOnNextLaunch"

    let mode: DevelopmentStoreMode
    let legacyCloudSyncEnabled: Bool
    let userStateCloudSyncEnabled: Bool

    static let launch = loadCurrent()

    static var current: StoreDevelopmentConfiguration {
        loadCurrent()
    }

    static var splitStoresEnabled: Bool {
        splitStoreHeavyWorkPaused == false && launch.mode != .legacyOnly
    }

    static var newStoreReadsEnabled: Bool {
        splitStoreHeavyWorkPaused == false
            && (launch.mode == .splitStoreReads || launch.mode == .newStoresOnly)
    }

    static var legacyMigrationEnabled: Bool {
        splitStoreHeavyWorkPaused == false && launch.mode == .splitStores
    }

    static var legacyCloudSyncEnabled: Bool {
        launch.mode == .splitStores && launch.legacyCloudSyncEnabled
    }

    static var userStateCloudSyncEnabled: Bool {
        launch.mode == .splitStores && launch.userStateCloudSyncEnabled
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
        true
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
        ) as? Bool ?? true
        return StoreDevelopmentConfiguration(
            mode: mode,
            legacyCloudSyncEnabled: legacyCloudSyncEnabled,
            userStateCloudSyncEnabled: userStateCloudSyncEnabled
        )
#else
        return StoreDevelopmentConfiguration(
            mode: .splitStores,
            legacyCloudSyncEnabled: true,
            userStateCloudSyncEnabled: true
        )
#endif
    }
}
