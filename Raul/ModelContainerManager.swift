import SwiftData
import SwiftUI

@MainActor
class ModelContainerManager: ObservableObject {
    let container: ModelContainer
    
    static let shared = ModelContainerManager()

    
    init() {
        do {
            if let sharedContainerURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.de.holgerkrupp.PodcastClient") {
                
                let configuration = ModelConfiguration(
                    url: sharedContainerURL.appendingPathComponent("SharedDatabase.sqlite"),
                    cloudKitDatabase: .automatic
                )
                
                container = try ModelContainer(
                    for: Podcast.self,
                        PodcastMetaData.self,
                        Episode.self,
                        EpisodeMetaData.self,
                        Playlist.self,
                        PlaylistEntry.self,
                        Marker.self,
                    configurations: configuration
                )
                
            } else {
                print("⚠️ Shared container URL not found. Falling back to in-memory store.")
                let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
                container = try ModelContainer(
                    for: Podcast.self,
                        PodcastMetaData.self,
                        Episode.self,
                        EpisodeMetaData.self,
                        Playlist.self,
                        PlaylistEntry.self,
                        Marker.self,
                    configurations: configuration
                )
            }
        } catch {
            fatalError("❌ Failed to initialize ModelContainer: \(error)")
        }
    }
}
