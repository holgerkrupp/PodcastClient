import Foundation
import SwiftData

struct StoreSplitMigrationDiagnosticsSnapshot: Sendable {
    var legacySubscribedPodcastCount: Int
    var legacyEpisodeCount: Int
    var legacyEpisodesWithPlaybackProgressCount: Int
    var legacyPlaylistEntryCount: Int
    var legacyBookmarkCount: Int
    var legacyTranscriptLineCount: Int
    var legacyListeningSummaryCount: Int
    var lastMigrationAt: Date?
    var failedItemCount: Int
}

enum StoreSplitMigrationDiagnostics {
    private static let lastMigrationKey = "storeSplit.lastMigrationAt"
    private static let failedItemsKey = "storeSplit.failedItems"

    static func snapshot(using modelContext: ModelContext) -> StoreSplitMigrationDiagnosticsSnapshot {
        let subscribedPodcastDescriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.metaData?.isSubscribed != false }
        )
        let episodesDescriptor = FetchDescriptor<Episode>()
        let progressDescriptor = FetchDescriptor<EpisodeMetaData>(
            predicate: #Predicate<EpisodeMetaData> {
                ($0.playPosition ?? 0) > 0 || ($0.maxPlayposition ?? 0) > 0
            }
        )

        let legacySubscribedPodcastCount = (try? modelContext.fetchCount(subscribedPodcastDescriptor)) ?? 0
        let legacyEpisodeCount = (try? modelContext.fetchCount(episodesDescriptor)) ?? 0
        let legacyEpisodesWithPlaybackProgressCount = (try? modelContext.fetchCount(progressDescriptor)) ?? 0
        let legacyPlaylistEntryCount = (try? modelContext.fetchCount(FetchDescriptor<PlaylistEntry>())) ?? 0
        let legacyBookmarkCount = (try? modelContext.fetchCount(FetchDescriptor<Bookmark>())) ?? 0
        let legacyTranscriptLineCount = (try? modelContext.fetchCount(FetchDescriptor<TranscriptLineAndTime>())) ?? 0
        let legacyListeningSummaryCount = (try? modelContext.fetchCount(FetchDescriptor<ListeningSummarySync>())) ?? 0

        return StoreSplitMigrationDiagnosticsSnapshot(
            legacySubscribedPodcastCount: legacySubscribedPodcastCount,
            legacyEpisodeCount: legacyEpisodeCount,
            legacyEpisodesWithPlaybackProgressCount: legacyEpisodesWithPlaybackProgressCount,
            legacyPlaylistEntryCount: legacyPlaylistEntryCount,
            legacyBookmarkCount: legacyBookmarkCount,
            legacyTranscriptLineCount: legacyTranscriptLineCount,
            legacyListeningSummaryCount: legacyListeningSummaryCount,
            lastMigrationAt: UserDefaults.standard.object(forKey: lastMigrationKey) as? Date,
            failedItemCount: failedItems().count
        )
    }

    static func recordMigrationRun(at date: Date = .now) {
        UserDefaults.standard.set(date, forKey: lastMigrationKey)
    }

    static func recordFailedItems(_ items: [String]) {
        UserDefaults.standard.set(items, forKey: failedItemsKey)
    }

    static func failedItems() -> [String] {
        UserDefaults.standard.stringArray(forKey: failedItemsKey) ?? []
    }
}
