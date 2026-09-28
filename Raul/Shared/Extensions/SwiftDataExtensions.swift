//
//  SwiftDataExtensions.swift
//  Raul
//
//  Created by Holger Krupp on 30.04.25.
//

import Foundation
import SwiftData


extension ModelContext{
    func saveIfNeeded(){
        // print("save if needed - \(self.hasChanges)")
        if self.hasChanges{
                do {
                    try self.save()
                }catch{
                  // print(error.localizedDescription)
                }
            }
    }

    // These helpers intentionally remain concrete. SwiftData's query
    // descriptor metadata is compiled from the model type; building the same
    // predicate through `T: PersistentModel` can trigger a framework assertion
    // in optimized builds (especially on iOS 27).
    func existingModel(for id: PersistentIdentifier) -> Podcast? {
        var descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.persistentModelID == id }
        )
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    func existingModel(for id: PersistentIdentifier) -> Episode? {
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.persistentModelID == id }
        )
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    func existingModel(for id: PersistentIdentifier) -> PodcastMetaData? {
        var descriptor = FetchDescriptor<PodcastMetaData>(
            predicate: #Predicate<PodcastMetaData> { $0.persistentModelID == id }
        )
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    func existingModel(for id: PersistentIdentifier) -> PodcastSettings? {
        var descriptor = FetchDescriptor<PodcastSettings>(
            predicate: #Predicate<PodcastSettings> { $0.persistentModelID == id }
        )
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    func existingModel(for id: PersistentIdentifier) -> PlaySession? {
        var descriptor = FetchDescriptor<PlaySession>(
            predicate: #Predicate<PlaySession> { $0.persistentModelID == id }
        )
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }

    func existingModels(for ids: [PersistentIdentifier]) -> [PersistentIdentifier: Podcast] {
        let uniqueIDs = Array(Set(ids))
        guard uniqueIDs.isEmpty == false else { return [:] }
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { uniqueIDs.contains($0.persistentModelID) }
        )
        let models = (try? fetch(descriptor)) ?? []
        return models.reduce(into: [:]) { $0[$1.persistentModelID] = $1 }
    }

    func existingModels(for ids: [PersistentIdentifier]) -> [PersistentIdentifier: Episode] {
        let uniqueIDs = Array(Set(ids))
        guard uniqueIDs.isEmpty == false else { return [:] }
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { uniqueIDs.contains($0.persistentModelID) }
        )
        let models = (try? fetch(descriptor)) ?? []
        return models.reduce(into: [:]) { $0[$1.persistentModelID] = $1 }
    }
}
