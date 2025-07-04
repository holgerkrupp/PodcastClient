//
//  PlaylistActor.swift
//  Raul
//
//  Created by Holger Krupp on 23.04.25.
//
import SwiftData
import Foundation
import BasicLogger

struct EpisodeSummary: Sendable {
    let id: UUID
    let title: String?
    let desc: String?
}


//@ModelActor
actor PlaylistModelActor : ModelActor {
    var playlist: Playlist

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
    
    
    
    func fetchEpisode(byID episodeID: UUID) async -> Episode? {
        let predicate = #Predicate<Episode> { episode in
            episode.id == episodeID
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate))
            return results.first
        } catch {
            print("❌ Error fetching episode for episode ID: \(episodeID), Error: \(error)")
            return nil
        }
    }
    
    
    
    func fetchEpisode(byURL fileURL: URL) async -> Episode? {
        let predicate = #Predicate<Episode> { episode in
            episode.url == fileURL
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate))
            return results.first
        } catch {
            print("❌ Error fetching episode for file URL: \(fileURL.absoluteString), Error: \(error)")
            return nil
        }
    }
    
    
    
    func refresh()  throws {
        let modelContext = ModelContext(modelContainer)
        
        // Re-fetch the playlist using the stored ID
     //   let predicate = #Predicate<Playlist> { $0.id == self.playlist.id }
        let playlistID = playlist.id
        let predicate = #Predicate<Playlist> { playlist in
            playlist.id == playlistID
        }
        let descriptor = FetchDescriptor<Playlist>(predicate: predicate)

        let results = try modelContext.fetch(descriptor)
        
        guard let refreshedPlaylist = results.first else {
            throw NSError(domain: "PlaylistModelActor", code: 404, userInfo: [NSLocalizedDescriptionKey: "Playlist not found during refresh"])
        }

        self.playlist = refreshedPlaylist

    }
    
  
    func orderedEpisodes() -> [Episode] {
        try? refresh()
        return playlist.ordered.compactMap { $0.episode }
    }
    
    func nextEpisode() -> UUID? {
   
        return orderedEpisodes().first?.id
    }
    
    // Add an episode to the playlist
    func add(episodeID: UUID, to position: Playlist.Position = .end) async {
        
        guard let episode = await fetchEpisode(byID: episodeID) else { return }
        
        await BasicLogger.shared.log("🎯 Adding episode \(episode.title) to playlist \(playlist.title) at position \(position)")

        let predicate = #Predicate<Episode> { $0.id == episodeID }

        


            // Determine new order
            let newPosition: Int
            switch position {
            case .front:
                newPosition = (playlist.ordered.first?.order ?? 0) - 1
            case .end:
                newPosition = (playlist.ordered.last?.order ?? 0) + 1
            case .none:
                newPosition = (playlist.ordered.last?.order ?? 0)
            }

            // Update if already exists
            if let existingItem = playlist.items.first(where: { $0.episode?.id == episode.id }) {
                existingItem.order = newPosition
              
                await BasicLogger.shared.log("🔄 Moved episode to position \(newPosition)")
            } else {
                let newEntry = PlaylistEntry(episode: episode, order: newPosition)
                newEntry.playlist = playlist
                episode.playlist.append(newEntry)
                await BasicLogger.shared.log("➕ Created and linked new PlaylistEntry at position \(newPosition) of \(playlist.title)")
            }
        
        

            episode.metaData?.isInbox = false
            episode.metaData?.isArchived = false
            episode.metaData?.status = .none
        
            modelContext.saveIfNeeded()
            await BasicLogger.shared.log("✅ Saved playlist changes")

            if episode.metaData?.calculatedIsAvailableLocally != true {
                Task {
                    let episodeActor = EpisodeActor(modelContainer: modelContainer)
                    await episodeActor.download(episodeID: episode.id)
                }
            }

    }

 
    func remove(episodeID: UUID) {
        print("remove episode \(episodeID)")
        do {
            // Find the PlaylistEntry directly using the same filter as your @Query
            let predicate = #Predicate<PlaylistEntry> {
                $0.episode?.id == episodeID &&
                $0.playlist?.title == "de.holgerkrupp.podbay.queue"
            }

            let entries = try modelContext.fetch(FetchDescriptor<PlaylistEntry>(predicate: predicate))
            guard let entry = entries.first else {
                print("❌ No PlaylistEntry found for episode ID: \(episodeID)")
                return
            }

            print("🗑 Removing entry for episode \(episodeID): \(entry.episode?.title ?? "Unknown")")

            // Delete the entry from SwiftData
            modelContext.delete(entry)

            // Save changes
            modelContext.saveIfNeeded()
            print("✅ PlaylistEntry deleted and context saved")
        } catch {
            print("❌ Failed to remove PlaylistEntry: \(error)")
        }
    }


    // Reorder playlist entries
    func moveEntry(from sourceIndex: Int, to destinationIndex: Int) {
        let entries = playlist.items

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
        print("morlaizing order")
        for (i, entry) in (playlist.ordered).enumerated() {
            entry.order = i
        }

         modelContext.saveIfNeeded()
    }
    
    func orderedEpisodeSummaries() async -> [EpisodeSummary] {
        let episodes = orderedEpisodes()
        return episodes.map { episode in
            EpisodeSummary(id: episode.id, title: episode.title, desc: episode.desc)
        }
    }
}
