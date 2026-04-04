import Foundation
import SwiftData

struct CloudSyncExpectedSnapshot: Codable {
    var deviceName: String
    var updatedAt: Date

    var podcasts: Int
    var episodes: Int
    var upNextEntries: Int
    var inboxEpisodes: Int
    var chapters: Int
    var bookmarks: Int
    var transcriptLines: Int
    var transcriptionRecords: Int
    var playSessions: Int
    var playSessionSummaries: Int
}

enum CloudSyncExpectationStore {
    static let libraryPresenceKey = "hasLibraryDataEver"
    private static let snapshotKeyLegacy = "cloudSync.expectedSnapshot.v1"
    private static let keyDeviceName = "cloudSync.expected.deviceName"
    private static let keyUpdatedAt = "cloudSync.expected.updatedAt"
    private static let keyPodcasts = "cloudSync.expected.podcasts"
    private static let keyEpisodes = "cloudSync.expected.episodes"
    private static let keyUpNextEntries = "cloudSync.expected.upNextEntries"
    private static let keyInboxEpisodes = "cloudSync.expected.inboxEpisodes"
    private static let keyChapters = "cloudSync.expected.chapters"
    private static let keyBookmarks = "cloudSync.expected.bookmarks"
    private static let keyTranscriptLines = "cloudSync.expected.transcriptLines"
    private static let keyTranscriptionRecords = "cloudSync.expected.transcriptionRecords"
    private static let keyPlaySessions = "cloudSync.expected.playSessions"
    private static let keyPlaySessionSummaries = "cloudSync.expected.playSessionSummaries"
    private static let queuePlaylistTitle = "de.holgerkrupp.podbay.queue"

    static func publishExpectedSnapshot(using context: ModelContext) {
        let snapshot = makeSnapshot(using: context)
        let total = snapshot.podcasts
            + snapshot.episodes
            + snapshot.upNextEntries
            + snapshot.inboxEpisodes
            + snapshot.chapters
            + snapshot.bookmarks
            + snapshot.transcriptLines
            + snapshot.transcriptionRecords
            + snapshot.playSessions
            + snapshot.playSessionSummaries

        // Never overwrite a healthy remote expectation with an empty local database snapshot.
        guard total > 0 else { return }

        let kvs = NSUbiquitousKeyValueStore.default
        kvs.set(snapshot.deviceName, forKey: keyDeviceName)
        kvs.set(snapshot.updatedAt.timeIntervalSince1970, forKey: keyUpdatedAt)
        kvs.set(snapshot.podcasts, forKey: keyPodcasts)
        kvs.set(snapshot.episodes, forKey: keyEpisodes)
        kvs.set(snapshot.upNextEntries, forKey: keyUpNextEntries)
        kvs.set(snapshot.inboxEpisodes, forKey: keyInboxEpisodes)
        kvs.set(snapshot.chapters, forKey: keyChapters)
        kvs.set(snapshot.bookmarks, forKey: keyBookmarks)
        kvs.set(snapshot.transcriptLines, forKey: keyTranscriptLines)
        kvs.set(snapshot.transcriptionRecords, forKey: keyTranscriptionRecords)
        kvs.set(snapshot.playSessions, forKey: keyPlaySessions)
        kvs.set(snapshot.playSessionSummaries, forKey: keyPlaySessionSummaries)
        kvs.set(true, forKey: libraryPresenceKey)
        kvs.synchronize()
    }

