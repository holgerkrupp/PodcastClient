import Foundation
import SwiftData

struct LibrarySearchRequest: Sendable {
    enum Scope: Sendable {
        case subscribed
        case unsubscribed
        case all
    }

    let query: String
    let scope: Scope
    let searchInTitle: Bool
    let searchInAuthor: Bool
    let searchInDescription: Bool
    let searchInEpisodes: Bool
    let minimumCharactersForTranscriptSearch: Int
}

@ModelActor
actor LibrarySearchActor {
    func search(request: LibrarySearchRequest) throws -> [PodcastSearchResultGroup] {
        let scopeFilter = try buildScopeFilter(scope: request.scope)
        let podcasts = try fetchPodcastResults(request: request, scopeFilter: scopeFilter)
        try Task.checkCancellation()
        let episodes = try fetchEpisodeResults(request: request, scopeFilter: scopeFilter)
        try Task.checkCancellation()
        return group(podcasts: podcasts, episodes: episodes)
    }

    private func fetchPodcastResults(
        request: LibrarySearchRequest,
        scopeFilter: SearchScopeFilter
    ) throws -> [PodcastSearchResult] {
        var matchesByID: [String: PodcastSearchResult] = [:]

        func insertUnique(_ podcasts: [Podcast]) {
            for podcastModel in podcasts {
                let podcastID = podcastModel.persistentModelID
                let key = "\(podcastID)"
                guard scopeFilter.includesPodcast(id: key) else { continue }
                guard matchesByID[key] == nil else { continue }
                guard let podcast = scopeFilter.podcastSummary(forPodcastID: key) else { continue }
                matchesByID[key] = PodcastSearchResult(
                    podcast: podcast,
                    title: podcast.title,
                    author: podcast.author,
                    snippet: podcast.desc.map { snippet(from: $0, query: request.query) }
                )
            }
        }

        if request.searchInTitle {
            var descriptor = FetchDescriptor<Podcast>(
                predicate: podcastTitlePredicate(query: request.query),
                sortBy: [SortDescriptor(\Podcast.title)]
            )
            descriptor.fetchLimit = 300
            insertUnique(try modelContext.fetch(descriptor))
        }

        if request.searchInAuthor {
            var descriptor = FetchDescriptor<Podcast>(
                predicate: podcastAuthorPredicate(query: request.query),
                sortBy: [SortDescriptor(\Podcast.title)]
            )
            descriptor.fetchLimit = 300
            insertUnique(try modelContext.fetch(descriptor))
        }

        if request.searchInDescription {
            var descriptor = FetchDescriptor<Podcast>(
                predicate: podcastDescriptionPredicate(query: request.query),
                sortBy: [SortDescriptor(\Podcast.title)]
            )
            descriptor.fetchLimit = 300
            insertUnique(try modelContext.fetch(descriptor))
        }

        return matchesByID.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func fetchEpisodeResults(
        request: LibrarySearchRequest,
        scopeFilter: SearchScopeFilter
    ) throws -> [EpisodeSearchResult] {
        guard request.searchInEpisodes else { return [] }

        var matchesByEpisodeID: [String: EpisodeSearchResult] = [:]

        func insertIfNeeded(episode: Episode, kind: EpisodeSearchResult.MatchKind, snippet: String) {
            let episodeID = episode.persistentModelID
            let key = "\(episodeID)"
            guard scopeFilter.includesEpisode(id: key) else { return }
            guard matchesByEpisodeID[key] == nil else { return }
            guard let podcastID = scopeFilter.podcastID(forEpisodeID: key) else { return }
            guard let podcast = scopeFilter.podcastSummary(forPodcastID: podcastID) else { return }
            matchesByEpisodeID[key] = EpisodeSearchResult(
                podcast: podcast,
                episodeID: episodeID,
                episodeTitle: episode.title,
                publishDate: episode.publishDate,
                episodeURL: episode.url,
                episodeImageURL: episode.imageURL,
                kind: kind,
                snippet: snippet
            )
        }

        if request.searchInTitle {
            var descriptor = FetchDescriptor<Episode>(
                predicate: episodeTitlePredicate(query: request.query),
                sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
            )
            descriptor.fetchLimit = 500
            for episode in try modelContext.fetch(descriptor) {
                insertIfNeeded(
                    episode: episode,
                    kind: .title,
                    snippet: snippet(from: episode.title, query: request.query)
                )
            }
        }

        if request.searchInAuthor {
            var descriptor = FetchDescriptor<Episode>(
                predicate: episodeAuthorPredicate(query: request.query),
                sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
            )
            descriptor.fetchLimit = 500
            for episode in try modelContext.fetch(descriptor) {
                insertIfNeeded(
                    episode: episode,
                    kind: .author,
                    snippet: snippet(from: episode.author ?? "", query: request.query)
                )
            }
        }

        if request.searchInDescription {
            var descriptionDescriptor = FetchDescriptor<Episode>(
                predicate: episodeDescPredicate(query: request.query),
                sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
            )
            descriptionDescriptor.fetchLimit = 500
            for episode in try modelContext.fetch(descriptionDescriptor) {
                if let desc = episode.desc,
                   containsIgnoringCaseAndDiacritics(desc, query: request.query) {
                    insertIfNeeded(
                        episode: episode,
                        kind: .showNotes,
                        snippet: snippet(from: desc, query: request.query)
                    )
                }
            }

            var subtitleDescriptor = FetchDescriptor<Episode>(
                predicate: episodeSubtitlePredicate(query: request.query),
                sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
            )
            subtitleDescriptor.fetchLimit = 500
            for episode in try modelContext.fetch(subtitleDescriptor) {
                if let subtitle = episode.subtitle,
                   containsIgnoringCaseAndDiacritics(subtitle, query: request.query) {
                    insertIfNeeded(
                        episode: episode,
                        kind: .showNotes,
                        snippet: snippet(from: subtitle, query: request.query)
                    )
                }
            }

            var contentDescriptor = FetchDescriptor<Episode>(
                predicate: episodeContentPredicate(query: request.query),
                sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
            )
            contentDescriptor.fetchLimit = 500
            for episode in try modelContext.fetch(contentDescriptor) {
                if let content = episode.content,
                   containsIgnoringCaseAndDiacritics(content, query: request.query) {
                    insertIfNeeded(
                        episode: episode,
                        kind: .showNotes,
                        snippet: snippet(from: content, query: request.query)
                    )
                }
            }
        }

        var chapterDescriptor = FetchDescriptor<Marker>(
            predicate: chapterTitlePredicate(query: request.query)
        )
        chapterDescriptor.fetchLimit = 600
        for chapter in try modelContext.fetch(chapterDescriptor) {
            guard let episode = chapter.episode else { continue }
            insertIfNeeded(
                episode: episode,
                kind: .chapter(startTime: chapter.start ?? 0),
                snippet: snippet(from: chapter.title, query: request.query)
            )
        }

        if request.query.count >= request.minimumCharactersForTranscriptSearch {
            var transcriptDescriptor = FetchDescriptor<TranscriptLineAndTime>(
                predicate: transcriptLinePredicate(query: request.query),
                sortBy: [SortDescriptor(\TranscriptLineAndTime.startTime)]
            )
            transcriptDescriptor.fetchLimit = 1_500
            for line in try modelContext.fetch(transcriptDescriptor) {
                guard let episode = line.episode else { continue }
                insertIfNeeded(
                    episode: episode,
                    kind: .transcript(startTime: line.startTime),
                    snippet: snippet(from: line.text, query: request.query, maxLength: 180)
                )
            }
        }

        return matchesByEpisodeID.values.sorted { lhs, rhs in
            let leftDate = lhs.publishDate ?? .distantPast
            let rightDate = rhs.publishDate ?? .distantPast
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return lhs.episodeTitle.localizedCaseInsensitiveCompare(rhs.episodeTitle) == .orderedAscending
        }
    }

    private func buildScopeFilter(scope: LibrarySearchRequest.Scope) throws -> SearchScopeFilter {
        let descriptor: FetchDescriptor<Podcast> = switch scope {
        case .all:
            FetchDescriptor<Podcast>()
        case .subscribed:
            FetchDescriptor<Podcast>(
                predicate: #Predicate<Podcast> { podcast in
                    podcast.metaData?.isSubscribed != false
                }
            )
        case .unsubscribed:
            FetchDescriptor<Podcast>(
                predicate: #Predicate<Podcast> { podcast in
                    podcast.metaData?.isSubscribed == false
                }
            )
        }

        let scopedPodcasts = try modelContext.fetch(descriptor)
        var podcastIDs = Set<String>()
        var episodeIDs = Set<String>()
        var podcastSummaries: [String: PodcastGroupSummary] = [:]
        var episodeToPodcastID: [String: String] = [:]

        for podcast in scopedPodcasts {
            let podcastID = podcast.persistentModelID
            let podcastKey = "\(podcastID)"
            podcastIDs.insert(podcastKey)
            podcastSummaries[podcastKey] = PodcastGroupSummary(
                podcastID: podcastID,
                title: podcast.title,
                author: podcast.author,
                desc: podcast.desc,
                imageURL: podcast.imageURL
            )
            for episode in podcast.episodes ?? [] {
                let episodeKey = "\(episode.persistentModelID)"
                episodeIDs.insert(episodeKey)
                episodeToPodcastID[episodeKey] = podcastKey
            }
        }

        return SearchScopeFilter(
            podcastIDs: podcastIDs,
            episodeIDs: episodeIDs,
            podcastsByID: podcastSummaries,
            episodeToPodcastID: episodeToPodcastID
        )
    }

    private func group(
        podcasts: [PodcastSearchResult],
        episodes: [EpisodeSearchResult]
    ) -> [PodcastSearchResultGroup] {
        var groupedItems: [String: [GroupedSearchItem]] = [:]
        var groupedPodcast: [String: PodcastGroupSummary] = [:]

        for result in podcasts {
            groupedItems[result.podcastKey, default: []].append(.podcast(result))
            groupedPodcast[result.podcastKey] = result.podcast
        }
        for result in episodes {
            groupedItems[result.podcastKey, default: []].append(.episode(result))
            groupedPodcast[result.podcastKey] = result.podcast
        }

        return groupedItems.compactMap { key, items in
            guard let podcast = groupedPodcast[key] else { return nil }
            return PodcastSearchResultGroup(
                podcast: podcast,
                items: items.sorted(by: GroupedSearchItem.sortOrder)
            )
        }
        .sorted {
            $0.podcast.title.localizedCaseInsensitiveCompare($1.podcast.title) == .orderedAscending
        }
    }

    private func podcastTitlePredicate(query: String) -> Predicate<Podcast> {
        #Predicate<Podcast> { $0.title.localizedStandardContains(query) }
    }

    private func podcastAuthorPredicate(query: String) -> Predicate<Podcast> {
        #Predicate<Podcast> { $0.author?.localizedStandardContains(query) == true }
    }

    private func podcastDescriptionPredicate(query: String) -> Predicate<Podcast> {
        #Predicate<Podcast> { $0.desc?.localizedStandardContains(query) == true }
    }

    private func episodeTitlePredicate(query: String) -> Predicate<Episode> {
        #Predicate<Episode> { $0.title.localizedStandardContains(query) }
    }

    private func episodeAuthorPredicate(query: String) -> Predicate<Episode> {
        #Predicate<Episode> { $0.author?.localizedStandardContains(query) == true }
    }

    private func episodeDescPredicate(query: String) -> Predicate<Episode> {
        #Predicate<Episode> { $0.desc?.localizedStandardContains(query) == true }
    }

    private func episodeSubtitlePredicate(query: String) -> Predicate<Episode> {
        #Predicate<Episode> { $0.subtitle?.localizedStandardContains(query) == true }
    }

    private func episodeContentPredicate(query: String) -> Predicate<Episode> {
        #Predicate<Episode> { $0.content?.localizedStandardContains(query) == true }
    }

    private func chapterTitlePredicate(query: String) -> Predicate<Marker> {
        #Predicate<Marker> { $0.title.localizedStandardContains(query) }
    }

    private func transcriptLinePredicate(query: String) -> Predicate<TranscriptLineAndTime> {
        #Predicate<TranscriptLineAndTime> { $0.text.localizedStandardContains(query) }
    }

    private func containsIgnoringCaseAndDiacritics(_ text: String, query: String) -> Bool {
        text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: .current
        ) != nil
    }

    private func snippet(from text: String, query: String, maxLength: Int = 140) -> String {
        let cleanedText = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanedText.count > maxLength else { return cleanedText }

        let lowercaseText = cleanedText.lowercased()
        let lowercaseQuery = query.lowercased()
        if let range = lowercaseText.range(of: lowercaseQuery) {
            let lowerBound = cleanedText.distance(from: cleanedText.startIndex, to: range.lowerBound)
            let startOffset = max(0, lowerBound - (maxLength / 2))
            let startIndex = cleanedText.index(cleanedText.startIndex, offsetBy: startOffset)
            let length = min(maxLength, cleanedText.distance(from: startIndex, to: cleanedText.endIndex))
            let endIndex = cleanedText.index(startIndex, offsetBy: length)
            let clipped = String(cleanedText[startIndex..<endIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return startOffset == 0 ? clipped : "…\(clipped)"
        }

        return String(cleanedText.prefix(maxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
