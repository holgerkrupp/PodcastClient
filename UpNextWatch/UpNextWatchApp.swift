import SwiftUI

@main
struct UpNextWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = WatchSyncStore()
    @StateObject private var playbackController = WatchPlaybackController()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(store)
                .environmentObject(playbackController)
                .task {
                    playbackController.attach(store: store)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase != .active {
                        playbackController.flushProgress()
                    }
                }
        }
    }
}
