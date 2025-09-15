import SwiftUI
import SwiftData
import BackgroundTasks
import DeviceInfo
import BasicLogger

@main
struct RaulApp: App {
    @StateObject private var modelContainerManager = ModelContainerManager.shared
    @State private var downloadedFilesManager = DownloadedFilesManager(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
    @Environment(\.scenePhase) private var phase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        _ = Player.shared
      
    }

    var body: some Scene {
        WindowGroup {
           
                ContentView()
                    .modelContainer(modelContainerManager.container)
                    .environment(downloadedFilesManager)
                    .accentColor(.accent)
                    .withDeviceStyle()

                    .onAppear {
                        let manager = downloadedFilesManager  // Capture outside the @Sendable closure
                        Task { @Sendable in
                            await DownloadManager.shared.injectDownloadedFilesManager(manager)
                        }
                    }
             
            
        }
        .onChange(of: phase, {
            switch phase {
            case .background:
                bgNewAppRefresh()
             
                
            case .active:
                cleanUp()
                refreshOnActive()
          
                
            default: break
            }
        })

        .backgroundTask(.appRefresh("checkFeedUpdates")) { task in
           //  await BasicLogger.shared.log("started checkFeedUpdates in Background")
            await bgNewAppRefresh()
       
            await SubscriptionManager(modelContainer: modelContainerManager.container).bgupdateFeeds()

            
        }
    }

    func refreshOnActive(){
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
    
    func bgNewAppRefresh() {
        
        // this should replace scheduleAppRefresh
        BasicLogger.shared.log("schedule checkFeedUpdates")
        let request = BGAppRefreshTaskRequest(identifier: "checkFeedUpdates")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60*30)
        
        do{
            try BGTaskScheduler.shared.submit(request)

        }catch{
            // print(error)
            BasicLogger.shared.log(error.localizedDescription)
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
        case .macLaptop: return "macbook"
        case .macMini: return "macmini"
        case .macPro: return "macpro.gen3"
        case .macDesktop: return "desktopcomputer"
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
