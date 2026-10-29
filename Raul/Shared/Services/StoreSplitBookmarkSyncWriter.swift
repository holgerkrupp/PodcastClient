import Foundation
import SwiftData

struct StoreSplitBookmarkSnapshot: Codable, Sendable {
    let id: String
    let identity: EpisodeStableIdentity
    let time: Double
    let title: String
    let createdAt: Date
}

enum StoreSplitBookmarkWriteError: Error {
    case missingBookmark
}

enum BookmarkSaveError: LocalizedError {
    case episodeUnavailable
    case localSaveFailed
    case portableRetryUnavailable
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .episodeUnavailable:
            String(localized: "No episode is available to bookmark.")
        case .localSaveFailed:
            String(localized: "The bookmark could not be saved. Check storage and try again.")
        case .portableRetryUnavailable:
            String(localized: "The bookmark was saved on this device but could not be queued for syncing. Check storage; do not add it again.")
        case .deleteFailed:
            String(localized: "The bookmark could not be removed. Check storage and try again.")
        }
    }
}

struct StoreSplitBookmarkWriterIO: Sendable {
    var fetch: @Sendable (ModelContext, String) throws -> BookmarkSync? = { context, id in
        var descriptor = FetchDescriptor<BookmarkSync>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
    var save: @Sendable (ModelContext) throws -> Void = { try $0.save() }
}

@ModelActor
actor StoreSplitBookmarkSyncWriter {
    func upsert(_ snapshot: StoreSplitBookmarkSnapshot, at date: Date = .now, io: StoreSplitBookmarkWriterIO = .init()) throws {
        do {
        let bookmarkID = snapshot.id
        let deviceID = ListeningDeviceIdentity.current().id
        if let bookmark = try io.fetch(modelContext, bookmarkID) {
            guard date > bookmark.updatedAt else { return }
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
        if modelContext.hasChanges { try io.save(modelContext) }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func tombstone(id: String, at date: Date = .now, io: StoreSplitBookmarkWriterIO = .init()) throws {
        do {
        let bookmarkID = id
        let deviceID = ListeningDeviceIdentity.current().id
        guard let bookmark = try io.fetch(modelContext, bookmarkID) else {
            // A delete without an existing sync row is ambiguous because the
            // logical episode key is unavailable. Creation writes the row first,
            // so record diagnostics rather than inventing a lossy identity.
            CrashBreadcrumbs.shared.record(
                "store_split_bookmark_tombstone_missing_source",
                details: id
            )
            throw StoreSplitBookmarkWriteError.missingBookmark
        }
        guard date >= bookmark.updatedAt else { return }
        bookmark.isDeleted = true
        bookmark.deletedAt = date
        bookmark.updatedAt = date
        bookmark.sourceDeviceID = deviceID
        if modelContext.hasChanges { try io.save(modelContext) }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func tombstone(_ snapshot: StoreSplitBookmarkSnapshot, at date: Date = .now, io: StoreSplitBookmarkWriterIO = .init()) throws {
        do {
        let bookmarkID = snapshot.id
        let deviceID = ListeningDeviceIdentity.current().id
        if let bookmark = try io.fetch(modelContext, bookmarkID) {
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
        if modelContext.hasChanges { try io.save(modelContext) }
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
