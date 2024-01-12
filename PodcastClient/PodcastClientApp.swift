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

    
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Podcast.self,
            Episode.self,
            Chapter.self,

            PodcastSettings.self,

            Playlist.self,
            PlaylistEntry.self
            
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

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
            print("startig Background refresh at \(Date().formatted())")
            await SubscriptionManager.shared.refreshall()
            print("Ending Background refresh at \(Date().formatted())")

        }
     
    }
    
    
    
    func scheduleAppRefresh() {
        print("requesting Background Refresh")
        let request = BGAppRefreshTaskRequest(identifier: "feedRefresh")
        request.earliestBeginDate = .now.addingTimeInterval(1 * 30)
        do {
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
