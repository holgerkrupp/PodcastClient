import SwiftUI
import SwiftData
import BackgroundTasks
import DeviceInfo
import BasicLogger
import TipKit
import CloudKitSyncMonitor

enum BackgroundTaskConfiguration {
    static let feedRefreshIdentifier = "checkFeedUpdates"
    static let storageCleanupIdentifier = "storageCleanup"
    static let automaticTranscriptionIdentifier = "automaticTranscriptionProcessing"
    static let feedRefreshInterval: TimeInterval = 60 * 30
    static let nightlyStorageCleanupInterval: TimeInterval = 60 * 60 * 24
    static let weeklyStorageCleanupFallbackInterval: TimeInterval = 60 * 60 * 24 * 7
    static let automaticTranscriptionInterval: TimeInterval = 60 * 15
    static let lastStorageCleanupKey = "LastStorageCleanup"
    static let lastForegroundDownloadCleanupKey = "LastForegroundDownloadCleanup"
    static let foregroundDownloadCleanupMinimumInterval: TimeInterval = 60 * 60 * 12
}

@main
struct RaulApp: App {
    @StateObject private var modelContainerManager = ModelContainerManager.shared
    @State private var downloadedFilesManager = DownloadedFilesManager(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
    @State private var settingsRequest = SettingsWindowRequest.global
    @State private var deferredStoreSplitTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var phase
#if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif

    init() {
        CrashBreadcrumbs.shared.record("raul_app_init_start")
        SyncMonitor.default.startMonitoring()
        CrashBreadcrumbs.shared.record("raul_app_init_completed")
        
        // Tips.showTipsForTesting([ReorderPlaylistTip.self]) // Uncomment to force show during dev
                
                try? Tips.configure([
                    .displayFrequency(.weekly), // Controls how often tips appear app-wide
                    .datastoreLocation(.applicationDefault)
                ])
        
    }

    var body: some Scene {

        
        WindowGroup("Up Next", id: AppWindowID.main) {
            if let container = modelContainerManager.preparedContainer {
                AppLaunchContainerView(
                    requiresInitialCloudImport: modelContainerManager.requiresInitialCloudImport,
                    modelContainer: container
                ) {
                    ContentView()
                    .modelContainer(container)
                    .environment(downloadedFilesManager)
                    .accentColor(.accent)
                    .withDeviceStyle()
                    .hostsSettingsPresentation(
                        modelContainer: container,
                        settingsRequest: $settingsRequest
                    )
                
                    .onAppear {
                        CrashBreadcrumbs.shared.record("root_view_on_appear")
                        WatchSyncCoordinator.activate()
                        let managerReference = DownloadedFilesManagerReference(manager: downloadedFilesManager)
                        Task {
                            await SubscriptionManifestSync.restoreSubscriptionsAndBootstrap(
                                modelContainer: container
                            )
                            await CloudSyncProgressReferenceStore.publish(modelContainer: container)
                            await PlayNextWidgetSync.refresh(using: container)
                            WatchSyncCoordinator.refreshSoon()
                        }
                        Task {
                            await DownloadManager.shared.injectDownloadedFilesManager(managerReference)
                        }
                        Task {
                            await AutoDownloadNetworkCoordinator.shared.startMonitoringIfNeeded(
                                modelContainer: container
                            )
                        }
                        Task {
                            let actor = EpisodeActor(modelContainer: container)
                            await actor.migrateLegacyBackCatalogSuppressionIfNeeded()
                        }
#if canImport(UIKit)
                        UIDevice.current.isBatteryMonitoringEnabled = true
#endif
                        Task {
                            await runAutomaticTranscriptionSweep(reason: "launch")
                        }
                        Task { @MainActor in
                            Player.shared.startRecoveryIfNeeded()
                        }
                        Task {
                            let enabled = UserDefaults.standard.bool(forKey: SideloadingConfiguration.enabledKey)
                            do {
                                try await SideloadingCoordinator.shared.syncEnabledState(enabled)
                            } catch {
                                BasicLogger.shared.log("Failed to restore sideloading state: \(error.localizedDescription)")
                            }
                        }
                    }
                

#if canImport(UIKit)
                    .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
                        CrashBreadcrumbs.shared.record("battery_state_changed")
                        Task {
                            await runAutomaticTranscriptionSweep(reason: "power state changed")
                        }
                    }
#endif
                }
            } else {
                ModelContainerLaunchView(
                    errorMessage: modelContainerManager.initializationError,
                    retry: {
                        Task {
                            await modelContainerManager.prepareContainer()
                        }
                    }
                )
                .task {
                    await modelContainerManager.prepareContainer()
                }
            }
        }
#if os(macOS)
        .commands {
            AppCommands(
                settingsRequest: $settingsRequest,
                isPlayerReady: modelContainerManager.preparedContainer != nil
            )
        }
#endif
        .onChange(of: phase, {
            CrashBreadcrumbs.shared.record("scene_phase_changed", details: "\(phase)")
            switch phase {
            case .background:
                deferredStoreSplitTask?.cancel()
                deferredStoreSplitTask = nil
                scheduleFeedRefresh()
                scheduleStorageCleanup()
                guard modelContainerManager.preparedContainer != nil else {
                    CrashBreadcrumbs.shared.record(
                        "background_transition_deferred",
                        details: "reason=model_container_not_prepared"
                    )
                    return
                }
                Player.shared.enterBackgroundPlaybackMode()
#if canImport(UIKit)
                Task {
                    await AppDelegate.scheduleAutomaticTranscriptionProcessingIfNeeded()
                }
#endif
             
                
            case .active:
                guard modelContainerManager.preparedContainer != nil else { return }
                cleanUp()
                refreshOnActive()
                scheduleStoreSplitMigration()
                Task {
                    await Player.shared.enterForegroundPlaybackMode()
                    await Player.shared.reloadPlaybackStateFromPersistenceIfNeeded()
                }
                Task {
                    await runScheduledStorageCleanupIfNeeded(
                        minimumInterval: BackgroundTaskConfiguration.weeklyStorageCleanupFallbackInterval,
                        reason: "active fallback"
                    )
                }
                Task {
                    await runAutomaticTranscriptionSweep(reason: "active")
                }
          
                
            default: break
            }
        })

#if os(iOS)
        .backgroundTask(.appRefresh(BackgroundTaskConfiguration.feedRefreshIdentifier)) { task in
            CrashBreadcrumbs.shared.record("feed_refresh_background_task_started")
            await scheduleFeedRefresh()
            await modelContainerManager.prepareContainer()

            guard let container = await MainActor.run(body: {
                modelContainerManager.preparedContainer
            }) else {
                CrashBreadcrumbs.shared.record(
                    "feed_refresh_background_task_aborted",
                    details: "reason=model_container_unavailable"
                )
                return
            }

            await SubscriptionManager(modelContainer: container).bgupdateFeeds()
            CrashBreadcrumbs.shared.record("feed_refresh_background_task_completed")
        }
        .backgroundTask(.appRefresh(BackgroundTaskConfiguration.storageCleanupIdentifier)) { task in
            await scheduleStorageCleanup()
            CrashBreadcrumbs.shared.record("skip_storage_cleanup_in_background_task")
        }
#endif

#if os(macOS)
        Window("Now Playing", id: AppWindowID.player) {
            if let container = modelContainerManager.preparedContainer {
                MacPlayerWindowContent()
                    .modelContainer(container)
                    .environment(downloadedFilesManager)
                    .accentColor(.accent)
                    .withDeviceStyle()
            } else {
                ModelContainerLaunchView(
                    errorMessage: modelContainerManager.initializationError,
                    retry: {
                        Task {
                            await modelContainerManager.prepareContainer()
                        }
                    }
                )
                .task {
                    await modelContainerManager.prepareContainer()
                }
            }
        }
        .defaultSize(width: 760, height: 820)

        MenuBarExtra {
            if let container = modelContainerManager.preparedContainer {
                MacMenuBarPlayerView()
                    .modelContainer(container)
                    .environment(downloadedFilesManager)
                    .accentColor(.accent)
            } else {
                ModelContainerLaunchView(
                    errorMessage: modelContainerManager.initializationError,
                    retry: {
                        Task {
                            await modelContainerManager.prepareContainer()
                        }
                    }
                )
                .frame(width: 320, height: 240)
                .task {
                    await modelContainerManager.prepareContainer()
                }
            }
        } label: {
            MacMenuBarLabel(
                isPlayerReady: modelContainerManager.preparedContainer != nil
            )
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: SettingsWindowRequest.sceneID) {
            settingsSceneContent
        }
        .defaultSize(width: 820, height: 680)
#else
        WindowGroup(
            "Settings",
            id: SettingsWindowRequest.sceneID,
            for: SettingsWindowRequest.self
        ) { request in
            if let container = modelContainerManager.preparedContainer {
                SettingsWindowContent(request: request.wrappedValue ?? .global)
                    .modelContainer(container)
                    .environment(downloadedFilesManager)
                    .accentColor(.accent)
                    .withDeviceStyle()
            } else {
                ModelContainerLaunchView(
                    errorMessage: modelContainerManager.initializationError,
                    retry: {
                        Task {
                            await modelContainerManager.prepareContainer()
                        }
                    }
                )
                .task {
                    await modelContainerManager.prepareContainer()
                }
            }
        }
        .defaultSize(width: 680, height: 760)
#endif
    }

#if os(macOS)
    @ViewBuilder
    private var settingsSceneContent: some View {
        if let container = modelContainerManager.preparedContainer {
            SettingsWindowContent(
                request: settingsRequest,
                onOpenAllSettings: {
                    settingsRequest = .global
                }
            )
                .modelContainer(container)
                .environment(downloadedFilesManager)
                .accentColor(.accent)
                .withDeviceStyle()
        } else {
            ModelContainerLaunchView(
                errorMessage: modelContainerManager.initializationError,
                retry: {
                    Task {
                        await modelContainerManager.prepareContainer()
                    }
                }
            )
            .task {
                await modelContainerManager.prepareContainer()
            }
        }
    }
#endif
    



