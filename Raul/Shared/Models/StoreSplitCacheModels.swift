import Foundation
import SwiftData

@Model
final class StoreSplitMigrationCheckpoint: Identifiable {
    var id: String = ""
    var migrationVersion: Int = 0
    var phase: String = ""
    var cursor: String?
    var startedAt: Date?
    var completedAt: Date?
    var scannedCount: Int = 0
    var insertedCount: Int = 0
    var updatedCount: Int = 0
    var skippedCount: Int = 0
    var failedCount: Int = 0
    var failedItemKeys: [String] = []
    var lastError: String?
    var updatedAt: Date = Date.distantPast

    init(
        id: String,
        migrationVersion: Int,
        phase: String,
        cursor: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        scannedCount: Int = 0,
        insertedCount: Int = 0,
        updatedCount: Int = 0,
        skippedCount: Int = 0,
        failedCount: Int = 0,
        failedItemKeys: [String] = [],
        lastError: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.migrationVersion = migrationVersion
        self.phase = phase
        self.cursor = cursor
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.scannedCount = scannedCount
        self.insertedCount = insertedCount
        self.updatedCount = updatedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.failedItemKeys = failedItemKeys
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

@Model
final class CachedFeedExtensionElement: Identifiable {
    var id: String = ""
    var feedURL: String = ""
    var episodeID: String?
    var scope: String = ""
    var namespaceURI: String = ""
    var qualifiedName: String = ""
    var localName: String = ""
    var payload: Data = Data()
    var ordinal: Int = 0
    var contentHash: String = ""
    var updatedAt: Date = Date.distantPast

    init(
        feedURL: String,
        episodeID: String? = nil,
        scope: String,
        namespaceURI: String,
        qualifiedName: String,
        localName: String,
        payload: Data,
        ordinal: Int,
        contentHash: String,
        updatedAt: Date = .now
    ) {
        self.id = StableIdentityKey.make(
            feedURL,
            episodeID ?? "__feed__",
            namespaceURI,
            qualifiedName,
            String(ordinal)
        )
        self.feedURL = feedURL
        self.episodeID = episodeID
        self.scope = scope
        self.namespaceURI = namespaceURI
        self.qualifiedName = qualifiedName
        self.localName = localName
        self.payload = payload
        self.ordinal = ordinal
        self.contentHash = contentHash
        self.updatedAt = updatedAt
    }
}

@Model
final class AppliedAIContentRevision: Identifiable {
    var id: String = ""
    var transcriptRevisionID: String?
    var chapterRevisionID: String?
    var updatedAt: Date = Date.distantPast

    init(
        episodeIdentityKey: String,
        transcriptRevisionID: String? = nil,
        chapterRevisionID: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = episodeIdentityKey
        self.transcriptRevisionID = transcriptRevisionID
        self.chapterRevisionID = chapterRevisionID
        self.updatedAt = updatedAt
    }
}
