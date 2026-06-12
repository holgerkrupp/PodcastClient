import SwiftData
import SwiftUI

@MainActor
class ModelContainerManager: ObservableObject {
    nonisolated static let appGroupID = "group.de.holgerkrupp.PodcastClient"

    @Published private(set) var preparedContainer: ModelContainer?
    @Published private(set) var initializationError: String?
    @Published private(set) var isInitializing = false
    @Published private(set) var requiresInitialCloudImport = false
    private var preparationTask: Task<ModelContainer, Error>?

    var container: ModelContainer {
        guard let preparedContainer else {
            preconditionFailure("ModelContainer accessed before preparation completed")
        }
        return preparedContainer
    }
    
    static let shared = ModelContainerManager()

    nonisolated static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    nonisolated static var sharedStoreURL: URL? {
        sharedContainerURL?.appendingPathComponent("SharedDatabase.sqlite")
    }

    
    func prepareContainer() async {
        guard preparedContainer == nil else { return }

        let task: Task<ModelContainer, Error>
        if let preparationTask {
            task = preparationTask
        } else {
            isInitializing = true
            initializationError = nil
            requiresInitialCloudImport = Self.sharedStoreURL.map {
                !FileManager.default.fileExists(atPath: $0.path)
            } ?? false
            CrashBreadcrumbs.shared.record("model_container_initialization_started")

            let newTask = Task.detached(priority: .userInitiated) {
                try Self.makeContainer()
            }
            preparationTask = newTask
            task = newTask
        }

        do {
            let preparedContainer = try await task.value
            if self.preparedContainer == nil {
                self.preparedContainer = preparedContainer
                CrashBreadcrumbs.shared.record("model_container_initialization_completed")
            }
        } catch {
            if initializationError == nil {
                initializationError = error.localizedDescription
                CrashBreadcrumbs.shared.record(
                    "model_container_initialization_failed",
                    details: error.localizedDescription
                )
            }
        }

        preparationTask = nil
        isInitializing = false
    }

    nonisolated private static func makeContainer() throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let sharedContainerURL = sharedContainerURL {
            configuration = ModelConfiguration(
                url: sharedContainerURL.appendingPathComponent("SharedDatabase.sqlite"),
                cloudKitDatabase: .automatic
            )
        } else {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        }

        return try ModelContainer(
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
}