    func refreshOnActive(){
        guard let container = modelContainerManager.preparedContainer else { return }
        WatchSyncCoordinator.refreshSoon()
        Task {
            await PlayNextWidgetSync.refresh(using: container)
            await CloudSyncProgressReferenceStore.publish(modelContainer: container)
        }
        if let lastRefresh = getLastRefreshDate(), lastRefresh < Date().addingTimeInterval(-60*60) {
            Task .detached {
                await SubscriptionManager(modelContainer: container).bgupdateFeeds()
            }
        }
    }

    func scheduleStoreSplitMigration() {
        deferredStoreSplitTask?.cancel()
        guard StoreDevelopmentConfiguration.splitStoresEnabled else {
            deferredStoreSplitTask = nil
            return
        }
        deferredStoreSplitTask = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            await modelContainerManager.runStoreSplitMigration()
            await MainActor.run {
                deferredStoreSplitTask = nil
            }
        }
    }
    
    
    func cleanUp()  {
        guard let container = modelContainerManager.preparedContainer else { return }
        if let lastCleanup = getLastForegroundDownloadCleanupDate(),
           Date().timeIntervalSince(lastCleanup) < BackgroundTaskConfiguration.foregroundDownloadCleanupMinimumInterval {
            return
        }

        setLastForegroundDownloadCleanupDate()
        Task.detached(priority: .utility) {
            let janitor = CleanUpActor(modelContainer: container)
            await janitor.cleanUpOldDownloads()
        }
    }

    func debugActions() {
        let sharedContainerURL :URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.de.holgerkrupp.PodcastClient")
        // replace "group.etc.etc" above with your App Group's identifier
        NSLog("sharedContainerURL = \(String(describing: sharedContainerURL))")
        if let sourceURL :URL = sharedContainerURL?.appendingPathComponent("SharedDatabase.sqlite") {
            if let destinationURL :URL = FileManager().urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("copyOfStore.sqlite") {
                try? FileManager().removeItem(at: destinationURL)
                try? FileManager().copyItem(at: sourceURL, to: destinationURL)
             //   try? FileManager().replaceItemAt(destinationURL, withItemAt: sourceURL)
            }
        }
    }
 

    
    func setLastRefreshDate(){
        UserDefaults.standard.setValue(Date().RFC1123String(), forKey: "LastBackgroundRefresh")
    }
    
    func getLastRefreshDate() -> Date? {
        let lastDate = Date.dateFromRFC1123(dateString: UserDefaults.standard.string(forKey: "LastBackgroundRefresh") ?? "")
        return lastDate
    }
    
    func setLastprocessDate(){
        UserDefaults.standard.setValue(Date().formatted(), forKey: "LastBackgroundProcess")
    }
    
    func scheduleFeedRefresh() {
#if os(iOS)
        // this should replace scheduleAppRefresh
        CrashBreadcrumbs.shared.record("schedule_feed_refresh_requested")
        BasicLogger.shared.log("schedule checkFeedUpdates")
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskConfiguration.feedRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundTaskConfiguration.feedRefreshInterval)
        
        do{
            try BGTaskScheduler.shared.submit(request)
            CrashBreadcrumbs.shared.record("schedule_feed_refresh_submitted")

        }catch{
            // print(error)
            CrashBreadcrumbs.shared.record("schedule_feed_refresh_failed", details: error.localizedDescription)
            BasicLogger.shared.log(error.localizedDescription)
        }
