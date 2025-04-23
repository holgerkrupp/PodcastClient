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
        .backgroundTask(.appRefresh("feedRefresh")) {
            await setLastprocessDate()
       //     await SubscriptionManager(modelContainer: modelContainerManager.container).bgupdateFeeds()
        }
        .backgroundTask(.appRefresh("checkFeedUpdates")) { task in
            await bgNewAppRefresh()
            await setLastRefreshDate()
            await scheduleAppRefresh()
     //       let shouldRefresh = await SubscriptionManager(modelContainer: modelContainerManager.container).bgcheckIfFeedsShouldRefresh()
                
           
            
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
        print("went to background started bgNewAppRefresh")
       
        let request = BGAppRefreshTaskRequest(identifier: "checkFeedUpdates")
        
        do{
            try BGTaskScheduler.shared.submit(request)
            
        }catch{
            print(error)
        }
    }
    
    
    func scheduleAppRefresh() {
        print("went to background will schedule AppRefresh")
        let request = BGProcessingTaskRequest(identifier: "feedRefresh")
        request.requiresNetworkConnectivity = true
        do{
            try BGTaskScheduler.shared.submit(request)
            
        }catch{
            print(error)
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
