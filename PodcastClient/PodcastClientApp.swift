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
          let pm = PersistanceManager.shared
          
          self.sharedModelContainer = pm.sharedModelContainer
          UserDefaults.standard.register(defaults: ["UserAgent" : "Raúl Podcatcher"])
          
      }

    var body: some Scene {
        WindowGroup {
            TabBarView()
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: phase, {
            switch phase {
            case .background: scheduleAppRefresh()
            default: break
            }
        })
        .backgroundTask(.appRefresh("feedRefresh")) {
            await SubscriptionManager.shared.refreshall()
        }
     
    }
    
    
    
    func scheduleAppRefresh() {
        print("went to background will schedule AppRefresh")
        let request = BGProcessingTaskRequest(identifier: "feedRefresh")
        request.earliestBeginDate = .now.addingTimeInterval(1 * 3600)

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

