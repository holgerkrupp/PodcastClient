import Foundation
import SwiftData

struct StoreSplitBookmarkSnapshot: Sendable {
    let id: String
    let identity: EpisodeStableIdentity
    let time: Double
    let title: String
    let createdAt: Date
}

@ModelActor
actor StoreSplitBookmarkSyncWriter {
    func upsert(_ snapshot: StoreSplitBookmarkSnapshot, at date: Date = .now) {
        let bookmarkID = snapshot.id
        let descriptor = FetchDescriptor<BookmarkSync>(
            predicate: #Predicate<BookmarkSync> { $0.id == bookmarkID }
        )
        let deviceID = ListeningDeviceIdentity.current().id
        if let bookmark = try? modelContext.fetch(descriptor).first {
            bookmark.feedURL = snapshot.identity.feedURL
            bookmark.episodeID = snapshot.identity.episodeID
            bookmark.time = snapshot.time
            bookmark.title = snapshot.title
            bookmark.createdAt = snapshot.createdAt
            bookmark.isDeleted = false
            bookmark.deletedAt = nil
            bookmark.updatedAt = date
            bookmark.sourceDeviceID = deviceID
        } else {
            modelContext.insert(
                BookmarkSync(
                    id: snapshot.id,
                    feedURL: snapshot.identity.feedURL,
                    episodeID: snapshot.identity.episodeID,
                    time: snapshot.time,
                    title: snapshot.title,
                    createdAt: snapshot.createdAt,
                    updatedAt: date,
                    sourceDeviceID: deviceID
                )
            )
        }
        modelContext.saveIfNeeded()
    }

    func tombstone(id: String, at date: Date = .now) {
        let bookmarkID = id
        let descriptor = FetchDescriptor<BookmarkSync>(
            predicate: #Predicate<BookmarkSync> { $0.id == bookmarkID }
        )
        let deviceID = ListeningDeviceIdentity.current().id
        guard let bookmark = try? modelContext.fetch(descriptor).first else {
            // A delete without an existing sync row is ambiguous because the
            // logical episode key is unavailable. Creation writes the row first,
            // so record diagnostics rather than inventing a lossy identity.
            CrashBreadcrumbs.shared.record(
                "store_split_bookmark_tombstone_missing_source",
                details: id
            )
            return
        }
        guard date >= bookmark.updatedAt else { return }
        bookmark.isDeleted = true
        bookmark.deletedAt = date
        bookmark.updatedAt = date
        bookmark.sourceDeviceID = deviceID
        modelContext.saveIfNeeded()
    }

    func tombstone(_ snapshot: StoreSplitBookmarkSnapshot, at date: Date = .now) {
        let bookmarkID = snapshot.id
        let descriptor = FetchDescriptor<BookmarkSync>(
            predicate: #Predicate<BookmarkSync> { $0.id == bookmarkID }
        )
        let deviceID = ListeningDeviceIdentity.current().id
        if let bookmark = try? modelContext.fetch(descriptor).first {
            guard date >= bookmark.updatedAt else { return }
            bookmark.isDeleted = true
            bookmark.deletedAt = date
            bookmark.updatedAt = date
            bookmark.sourceDeviceID = deviceID
        } else {
            let bookmark = BookmarkSync(
                id: snapshot.id,
                feedURL: snapshot.identity.feedURL,
                episodeID: snapshot.identity.episodeID,
                time: snapshot.time,
                title: snapshot.title,
                createdAt: snapshot.createdAt,
                isDeleted: true,
                deletedAt: date,
                updatedAt: date,
                sourceDeviceID: deviceID
            )
            modelContext.insert(bookmark)
            // Assign tombstone fields after insertion as well. This avoids a
            // SwiftData default-value materialization edge case seen when a new
            // CloudKit-compatible model is inserted and saved in one turn.
            bookmark.isDeleted = true
            bookmark.deletedAt = date
            bookmark.updatedAt = date
        }
        modelContext.saveIfNeeded()
    }
}
