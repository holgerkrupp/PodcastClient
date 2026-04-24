import SwiftUI
import SwiftData
import BackgroundTasks
import DeviceInfo
import BasicLogger
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
    @Environment(\.scenePhase) private var phase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        CrashBreadcrumbs.shared.record("raul_app_init_start")
        SyncMonitor.default.startMonitoring()
        _ = Player.shared
        WatchSyncCoordinator.activate()
        CrashBreadcrumbs.shared.record("raul_app_init_completed")
    }

    var body: some Scene {
        WindowGroup {
            AppLaunchContainerView{
                ContentView()
                    .modelContainer(modelContainerManager.container)
                    .environment(downloadedFilesManager)
                    .accentColor(.accent)
                    .withDeviceStyle()
                
                    .onAppear {
                        CrashBreadcrumbs.shared.record("root_view_on_appear")
                        let managerReference = DownloadedFilesManagerReference(manager: downloadedFilesManager)
                        Task {
                            await DownloadManager.shared.injectDownloadedFilesManager(managerReference)
                        }
                        Task {
                            await PlayNextWidgetSync.refresh(using: modelContainerManager.container)
                            WatchSyncCoordinator.refreshSoon()
                        }
                        Task {
                            await AutoDownloadNetworkCoordinator.shared.startMonitoringIfNeeded(
                                modelContainer: modelContainerManager.container
                            )
                        }
                        Task {
                            let actor = EpisodeActor(modelContainer: modelContainerManager.container)
                            await actor.migrateLegacyBackCatalogSuppressionIfNeeded()
                        }
                        UIDevice.current.isBatteryMonitoringEnabled = true
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
                    .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
                        CrashBreadcrumbs.shared.record("battery_state_changed")
                        Task {
                            await runAutomaticTranscriptionSweep(reason: "power state changed")
                        }
                    }
            }
        }
        .onChange(of: phase, {
            CrashBreadcrumbs.shared.record("scene_phase_changed", details: "\(phase)")
            switch phase {
            case .background:
                scheduleFeedRefresh()
                scheduleStorageCleanup()
                Task {
                    await AppDelegate.scheduleAutomaticTranscriptionProcessingIfNeeded()
                }
             
                
            case .active:
                cleanUp()
                refreshOnActive()
                Task {
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

        .backgroundTask(.appRefresh(BackgroundTaskConfiguration.feedRefreshIdentifier)) { task in
           //  await BasicLogger.shared.log("started checkFeedUpdates in Background")
            await scheduleFeedRefresh()
            CrashBreadcrumbs.shared.record("skip_storage_cleanup_in_feed_refresh_task")
       
            await SubscriptionManager(modelContainer: modelContainerManager.container).bgupdateFeeds()

            
        }
        .backgroundTask(.appRefresh(BackgroundTaskConfiguration.storageCleanupIdentifier)) { task in
            await scheduleStorageCleanup()
            CrashBreadcrumbs.shared.record("skip_storage_cleanup_in_background_task")
        }
    }

    func refreshOnActive(){
        WatchSyncCoordinator.refreshSoon()
        if let lastRefresh = getLastRefreshDate(), lastRefresh < Date().addingTimeInterval(-60*60) {
            Task .detached {
                await SubscriptionManager(modelContainer: modelContainerManager.container).bgupdateFeeds()
            }
        }
    }
    
    
    func cleanUp()  {
        if let lastCleanup = getLastForegroundDownloadCleanupDate(),
           Date().timeIntervalSince(lastCleanup) < BackgroundTaskConfiguration.foregroundDownloadCleanupMinimumInterval {
            return
        }

        setLastForegroundDownloadCleanupDate()
        let modelContainer = modelContainerManager.container
        Task.detached(priority: .utility) {
            let janitor = CleanUpActor(modelContainer: modelContainer)
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
       
    }

    func scheduleStorageCleanup() {
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
        CrashBreadcrumbs.shared.record("storage_cleanup_check_started", details: reason)
        if let lastCleanup = getLastStorageCleanupDate(),
           Date().timeIntervalSince(lastCleanup) < minimumInterval {
            CrashBreadcrumbs.shared.record("storage_cleanup_skipped_recent", details: reason)
            return
        }

        do {
            let result = try await StorageManagementService(modelContainer: modelContainerManager.container)
                .deleteFilesOutsideUpNext()
            let chapterImageResult = await EpisodeActor(modelContainer: modelContainerManager.container)
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
