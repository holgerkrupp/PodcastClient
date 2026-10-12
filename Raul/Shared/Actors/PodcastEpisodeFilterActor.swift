import Foundation
import SwiftData

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
        let started = Date()
        CrashBreadcrumbs.shared.record("podcast_detail_fetch_begin", details: "model=Episode predicate=parent_feed")
        defer {
            CrashBreadcrumbs.shared.record(
                "podcast_detail_fetch_end",
                details: "model=Episode elapsed_ms=\(Int(Date().timeIntervalSince(started) * 1_000))"
            )
        }
        // Resolve the parent in this actor's context and keep the relationship's
        // persistentModelID comparison out of Core Data's SQL generator.
        var podcastDescriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.persistentModelID == podcastID }
        )
        podcastDescriptor.fetchLimit = 1
        guard let podcast = try modelContext.fetch(podcastDescriptor).first else { return [] }
        let episodesForFeed: [Episode]
        if let feed = podcast.feed {
            let descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.podcast?.feed == feed }
            )
            episodesForFeed = try modelContext.fetch(descriptor)
        } else {
            // Feedless legacy rows are rare. Narrow them by their parent in
            // memory instead of asking SQL to compare a relationship's ID.
            let descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.podcast != nil }
            )
            episodesForFeed = try modelContext.fetch(descriptor)
        }
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
