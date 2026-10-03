import Foundation
import SwiftData

enum TranscriptSearchScope: Hashable, Sendable {
    case episode(String)
    case podcast(String)
    case library
}

struct TranscriptSearchQuery: Sendable {
    let text: String
    let scope: TranscriptSearchScope
    let limit: Int
    let offset: Int

    init(text: String, scope: TranscriptSearchScope, limit: Int = 80, offset: Int = 0) {
        self.text = text
        self.scope = scope
        self.limit = max(1, min(limit, 250))
        self.offset = max(0, offset)
    }
}

enum TranscriptSearchText {
    static func matches(_ text: String, query: String) -> Bool {
        let normalizedText = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "ß", with: "ss")
        let normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "ß", with: "ss")
        guard normalizedQuery.isEmpty == false else { return false }
        return normalizedText.range(of: normalizedQuery) != nil
    }
}

struct TranscriptSearchPassage: Identifiable, Hashable, Sendable {
    let id: String
    let podcastID: String
    let podcastTitle: String
    let podcastImageURL: URL?
    let episodeID: String
    let episodeTitle: String
    let episodeURL: URL?
    let episodeImageURL: URL?
    let publishDate: Date?
    let text: String
    let snippet: String
    let speaker: String?
    let startTime: TimeInterval
    let endTime: TimeInterval?
    let matchedTerms: [String]
}

struct TranscriptSearchEpisodeGroup: Identifiable, Hashable, Sendable {
    let episodeID: String
    let episodeTitle: String
    let episodeURL: URL?
    let episodeImageURL: URL?
    let publishDate: Date?
    let passages: [TranscriptSearchPassage]

    var id: String { episodeID }
}

struct TranscriptSearchPodcastGroup: Identifiable, Hashable, Sendable {
    let podcastID: String
    let podcastTitle: String
    let podcastImageURL: URL?
    let episodes: [TranscriptSearchEpisodeGroup]

    var id: String { podcastID }
    var passageCount: Int { episodes.reduce(0) { $0 + $1.passages.count } }
}

struct TranscriptSearchSnapshot: Sendable {
    let groups: [TranscriptSearchPodcastGroup]
    let totalMatches: Int
}

enum TranscriptSearchError: LocalizedError {
    case invalidQuery

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "Enter a word or phrase to search transcripts."
        }
    }
}

protocol TranscriptSearching: Sendable {
    func search(_ request: TranscriptSearchQuery) async throws -> TranscriptSearchSnapshot
    func hasSearchableTranscripts(in scope: TranscriptSearchScope) async throws -> Bool
}

