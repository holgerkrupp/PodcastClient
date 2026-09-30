import Foundation
import SwiftData

struct EpisodeListQueryResult: Sendable {
    let episodeIDs: [PersistentIdentifier]
    let hasMore: Bool
}

enum EpisodeListQuerySort: Sendable {
    case newestFirst
    case titleAZ
}

@ModelActor
actor EpisodeListQueryActor {
    func allEpisodes(
        searchText: String,
        limit: Int,
        recentlyPlayedOnly: Bool
    ) throws -> EpisodeListQueryResult {
        if recentlyPlayedOnly {
            let predicate: Predicate<EpisodeMetaData>
            if searchText.isEmpty {
                predicate = #Predicate<EpisodeMetaData> { metadata in
                    metadata.lastPlayed != nil
                }
            } else {
                predicate = #Predicate<EpisodeMetaData> { metadata in
                    metadata.lastPlayed != nil
                        && metadata.episode?.title.localizedStandardContains(searchText) == true
                }
            }

            var descriptor = FetchDescriptor<EpisodeMetaData>(
                predicate: predicate,
                sortBy: [SortDescriptor(\EpisodeMetaData.lastPlayed, order: .reverse)]
            )
            descriptor.fetchLimit = limit + 1
            let rows = try modelContext.fetch(descriptor)
            let episodeIDs = rows.prefix(limit).compactMap {
                $0.episode?.persistentModelID
            }
            return EpisodeListQueryResult(
                episodeIDs: episodeIDs,
                hasMore: rows.count > limit
            )
        }

        let predicate: Predicate<Episode>?
        if searchText.isEmpty {
            predicate = nil
        } else {
            predicate = #Predicate<Episode> { episode in
                episode.title.localizedStandardContains(searchText)
            }
        }

        var descriptor = FetchDescriptor<Episode>(
            predicate: predicate,
            sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = limit + 1
        let rows = try modelContext.fetch(descriptor)
        let episodeIDs = rows.prefix(limit).map(\.persistentModelID)
        return EpisodeListQueryResult(
            episodeIDs: episodeIDs,
            hasMore: rows.count > limit
        )
    }

    func inboxEpisodeIDs() throws -> [PersistentIdentifier] {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.metaData?.isInbox == true
            },
            sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(\.persistentModelID)
    }

    func downloadedEpisodeIDs(
        downloadedFiles: Set<URL>,
        sort: EpisodeListQuerySort
    ) throws -> [PersistentIdentifier] {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.metaData?.isAvailableLocally == true
            }
        )
        var episodes = try modelContext.fetch(descriptor).filter { episode in
            guard let localFile = episode.localFile?.standardizedFileURL else {
                return false
            }
            return downloadedFiles.contains(localFile)
        }

        switch sort {
        case .newestFirst:
            episodes.sort {
                ($0.publishDate ?? .distantPast) > ($1.publishDate ?? .distantPast)
            }
        case .titleAZ:
            episodes.sort {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }

        return episodes.map(\.persistentModelID)
    }
}
