import SwiftUI
import WidgetKit

@main
struct UpNextWatchComplicationsBundle: WidgetBundle {
    var body: some Widget {
        WatchAppLauncherComplication()
        WatchEpisodeProgressComplication()
        WatchEpisodeArtworkComplication()
        WatchPlaylistRemainingComplication()
        WatchSyncStatusComplication()
    }
}