/// Queries canonical SwiftData transcript lines directly. This actor returns
/// immutable snapshots and never creates a second persisted copy of transcript
/// text for search.
@ModelActor
actor TranscriptSearchActor: TranscriptSearching {
    func search(_ request: TranscriptSearchQuery) async throws -> TranscriptSearchSnapshot {
        let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { throw TranscriptSearchError.invalidQuery }
        try Task.checkCancellation()

        let predicate = try transcriptPredicate(query: query, scope: request.scope)
        let totalMatches = try modelContext.fetchCount(
            FetchDescriptor<TranscriptLineAndTime>(predicate: predicate)
        )
        try Task.checkCancellation()

        var descriptor = FetchDescriptor<TranscriptLineAndTime>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startTime)]
        )
        descriptor.fetchLimit = request.limit
        descriptor.fetchOffset = request.offset

        let lines = try modelContext.fetch(descriptor)
        var passages: [TranscriptSearchPassage] = []
        passages.reserveCapacity(lines.count)
        for line in lines {
            try Task.checkCancellation()
            guard let episode = line.episode, let podcast = episode.podcast else { continue }
            passages.append(makePassage(line: line, episode: episode, podcast: podcast, query: query))
        }

        return TranscriptSearchSnapshot(
            groups: Self.group(passages),
            totalMatches: totalMatches
        )
    }

    func hasSearchableTranscripts(in scope: TranscriptSearchScope) async throws -> Bool {
        let predicate = try scopePredicate(scope)
        var descriptor = FetchDescriptor<TranscriptLineAndTime>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).isEmpty == false
    }

    private func transcriptPredicate(
        query: String,
        scope: TranscriptSearchScope
    ) throws -> Predicate<TranscriptLineAndTime> {
        switch scope {
        case .library:
            return #Predicate<TranscriptLineAndTime> { line in
                line.text.localizedStandardContains(query)
                    || line.speaker?.localizedStandardContains(query) == true
            }
        case .podcast(let podcastID):
            let (feed, title) = podcastScopeValues(for: podcastID)
            if let feed {
                return #Predicate<TranscriptLineAndTime> { line in
                    (line.text.localizedStandardContains(query)
                        || line.speaker?.localizedStandardContains(query) == true)
                        && line.episode?.podcast?.feed == feed
                }
            }
            guard let title else {
                return #Predicate<TranscriptLineAndTime> { _ in false }
            }
            return #Predicate<TranscriptLineAndTime> { line in
                (line.text.localizedStandardContains(query)
                    || line.speaker?.localizedStandardContains(query) == true)
                    && line.episode?.podcast?.title == title
            }
        case .episode(let episodeID):
            guard let episodePersistentID = try resolveEpisodePersistentID(for: episodeID) else {
                return #Predicate<TranscriptLineAndTime> { _ in false }
            }
            return #Predicate<TranscriptLineAndTime> { line in
                (line.text.localizedStandardContains(query)
                    || line.speaker?.localizedStandardContains(query) == true)
                    && line.episode?.persistentModelID == episodePersistentID
            }
        }
    }

    private func scopePredicate(_ scope: TranscriptSearchScope) throws -> Predicate<TranscriptLineAndTime> {
        switch scope {
        case .library:
            return #Predicate<TranscriptLineAndTime> { _ in true }
        case .podcast(let podcastID):
            let (feed, title) = podcastScopeValues(for: podcastID)
            if let feed {
                return #Predicate<TranscriptLineAndTime> { line in
                    line.episode?.podcast?.feed == feed
                }
            }
            guard let title else {
                return #Predicate<TranscriptLineAndTime> { _ in false }
            }
            return #Predicate<TranscriptLineAndTime> { line in
                line.episode?.podcast?.title == title
            }
        case .episode(let episodeID):
            guard let episodePersistentID = try resolveEpisodePersistentID(for: episodeID) else {
                return #Predicate<TranscriptLineAndTime> { _ in false }
            }
            return #Predicate<TranscriptLineAndTime> { line in
                line.episode?.persistentModelID == episodePersistentID
            }
        }
    }

    private func resolveEpisodePersistentID(for identityKey: String) throws -> PersistentIdentifier? {
        guard let components = StableIdentityKey.components(from: identityKey),
              components.count >= 2,
              let feed = URL(string: components[0]) else {
            return nil
        }

        let episodeIdentity = components[1]
        let descriptor: FetchDescriptor<Episode>
        if episodeIdentity.hasPrefix("guid:") {
            let guid = String(episodeIdentity.dropFirst("guid:".count))
            descriptor = FetchDescriptor<Episode>(predicate: #Predicate { episode in
                episode.podcast?.feed == feed && episode.guid == guid
            })
        } else if episodeIdentity.hasPrefix("enclosure:") {
            let url = URL(string: String(episodeIdentity.dropFirst("enclosure:".count)))
            descriptor = FetchDescriptor<Episode>(predicate: #Predicate { episode in
                episode.podcast?.feed == feed && episode.url == url
            })
        } else if episodeIdentity.hasPrefix("episode:") {
            let url = URL(string: String(episodeIdentity.dropFirst("episode:".count)))
            descriptor = FetchDescriptor<Episode>(predicate: #Predicate { episode in
                episode.podcast?.feed == feed && episode.url == url
            })
        } else if episodeIdentity.hasPrefix("link:") {
            let url = URL(string: String(episodeIdentity.dropFirst("link:".count)))
            descriptor = FetchDescriptor<Episode>(predicate: #Predicate { episode in
                episode.podcast?.feed == feed && episode.link == url
            })
        } else {
            var fallback = FetchDescriptor<Episode>(predicate: #Predicate { episode in
                episode.podcast?.feed == feed
            })
            fallback.fetchLimit = 500
            return try modelContext.fetch(fallback).first {
                $0.stableEpisodeIdentity.key == identityKey
            }?.persistentModelID
        }

        var bounded = descriptor
        bounded.fetchLimit = 1
        return try modelContext.fetch(bounded).first?.persistentModelID
    }

    private func podcastScopeValues(for identity: String) -> (URL?, String?) {
        if let feed = URL(string: identity), feed.scheme != nil {
            return (feed, nil)
        }
        if let components = StableIdentityKey.components(from: identity),
           components.first == "title",
           components.count > 1 {
            return (nil, components[1])
        }
        return (URL(string: identity), nil)
    }

    private func makePassage(
        line: TranscriptLineAndTime,
        episode: Episode,
        podcast: Podcast,
        query: String
    ) -> TranscriptSearchPassage {
        TranscriptSearchPassage(
            id: line.id.uuidString,
            podcastID: podcast.stablePodcastIdentityKey,
            podcastTitle: podcast.title,
            podcastImageURL: podcast.imageURL,
            episodeID: episode.stableEpisodeIdentity.key,
            episodeTitle: episode.title,
            episodeURL: episode.url,
            episodeImageURL: episode.imageURL,
            publishDate: episode.publishDate,
            text: line.text,
            snippet: makeSnippet(from: line.text, query: query),
            speaker: line.speaker,
            startTime: line.startTime,
            endTime: line.endTime,
            matchedTerms: queryTerms(from: query)
        )
    }

    private func makeSnippet(from text: String, query: String, maxLength: Int = 180) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxLength else { return markDirectMatch(in: cleaned, query: query) }
        guard let range = cleaned.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: .current
        ) else {
            return String(cleaned.prefix(maxLength))
        }
        let offset = cleaned.distance(from: cleaned.startIndex, to: range.lowerBound)
        let startOffset = max(0, offset - maxLength / 2)
        let startIndex = cleaned.index(cleaned.startIndex, offsetBy: startOffset)
        let length = min(maxLength, cleaned.distance(from: startIndex, to: cleaned.endIndex))
        let endIndex = cleaned.index(startIndex, offsetBy: length)
        let clipped = String(cleaned[startIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (startOffset == 0 ? "" : "…") + markDirectMatch(in: clipped, query: query)
    }

    private func markDirectMatch(in text: String, query: String) -> String {
        guard let range = text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: .current
        ) else { return text }
        return String(text[..<range.lowerBound])
            + "[" + String(text[range]) + "]" + String(text[range.upperBound...])
    }

    private func queryTerms(from query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map { String($0) }
    }

    private static func group(_ results: [TranscriptSearchPassage]) -> [TranscriptSearchPodcastGroup] {
        var episodesByPodcast: [String: [String: [TranscriptSearchPassage]]] = [:]
        var podcastMetadata: [String: (String, URL?)] = [:]
        var episodeMetadata: [String: (String, URL?, URL?, Date?)] = [:]

        for result in results {
            episodesByPodcast[result.podcastID, default: [:]][result.episodeID, default: []].append(result)
            podcastMetadata[result.podcastID] = (result.podcastTitle, result.podcastImageURL)
            episodeMetadata[result.episodeID] = (
                result.episodeTitle,
                result.episodeURL,
                result.episodeImageURL,
                result.publishDate
            )
        }

        return episodesByPodcast.keys.sorted { lhs, rhs in
            (podcastMetadata[lhs]?.0 ?? "").localizedCaseInsensitiveCompare(podcastMetadata[rhs]?.0 ?? "") == .orderedAscending
        }.compactMap { podcastID in
            guard let metadata = podcastMetadata[podcastID] else { return nil }
            let episodes = episodesByPodcast[podcastID, default: [:]].keys.sorted { lhs, rhs in
                let left = episodeMetadata[lhs]?.3 ?? .distantPast
                let right = episodeMetadata[rhs]?.3 ?? .distantPast
                if left != right { return left > right }
                return (episodeMetadata[lhs]?.0 ?? "").localizedCaseInsensitiveCompare(episodeMetadata[rhs]?.0 ?? "") == .orderedAscending
            }.compactMap { episodeID -> TranscriptSearchEpisodeGroup? in
                guard let episode = episodeMetadata[episodeID] else { return nil }
                return TranscriptSearchEpisodeGroup(
                    episodeID: episodeID,
                    episodeTitle: episode.0,
                    episodeURL: episode.1,
                    episodeImageURL: episode.2,
                    publishDate: episode.3,
                    passages: episodesByPodcast[podcastID]?[episodeID] ?? []
                )
            }
            return TranscriptSearchPodcastGroup(
                podcastID: podcastID,
                podcastTitle: metadata.0,
                podcastImageURL: metadata.1,
                episodes: episodes
            )
        }
    }
}

enum TranscriptSearchLegacyStoreCleanup {
    /// Removes only the old derived search database and its SQLite sidecars.
    /// Canonical SwiftData stores are deliberately outside this path.
    static func removeObsoleteStore() {
        let baseURL = ModelContainerManager.sharedContainerURL
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let storeURL = baseURL
            .appendingPathComponent("TranscriptSearch", isDirectory: true)
            .appendingPathComponent("TranscriptSearch.sqlite")
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
    }
}
