import SwiftUI
import SwiftData
import BackgroundTasks
import DeviceInfo
import BasicLogger

private enum BackgroundTaskConfiguration {
    static let feedRefreshIdentifier = "checkFeedUpdates"
    static let storageCleanupIdentifier = "storageCleanup"
    static let feedRefreshInterval: TimeInterval = 60 * 30
    static let nightlyStorageCleanupInterval: TimeInterval = 60 * 60 * 24
    static let weeklyStorageCleanupFallbackInterval: TimeInterval = 60 * 60 * 24 * 7
    static let lastStorageCleanupKey = "LastStorageCleanup"
}

@main
struct RaulApp: App {
    @StateObject private var modelContainerManager = ModelContainerManager.shared
    @State private var downloadedFilesManager = DownloadedFilesManager(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
    @Environment(\.scenePhase) private var phase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        _ = Player.shared
        WatchSyncCoordinator.activate()
    }

    var body: some Scene {
        WindowGroup {
            
                ContentView()
                    .modelContainer(modelContainerManager.container)
                    .environment(downloadedFilesManager)
                    .accentColor(.accent)
                    .withDeviceStyle()

                    .onAppear {
                        let managerReference = DownloadedFilesManagerReference(manager: downloadedFilesManager)
                        Task {
                            await DownloadManager.shared.injectDownloadedFilesManager(managerReference)
                        }
                        Task {
                            await PlayNextWidgetSync.refresh(using: modelContainerManager.container)
                            WatchSyncCoordinator.refreshSoon()
                        }
                    }
            
        }
        .onChange(of: phase, {
            switch phase {
            case .background:
                scheduleFeedRefresh()
                scheduleStorageCleanup()
             
                
            case .active:
                cleanUp()
                refreshOnActive()
                Task {
                    await runScheduledStorageCleanupIfNeeded(
                        minimumInterval: BackgroundTaskConfiguration.weeklyStorageCleanupFallbackInterval,
                        reason: "active fallback"
                    )
                }
          
                
            default: break
            }
        })

        .backgroundTask(.appRefresh(BackgroundTaskConfiguration.feedRefreshIdentifier)) { task in
           //  await BasicLogger.shared.log("started checkFeedUpdates in Background")
            await scheduleFeedRefresh()
            await runScheduledStorageCleanupIfNeeded(
                minimumInterval: BackgroundTaskConfiguration.nightlyStorageCleanupInterval,
                reason: "feed refresh task"
            )
       
            await SubscriptionManager(modelContainer: modelContainerManager.container).bgupdateFeeds()

            
        }
        .backgroundTask(.appRefresh(BackgroundTaskConfiguration.storageCleanupIdentifier)) { task in
            await scheduleStorageCleanup()
            await runScheduledStorageCleanupIfNeeded(
                minimumInterval: BackgroundTaskConfiguration.nightlyStorageCleanupInterval,
                reason: "storage cleanup task"
            )
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
    
            Task{
                let janitor = CleanUpActor(modelContainer: modelContainerManager.container)
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
        BasicLogger.shared.log("schedule checkFeedUpdates")
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskConfiguration.feedRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundTaskConfiguration.feedRefreshInterval)
        
        do{
            try BGTaskScheduler.shared.submit(request)

        }catch{
            // print(error)
            BasicLogger.shared.log(error.localizedDescription)
        }
       
    }

    func scheduleStorageCleanup() {
        BasicLogger.shared.log("schedule storageCleanup")
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskConfiguration.storageCleanupIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundTaskConfiguration.nightlyStorageCleanupInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            BasicLogger.shared.log(error.localizedDescription)
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
        if let lastCleanup = getLastStorageCleanupDate(),
           Date().timeIntervalSince(lastCleanup) < minimumInterval {
            return
        }

        do {
            let result = try await StorageManagementService(modelContainer: modelContainerManager.container)
                .deleteFilesOutsideUpNext()
            let chapterImageResult = await EpisodeActor(modelContainer: modelContainerManager.container)
                .maintainChapterImageStorage()
            setLastStorageCleanupDate()
            downloadedFilesManager.rescanDownloadedFiles()
            BasicLogger.shared.log(
                "storage cleanup (\(reason)) deleted \(result.deletedFileCount) files, kept \(result.keptUpNextFileCount) Up Next files, optimized \(chapterImageResult.optimizedImageCount) chapter images saving \(chapterImageResult.optimizedBytesSaved) bytes, restored \(chapterImageResult.restoredImageCount) Up Next chapter images"
            )
        } catch {
            BasicLogger.shared.log("storage cleanup failed (\(reason)): \(error.localizedDescription)")
        }
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
