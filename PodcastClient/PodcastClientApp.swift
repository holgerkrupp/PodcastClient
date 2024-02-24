//
//  PodcastClientApp.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import SwiftUI
import SwiftData
import BackgroundTasks


@main

struct PodcastClientApp: App {
    @Environment(\.scenePhase) private var phase

      var sharedModelContainer: ModelContainer

     
      init() {
          let pm = PersistenceManager.shared
          
          self.sharedModelContainer = pm.sharedModelContainer
          UserDefaults.standard.register(defaults: ["UserAgent" : "Raúl Podcatcher"])
          
      }

    var body: some Scene {
        WindowGroup {
               
               TabBarView()
                    .accentColor(.accent)
            
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: phase, {
            switch phase {
            case .background: 
            //    scheduleAppRefresh()
                bgNewAppRefresh()
            default: break
            }
        })
        .backgroundTask(.appRefresh("feedRefresh")) {
            
            await SubscriptionManager.shared.bgupdateFeeds()
        }
        .backgroundTask(.appRefresh("checkFeedUpdates")) { task in
            bgNewAppRefresh()
            setLastRefreshDate()
            scheduleAppRefresh()
            let shouldRefresh = await SubscriptionManager.shared.bgcheckIfFeedsShouldRefresh()
                /*
            if shouldRefresh == true{
                scheduleAppRefresh()
            }*/
            
        }
        
    }
    
    func setLastRefreshDate(){
        UserDefaults.standard.setValue(Date().formatted(), forKey: "LastBackgroundRefresh")
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

extension Bundle {
    /// Application name shown under the application icon.
    var applicationName: String? {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
        object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}


/*
struct CarPlayScene: Scene {
    var body: some Scene {
        WindowGroup {
            CarPlayUpNextView()
        }
    }
}
*/
/*
 
 e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"checkFeedUpdates"]

 e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"checkFeedUpdates"]

 */
