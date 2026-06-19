import Foundation

enum DevelopmentStoreMode: String, CaseIterable, Identifiable {
    case legacyOnly
    case splitStores
    case splitStoreReads

    var id: Self { self }

    var title: String {
        switch self {
        case .legacyOnly:
            "Legacy store only"
        case .splitStores:
            "Split stores (dual-write)"
        case .splitStoreReads:
            "New-store reads (dual-write)"
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
        launch.mode != .legacyOnly
    }

    static var newStoreReadsEnabled: Bool {
        launch.mode == .splitStoreReads
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
