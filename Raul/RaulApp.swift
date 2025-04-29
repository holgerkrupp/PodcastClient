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
            //    scheduleAppRefresh()
                bgNewAppRefresh()
            
            default: break
            }
        })
        .backgroundTask(.appRefresh("feedRefresh")) { task in
            await BasicLogger.shared.log("started feedRefresh in Background")

            await setLastprocessDate()
            await SubscriptionManager(modelContainer: ModelContainerManager().container).bgupdateFeeds()
        }
        .backgroundTask(.appRefresh("checkFeedUpdates")) { task in
            await BasicLogger.shared.log("started checkFeedUpdates in Background")
            await bgNewAppRefresh()
            await setLastRefreshDate()
            await scheduleAppRefresh()
            let shouldRefresh = await SubscriptionManager(modelContainer: ModelContainerManager().container).bgcheckIfFeedsShouldRefresh()
         /*
            if shouldRefresh {
                await SubscriptionManager(modelContainer: ModelContainerManager().container).bgupdateFeeds()
            }
           */
            
        }
    }



    
    func setLastRefreshDate(){
        UserDefaults.standard.setValue(Date().formatted(), forKey: "LastBackgroundRefresh")
    }
    
    func setLastprocessDate(){
        UserDefaults.standard.setValue(Date().formatted(), forKey: "LastBackgroundProcess")
    }
    
    func bgNewAppRefresh(){
        
        // this should replace scheduleAppRefresh
        BasicLogger.shared.log("going to background will schedule checkFeedUpdates")
        let request = BGAppRefreshTaskRequest(identifier: "checkFeedUpdates")
        
        do{
            try BGTaskScheduler.shared.submit(request)

        }catch{
            print(error)
            BasicLogger.shared.log(error.localizedDescription)
        }
    }
    
    
    func scheduleAppRefresh() {
        BasicLogger.shared.log("going to background will schedule feedRefresh")
        let request = BGProcessingTaskRequest(identifier: "feedRefresh")
        request.requiresNetworkConnectivity = true
        do{
            try BGTaskScheduler.shared.submit(request)
        }catch{
            print(error)
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
}
extension Bundle {
    /// Application name shown under the application icon.
    var applicationName: String? {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
        object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}
