//
//  PlaylistActor.swift
//  Raul
//
//  Created by Holger Krupp on 23.04.25.
//
import SwiftData
import Foundation




//@ModelActor
actor PlaylistModelActor : ModelActor {
    let playlist: Playlist

    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor
    
    public init(modelContainer: ModelContainer, playlistID: UUID) {
      let modelContext = ModelContext(modelContainer)
      modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
      self.modelContainer = modelContainer
        
        
        let predicate = #Predicate<Playlist> { playlist in
            playlist.id == playlistID
        }

                do {
                    let results = try modelContext.fetch(FetchDescriptor<Playlist>(predicate: predicate))
                    guard let playlist = results.first else {
                        self.playlist = Playlist()
                        return
                    }
                    self.playlist = playlist
                } catch {
                    self.playlist = Playlist()
                }
    }
    
    
    
    
    
    
    /// - Parameters:
    ///   - modelContainer: The ModelContainer to use
    ///   - playlistTitle: An optional Title to use, if not set, the playNext List is used
    public init(modelContainer: ModelContainer, playlistTitle: String = "de.holgerkrupp.podbay.queue") {
      let modelContext = ModelContext(modelContainer)
      modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
      self.modelContainer = modelContainer
        
        
        let predicate = #Predicate<Playlist> { playlist in
            playlist.title == playlistTitle
        }

                do {
                    let results = try modelContext.fetch(FetchDescriptor<Playlist>(predicate: predicate))
                    guard let playlist = results.first else {
                        self.playlist = Playlist()
                        return
                    }
                    self.playlist = playlist
                } catch {
                    self.playlist = Playlist()
                }
    }
    
  
    func orderedEpisodes() -> [Episode] {
        return playlist.ordered.compactMap { $0.episode }
    }
    
    func nextEpisode() -> UUID? {
        return orderedEpisodes().first?.id 
    }
    
    // Add an episode to the playlist
    func add(episodeID: UUID, to position: Playlist.Position = .end) async {
        
        let predicate = #Predicate<Episode> { episode in
            // Direct comparison of the episode's persistentModelID
            episode.id == episodeID
        }

                do {
                    let results = try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate))
                    guard let episode = results.first else {
                        print("❌ No episode found for episode ID: \(episodeID)")
                        return
                    }

                 

                    var newPosition = 0
                    switch position {
                    case .front:
                        newPosition = (playlist.ordered.first?.order ?? 0) - 1
                    case .end:
                        newPosition = (playlist.ordered.last?.order ?? 0) + 1
                    case .none:
                        newPosition = (playlist.ordered.last?.order ?? 0)
                    }

                    if let existingItem = playlist.items?.first(where: { $0.episode == episode }) {
                        existingItem.order = newPosition
                        print("puted episode in new Position \(newPosition)")
                    } else {
                        let newEntry = PlaylistEntry(episode: episode, order: newPosition)
                        if playlist.items == nil {
                            playlist.items = [newEntry]
                        } else {
                            playlist.items?.append(newEntry)
                        }
                        print("added episode in new Position \(newPosition)")

                    }
                    
                    episode.metaData?.isInbox = false
                    
                    modelContext.saveIfNeeded()
                    print("✅ Playlist updated")
                    
                    let episodeActor = EpisodeActor(modelContainer: modelContainer)
                    await episodeActor.download(episodeID: episode.id)
                    
                } catch {
                    print("error saving Playlist \(error)")
                }
 



    }

    // Remove an episode from the playlist
    func remove(episodeID: UUID) {
        
        let predicate = #Predicate<Episode> { episode in
            // Direct comparison of the episode's persistentModelID
            episode.id == episodeID
        }

                do {
                    let results = try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate))
                    guard let episode = results.first else {
                        print("❌ No episode found for episode ID: \(episodeID)")
                        return
                    }
                    
                    
                    guard
                          let entry = playlist.items?.first(where: { $0.episode == episode }) else {
                        return
                    }
                    if let index = playlist.items?.firstIndex(of: entry) {
                        playlist.items?.remove(at: index)
                        modelContext.delete(entry)
                    }

                    
                    
                     modelContext.saveIfNeeded()
                    print("✅ Playlist updated")
                } catch {
                    print("error saving Playlist \(error)")
                }
        
        
  


    }

    // Reorder playlist entries
    func moveEntry(from sourceIndex: Int, to destinationIndex: Int) {
        guard let entries = playlist.items else {
            return
        }

        let sorted = entries.sorted { $0.order < $1.order }

        guard sourceIndex < sorted.count, destinationIndex < sorted.count else { return }

        let movedEntry = sorted[sourceIndex]
        var reordered = sorted
        reordered.remove(at: sourceIndex)
        reordered.insert(movedEntry, at: destinationIndex)

        for (i, entry) in reordered.enumerated() {
            entry.order = i
        }

         modelContext.saveIfNeeded()
    }
    
    func normalizeOrder() {

        for (i, entry) in (playlist.ordered).enumerated() {
            entry.order = i
        }

         modelContext.saveIfNeeded()
    }
}
