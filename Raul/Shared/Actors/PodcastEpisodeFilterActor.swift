import Foundation
import SwiftData
import os

enum PodcastDetailFetchSignposts {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "PodcastClient",
        category: .pointsOfInterest
    )

    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, id: OSSignpostID, count: Int = -1) {
        os_signpost(.end, log: log, name: name, signpostID: id, "count=%{public}d", count)
    }
}

enum PodcastEpisodeListSort: Sendable {
    case newestFirst
    case oldestFirst
    case titleAZ
    case titleZA
}

struct PodcastEpisodeFilterRequest: Sendable {
    let query: String
    let searchInTitle: Bool
    let searchInAuthor: Bool
    let searchInDescription: Bool
    let searchInTranscript: Bool
    let hidePlayedAndArchived: Bool
    let sort: PodcastEpisodeListSort
}

@ModelActor
actor PodcastEpisodeFilterActor {
    func episodeIDs(
        podcastID: PersistentIdentifier,
        request: PodcastEpisodeFilterRequest
    ) throws -> [PersistentIdentifier] {
        // Resolve the parent in this actor's context. Keep the relationship's
        // PersistentIdentifier comparison out of Core Data's SQL generator.
        let parentFetchID = PodcastDetailFetchSignposts.begin("Podcast detail parent lookup")
        var podcastDescriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.persistentModelID == podcastID }
        )
        podcastDescriptor.fetchLimit = 1
        var parentCount = -1
        defer {
            PodcastDetailFetchSignposts.end(
                "Podcast detail parent lookup",
                id: parentFetchID,
                count: parentCount
            )
        }
        let podcast = try modelContext.fetch(podcastDescriptor).first
        parentCount = podcast == nil ? 0 : 1
        guard let podcast else { return [] }
        let episodesForFeed: [Episode]
        let episodeFetchID = PodcastDetailFetchSignposts.begin("Podcast detail episode feed fetch")
        var episodeCount = -1
        defer {
            PodcastDetailFetchSignposts.end(
                "Podcast detail episode feed fetch",
                id: episodeFetchID,
                count: episodeCount
            )
        }
        if let feed = podcast.feed {
            let descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.podcast?.feed == feed }
            )
            episodesForFeed = try modelContext.fetch(descriptor)
        } else {
            let descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.podcast != nil }
            )
            episodesForFeed = try modelContext.fetch(descriptor)
        }
        episodeCount = episodesForFeed.count
        var episodes = episodesForFeed.filter {
            $0.podcast?.persistentModelID == podcastID
        }

        if request.hidePlayedAndArchived {
            episodes.removeAll { $0.maxPlayProgress >= 0.95 }
        }

        if request.query.isEmpty == false {
            episodes.removeAll { episode in
                if request.searchInTitle,
                   episode.title.localizedStandardContains(request.query) {
                    return false
                }
                if request.searchInAuthor,
                   episode.author?.localizedStandardContains(request.query) == true {
                    return false
                }
                if request.searchInDescription,
                   episode.desc?.localizedStandardContains(request.query) == true {
                    return false
                }
                if request.searchInTranscript,
                   transcriptContains(
                    request.query,
                    forEpisodeID: episode.persistentModelID
                   ) {
                    return false
                }
                return true
            }
        }

        switch request.sort {
        case .newestFirst:
            episodes.sort {
                ($0.publishDate ?? .distantPast) > ($1.publishDate ?? .distantPast)
            }
        case .oldestFirst:
            episodes.sort {
                ($0.publishDate ?? .distantFuture) < ($1.publishDate ?? .distantFuture)
            }
        case .titleAZ:
            episodes.sort {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .titleZA:
            episodes.sort {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending
            }
        }

        return episodes.map(\.persistentModelID)
    }

    /// Queries transcript rows directly rather than faulting
    /// `episode.transcriptLines`, which can be replaced while transcription or
    /// an import is running in another model context.
    private func transcriptContains(
        _ query: String,
        forEpisodeID episodeID: PersistentIdentifier
    ) -> Bool {
        var descriptor = FetchDescriptor<TranscriptLineAndTime>(
            predicate: #Predicate { line in
                line.episode?.persistentModelID == episodeID
                    && line.text.localizedStandardContains(query)
            }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor).isEmpty == false) ?? false
    }
}