#endif
    }

    func scheduleStorageCleanup() {
#if os(iOS)
        CrashBreadcrumbs.shared.record("schedule_storage_cleanup_requested")
        BasicLogger.shared.log("schedule storageCleanup")
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskConfiguration.storageCleanupIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundTaskConfiguration.nightlyStorageCleanupInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            CrashBreadcrumbs.shared.record("schedule_storage_cleanup_submitted")
        } catch {
            CrashBreadcrumbs.shared.record("schedule_storage_cleanup_failed", details: error.localizedDescription)
            BasicLogger.shared.log(error.localizedDescription)
        }
#endif
    }

    func runAutomaticTranscriptionSweep(reason: String) async {
        CrashBreadcrumbs.shared.record("automatic_transcription_sweep_started", details: reason)
        let startedEpisodeURL = await TranscriptionManager.shared.processNextAutomaticTranscriptionFromUpNext()
        if let startedEpisodeURL {
            CrashBreadcrumbs.shared.record("automatic_transcription_sweep_started_episode", details: startedEpisodeURL.absoluteString)
            BasicLogger.shared.log("automatic transcription sweep (\(reason)) started for \(startedEpisodeURL.absoluteString)")
        } else {
            CrashBreadcrumbs.shared.record("automatic_transcription_sweep_idle", details: reason)
        }
    }

    func setLastStorageCleanupDate(_ date: Date = Date()) {
        UserDefaults.standard.setValue(date.timeIntervalSince1970, forKey: BackgroundTaskConfiguration.lastStorageCleanupKey)
    }

    func getLastStorageCleanupDate() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: BackgroundTaskConfiguration.lastStorageCleanupKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func runScheduledStorageCleanupIfNeeded(minimumInterval: TimeInterval, reason: String) async {
        guard let container = modelContainerManager.preparedContainer else { return }
        CrashBreadcrumbs.shared.record("storage_cleanup_check_started", details: reason)
        if let lastCleanup = getLastStorageCleanupDate(),
           Date().timeIntervalSince(lastCleanup) < minimumInterval {
            CrashBreadcrumbs.shared.record("storage_cleanup_skipped_recent", details: reason)
            return
        }

        do {
            let result = try await StorageManagementService(modelContainer: container)
                .deleteFilesOutsideUpNext()
            let chapterImageResult = await EpisodeActor(modelContainer: container)
                .maintainChapterImageStorage()
            setLastStorageCleanupDate()
            downloadedFilesManager.rescanDownloadedFiles()
            CrashBreadcrumbs.shared.record(
                "storage_cleanup_completed",
                details: "\(reason):deleted=\(result.deletedFileCount),kept=\(result.keptUpNextFileCount),chapter_images_optimized=\(chapterImageResult.optimizedImageCount)"
            )
            BasicLogger.shared.log(
                "storage cleanup (\(reason)) deleted \(result.deletedFileCount) files, kept \(result.keptUpNextFileCount) Up Next files, optimized \(chapterImageResult.optimizedImageCount) chapter images saving \(chapterImageResult.optimizedBytesSaved) bytes, restored \(chapterImageResult.restoredImageCount) Up Next chapter images"
            )
        } catch {
            CrashBreadcrumbs.shared.record("storage_cleanup_failed", details: "\(reason):\(error.localizedDescription)")
            BasicLogger.shared.log("storage cleanup failed (\(reason)): \(error.localizedDescription)")
        }
    }

    func setLastForegroundDownloadCleanupDate(_ date: Date = Date()) {
        UserDefaults.standard.setValue(date.timeIntervalSince1970, forKey: BackgroundTaskConfiguration.lastForegroundDownloadCleanupKey)
    }

    func getLastForegroundDownloadCleanupDate() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: BackgroundTaskConfiguration.lastForegroundDownloadCleanupKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
    
}



