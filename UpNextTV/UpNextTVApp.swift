import SwiftUI

@main
struct UpNextTVApp: App {
    @StateObject private var bootstrapStore = TVPremiumBootstrapStore()

    var body: some Scene {
        WindowGroup {
            TVPremiumBootstrapView()
                .environmentObject(bootstrapStore)
        }
    }
}
