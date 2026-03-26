import SwiftUI

@main
struct UpNextWatchApp: App {
    @StateObject private var store = WatchSyncStore()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(store)
        }
    }
}