extension DeviceUIStyle {
    var sfSymbolName: String {
        switch self {
        case .iphoneHomeButton: return "iphone.gen1"
        case .iphoneNotch: return "iphone.gen2"
        case .iphoneDynamicIsland: return "iphone.gen3"
        case .ipadHomeButton: return "ipad.gen1"
        case .ipadNoHomeButton: return "ipad.gen2"
        case .appleWatch: return "applewatch"
        case .visionPro: return "visionpro"
        case .macLaptop: return "macbook"
        case .macMini: return "macmini"
        case .macPro: return "macpro.gen3"
        case .macDesktop: return "desktopcomputer"
        @unknown default: return "questionmark.square.dashed"
        }
    }
    
    var currencySFSymbolName: String {
        let code = Locale.current.currency?.identifier  ?? ""
        
        // Map ISO currency codes to SF Symbol currency names
        let map: [String: String] = [
            "USD": "dollarsign",
            "EUR": "eurosign",
            "JPY": "yensign",
            "GBP": "sterlingsign",
            "KRW": "wonsign",
            "INR": "indianrupeesign",
            "RUB": "rublesign",
            "TRY": "turkishlirasign",
            "VND": "vietnamesedongsign",
            "ILS": "shekelsign",
            "THB": "bahtsign",
            "PLN": "zlotysign",
            "CZK": "czechkorunasign",
            "HUF": "forintsign",
            "NGN": "nairasign",
            "BRL": "brazilsign",
            "ZAR": "randsign",
            "PHP": "philippinepesosign",
            "MXN": "pesosign"
        ]
        
        let symbolBase = map[code] ?? "creditcard"
        return "\(symbolBase).circle"
    }
}
