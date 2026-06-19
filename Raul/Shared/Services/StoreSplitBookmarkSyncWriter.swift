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
}
