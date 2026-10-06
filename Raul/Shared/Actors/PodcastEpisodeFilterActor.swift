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
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.podcast?.persistentModelID == podcastID
            }
        )
        var episodes = try modelContext.fetch(descriptor)

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
