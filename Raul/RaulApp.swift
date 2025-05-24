//
//  RaulApp.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import SwiftData
import BackgroundTasks
import DeviceInfo
import BasicLogger

@main
struct RaulApp: App {
    @StateObject private var modelContainerManager = ModelContainerManager()
    @Environment(\.scenePhase) private var phase
    

    init() {
        _ = Player.shared
      
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainerManager.container)
                .accentColor(.accent)
                .withDeviceStyle()
        }
        .onChange(of: phase, {
            switch phase {
            case .background:
                bgNewAppRefresh()
         
          
                
              //  debugActions()
            default: break
            }
        })

        .backgroundTask(.appRefresh("checkFeedUpdates")) { task in
            await BasicLogger.shared.log("started checkFeedUpdates in Background")
            await bgNewAppRefresh()
            
            await SubscriptionManager(modelContainer: ModelContainerManager().container).bgupdateFeeds()
        }
    }

    

    func debugActions() {
        let sharedContainerURL :URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.de.holgerkrupp.PodcastClient")
        // replace "group.etc.etc" above with your App Group's identifier
        NSLog("sharedContainerURL = \(String(describing: sharedContainerURL))")
        if let sourceURL :URL = sharedContainerURL?.appendingPathComponent("SharedDatabase.sqlite") {
            if let destinationURL :URL = FileManager().urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("copyOfStore.sqlite") {
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
        BasicLogger.shared.log("going to background will schedule checkFeedUpdates")
        let request = BGAppRefreshTaskRequest(identifier: "checkFeedUpdates")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30)
        
        do{
            try BGTaskScheduler.shared.submit(request)

        }catch{
            print(error)
            BasicLogger.shared.log(error.localizedDescription)
        }
       
    }
    
}

struct CarPlayScene: Scene {
    let container = ModelContainerManager().container
    var body: some Scene {
        WindowGroup {
           // CarPlayPlayNext()
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
}
extension Bundle {
    /// Application name shown under the application icon.
    var applicationName: String? {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
        object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}