    static func loadExpectedSnapshot() -> CloudSyncExpectedSnapshot? {
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.synchronize()

        let updatedAtTimestamp = kvs.double(forKey: keyUpdatedAt)
        if updatedAtTimestamp > 0 {
            let snapshot = CloudSyncExpectedSnapshot(
                deviceName: kvs.string(forKey: keyDeviceName) ?? "Unknown Device",
                updatedAt: Date(timeIntervalSince1970: updatedAtTimestamp),
                podcasts: Int(kvs.longLong(forKey: keyPodcasts)),
                episodes: Int(kvs.longLong(forKey: keyEpisodes)),
                upNextEntries: Int(kvs.longLong(forKey: keyUpNextEntries)),
                inboxEpisodes: Int(kvs.longLong(forKey: keyInboxEpisodes)),
                chapters: Int(kvs.longLong(forKey: keyChapters)),
                bookmarks: Int(kvs.longLong(forKey: keyBookmarks)),
                transcriptLines: Int(kvs.longLong(forKey: keyTranscriptLines)),
                transcriptionRecords: Int(kvs.longLong(forKey: keyTranscriptionRecords)),
                playSessions: Int(kvs.longLong(forKey: keyPlaySessions)),
                playSessionSummaries: Int(kvs.longLong(forKey: keyPlaySessionSummaries))
            )
            return snapshot
        }

        // Backward compatibility with previous JSON blob storage.
        guard let data = kvs.data(forKey: snapshotKeyLegacy) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CloudSyncExpectedSnapshot.self, from: data)
    }

    static func hasExpectedRemoteData() -> Bool {
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.synchronize()
        return kvs.bool(forKey: libraryPresenceKey)
            || kvs.double(forKey: keyUpdatedAt) > 0
            || kvs.data(forKey: snapshotKeyLegacy) != nil
    }

    static func makeSnapshot(using context: ModelContext) -> CloudSyncExpectedSnapshot {
        CloudSyncExpectedSnapshot(
            deviceName: ProcessInfo.processInfo.hostName,
            updatedAt: Date(),
            podcasts: countPodcasts(context),
            episodes: countEpisodes(context),
            upNextEntries: countUpNextEntries(context),
            inboxEpisodes: countInboxEpisodes(context),
            chapters: countChapters(context),
            bookmarks: countBookmarks(context),
            transcriptLines: countTranscriptLines(context),
            transcriptionRecords: countTranscriptionRecords(context),
            playSessions: countPlaySessions(context),
            playSessionSummaries: countPlaySessionSummaries(context)
        )
    }

    private static func countPodcasts(_ context: ModelContext) -> Int {
        do {
            var descriptor = FetchDescriptor<Podcast>()
            descriptor.propertiesToFetch = [\.title]
            return try context.fetch(descriptor).count
        } catch {
            return 0
        }
    }

    private static func countEpisodes(_ context: ModelContext) -> Int {
        do {
            var descriptor = FetchDescriptor<Episode>()
            descriptor.propertiesToFetch = [\.title]
            return try context.fetch(descriptor).count
        } catch {
            return 0
        }
    }

    private static func countUpNextEntries(_ context: ModelContext) -> Int {
        do {
            var descriptor = FetchDescriptor<PlaylistEntry>(
                predicate: #Predicate<PlaylistEntry> { $0.playlist?.title == queuePlaylistTitle }
            )
            descriptor.propertiesToFetch = [\.id]
            return try context.fetch(descriptor).count
        } catch {
            return 0
        }
    }

    private static func countInboxEpisodes(_ context: ModelContext) -> Int {
        do {
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.metaData?.isInbox == true }
            )
            descriptor.propertiesToFetch = [\.title]
            return try context.fetch(descriptor).count
        } catch {
            return 0
        }
    }

    private static func countChapters(_ context: ModelContext) -> Int {
        do {
            var descriptor = FetchDescriptor<Marker>()
            descriptor.propertiesToFetch = [\.title]
            let markerCount = try context.fetch(descriptor).count
            let bookmarkCount = countBookmarks(context)
            return max(0, markerCount - bookmarkCount)
        } catch {
            return 0
        }
    }

    private static func countBookmarks(_ context: ModelContext) -> Int {
        do {
            var descriptor = FetchDescriptor<Bookmark>()
            descriptor.propertiesToFetch = [\.title]
            return try context.fetch(descriptor).count
        } catch {
            return 0
        }
    }

    private static func countTranscriptLines(_ context: ModelContext) -> Int {
        do {
            var descriptor = FetchDescriptor<TranscriptLineAndTime>()
            descriptor.propertiesToFetch = [\.text]
            return try context.fetch(descriptor).count
        } catch {
            return 0
        }
    }

    private static func countTranscriptionRecords(_ context: ModelContext) -> Int {
        do {
            var descriptor = FetchDescriptor<TranscriptionRecord>()
            descriptor.propertiesToFetch = [\.episodeTitle]
            return try context.fetch(descriptor).count
        } catch {
            return 0
        }
    }

    private static func countPlaySessions(_ context: ModelContext) -> Int {
        do {
            var descriptor = FetchDescriptor<PlaySession>()
            descriptor.propertiesToFetch = [\.id]
            return try context.fetch(descriptor).count
        } catch {
            return 0
        }
    }

    private static func countPlaySessionSummaries(_ context: ModelContext) -> Int {
        do {
            var descriptor = FetchDescriptor<PlaySessionSummary>()
            descriptor.propertiesToFetch = [\.id]
            return try context.fetch(descriptor).count
        } catch {
            return 0
        }
    }
}
