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

    /// Resolve episodes whose enclosure URL is one of `urls`, in this context.
    ///
    /// Each unique URL is resolved with its own scalar-equality predicate
    /// (`episode.url == url`) instead of the former optional-array membership
    /// predicate (`optionalURLs.contains(episode.url)`), which remained a
    /// candidate in the build-560 SwiftData assertion (#348). Duplicate input
    /// URLs are queried once; every episode sharing a URL is returned. Fetch
    /// failures propagate so callers cannot mistake a failed read for
    /// "no episodes". Intended for bounded inputs such as one UI page.
    func episodes(forURLs urls: [URL]) throws -> [Episode] {
        var seen = Set<URL>()
        let uniqueURLs = urls.filter { seen.insert($0).inserted }
        guard uniqueURLs.isEmpty == false else { return [] }
        var result: [Episode] = []
        var resultIDs = Set<PersistentIdentifier>()
        for url in uniqueURLs {
            let descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { episode in
                    episode.url == url
                }
            )
            for episode in try fetch(descriptor)
            where resultIDs.insert(episode.persistentModelID).inserted {
                result.append(episode)
            }
        }
        return result
    }

    /// Resolve one UI page in the filter actor's original order.
    ///
    /// The page's persistent IDs are already in hand, so every row is resolved
    /// by its own primary-key predicate (at most one page, 80 rows) instead of
    /// a URL or ID membership list. This keeps duplicate-URL siblings from
    /// substituting for one another, skips rows deleted between filtering and
    /// resolution, and propagates fetch errors. `urls` is kept for source
    /// compatibility and breadcrumb counts; it no longer drives the query.
    func episodes(
        forPageIDs ids: [PersistentIdentifier],
        urls: [URL?]
    ) throws -> [Episode] {
        precondition(ids.count == urls.count)
        guard ids.isEmpty == false else { return [] }
        let operationID = UUID().uuidString
        let startedAt = ContinuousClock.now
        CrashBreadcrumbs.shared.record(
            "podcast_detail_visible_page_started",
            details: "operation=\(operationID) predicate=episode_page_primary_key requested=\(ids.count) nil_urls=\(urls.count { $0 == nil })"
        )
        defer {
            let elapsed = startedAt.duration(to: .now).components
            let elapsedMilliseconds = elapsed.seconds * 1_000
                + elapsed.attoseconds / 1_000_000_000_000_000
            CrashBreadcrumbs.shared.record(
                "podcast_detail_visible_page_finished",
                details: "operation=\(operationID) predicate=episode_page_primary_key elapsed_ms=\(elapsedMilliseconds)"
            )
        }

        var byID: [PersistentIdentifier: Episode] = [:]
        for id in ids where byID[id] == nil {
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.persistentModelID == id }
            )
            descriptor.fetchLimit = 1
            if let episode = try fetch(descriptor).first {
                byID[id] = episode
            }
        }
        return ids.compactMap { byID[$0] }
    }
}
