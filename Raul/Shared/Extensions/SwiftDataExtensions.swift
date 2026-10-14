//
//  SwiftDataExtensions.swift
//  Raul
//
//  Created by Holger Krupp on 30.04.25.
//

import Foundation
import SwiftData


extension ModelContext{
    func saveIfNeeded() {
        if hasChanges {
            do {
                try save()
            } catch {
                AppDiagnostics.log("SwiftData save failed: \(error.localizedDescription)")
                CrashBreadcrumbs.shared.record(
                    "swiftdata_save_failed",
                    details: error.localizedDescription
                )
            }
        }
    }

    /// Commit pending model changes and propagate failures to operations that
    /// must not report success until their write is durable.
    func commitChangesIfNeeded() throws {
        if hasChanges {
            try save()
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
        var resolved: [PersistentIdentifier: Podcast] = [:]
        // Keep each SQL predicate to a single concrete persistent ID. Even
        // modest `IN` lists of PersistentIdentifier can exercise a fragile
        // Core Data SQL-generator path, and their size grows with library
        // history when callers resolve every filtered row at once.
        for id in uniqueIDs {
            let model: Podcast? = existingModel(for: id)
            if let model {
                resolved[id] = model
            }
        }
        return resolved
    }

    func existingModels(for ids: [PersistentIdentifier]) -> [PersistentIdentifier: Episode] {
        let uniqueIDs = Array(Set(ids))
        guard uniqueIDs.isEmpty == false else { return [:] }
        var resolved: [PersistentIdentifier: Episode] = [:]
        for id in uniqueIDs {
            let model: Episode? = existingModel(for: id)
            if let model {
                resolved[id] = model
            }
        }
        return resolved
    }

    /// Resolve a visible episode page with one bounded SwiftData fetch. URL
    /// membership predicates are supported by the SQLite store and avoid the
    /// per-ID synchronous fetches required by `PersistentIdentifier` lookups.
    func episodes(forURLs urls: [URL]) -> [Episode] {
        let uniqueURLs = Array(Set(urls))
        guard uniqueURLs.isEmpty == false else { return [] }
        let optionalURLs = uniqueURLs.map(Optional.some)
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                optionalURLs.contains(episode.url)
            }
        )
        return (try? fetch(descriptor)) ?? []
    }
}
