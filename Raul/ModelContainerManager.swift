import SwiftData
import SwiftUI

class ModelContainerManager: ObservableObject {
    let container: ModelContainer?

    init() {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.de.holgerkrupp.PodcastClient") else {
            print("Shared container URL not found. Returning nil container.")
            container = nil
            return
        }

        let configuration = ModelConfiguration(
            url: sharedContainerURL.appendingPathComponent("SharedDatabase.sqlite"),
            cloudKitDatabase: .automatic
        )
        do {
            container = try ModelContainer(for: Podcast.self, PodcastMetaData.self, Episode.self, EpisodeMetaData.self, Playlist.self, PlaylistEntry.self, Chapter.self, configurations: configuration)
        } catch {
            print("Failed to initialize ModelContainer: \(error)")
            container = nil
        }
    }
}
