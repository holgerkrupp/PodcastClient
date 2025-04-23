import SwiftData
import SwiftUI

class ModelContainerManager: ObservableObject {
    let container: ModelContainer

    init() {
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.de.holgerkrupp.PodcastClient") else {
            fatalError("Shared container URL not found.")
        }

        let configuration = ModelConfiguration(
            url: sharedContainerURL.appendingPathComponent("SharedDatabase.sqlite"),
            cloudKitDatabase: .automatic
        )
        
        do {
            container = try ModelContainer(for: Podcast.self, Episode.self, Playlist.self, PlaylistEntry.self, Chapter.self, configurations: configuration)
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }
}
