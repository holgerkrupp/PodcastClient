import SwiftData
import SwiftUI

@MainActor
class ModelContainerManager: ObservableObject {
    nonisolated static let appGroupID = "group.de.holgerkrupp.PodcastClient"

    let container: ModelContainer
    
    static let shared = ModelContainerManager()

    nonisolated static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    nonisolated static var sharedStoreURL: URL? {
        sharedContainerURL?.appendingPathComponent("SharedDatabase.sqlite")
    }

    
    init() {
        do {
            if let sharedContainerURL = Self.sharedContainerURL {
                
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
                        Bookmark.self,
                        RateSegment.self,
                        PlaySession.self,
                        ListeningStat.self,
                        PlaySessionSummary.self,
                        TranscriptionRecord.self,
                    configurations: configuration
                )
                
            } else {
                // print("⚠️ Shared container URL not found. Falling back to in-memory store.")
                let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
                container = try ModelContainer(
                    for: Podcast.self,
                        PodcastMetaData.self,
                        Episode.self,
                        EpisodeMetaData.self,
                        Playlist.self,
                        PlaylistEntry.self,
                        Marker.self,
                    Bookmark.self,
                    RateSegment.self,
                    PlaySession.self,
                    ListeningStat.self,
                    PlaySessionSummary.self,
                    TranscriptionRecord.self,
                    configurations: configuration
                )
            }
        } catch {
            fatalError("❌ Failed to initialize ModelContainer: \(error)")
        }
    }
}
