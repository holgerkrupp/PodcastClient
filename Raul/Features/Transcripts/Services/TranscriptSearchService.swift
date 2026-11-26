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

        let livePassages = try livePassages(matching: query, scope: request.scope)
        let window = request.offset > Int.max - request.limit ? Int.max : request.offset + request.limit
        let canonicalMatches: Int
        var lines: [TranscriptLineAndTime]
        if case .podcast(let identity) = request.scope {
            // Two-step podcast scope: resolve the podcast's episodes by scalar
            // key, then query lines per episode by persistent ID. This avoids
            // compiling the nested optional `line.episode?.podcast?.feed`
            // predicate, a #348 build-560 candidate.
            let episodeIDs = try episodeIDs(inPodcastScope: identity)
            (canonicalMatches, lines) = try podcastLines(
                matching: query,
                episodeIDs: episodeIDs,
                window: window
            )
            if livePassages.isEmpty {
                lines = Array(lines.dropFirst(request.offset).prefix(request.limit))
            }
        } else {
            let predicate = try transcriptPredicate(query: query, scope: request.scope)
            canonicalMatches = try modelContext.fetchCount(
                FetchDescriptor<TranscriptLineAndTime>(predicate: predicate)
            )
            try Task.checkCancellation()

            var descriptor = FetchDescriptor<TranscriptLineAndTime>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.startTime)]
            )
            if livePassages.isEmpty {
                descriptor.fetchLimit = request.limit
                descriptor.fetchOffset = request.offset
            } else {
                descriptor.fetchLimit = window
            }
            lines = try modelContext.fetch(descriptor)
        }
        var passages: [TranscriptSearchPassage] = []
        passages.reserveCapacity(lines.count)
        for line in lines {
            try Task.checkCancellation()
            guard let episode = line.episode, let podcast = episode.podcast else { continue }
            passages.append(makePassage(line: line, episode: episode, podcast: podcast, query: query))
        }

        if !livePassages.isEmpty {
            passages += livePassages
            passages.sort { $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime }
            passages = Array(passages.dropFirst(request.offset).prefix(request.limit))
        }
        return TranscriptSearchSnapshot(groups: Self.group(passages), totalMatches: canonicalMatches + livePassages.count)
    }

    func hasSearchableTranscripts(in scope: TranscriptSearchScope) async throws -> Bool {
        let signpostID = PodcastDetailFetchSignposts.begin(
            "Podcast detail transcript availability fetch"
        )
        var resultCount = -1
        defer {
            PodcastDetailFetchSignposts.end(
                "Podcast detail transcript availability fetch",
                id: signpostID,
                count: resultCount
            )
        }
        let hasLines = try hasCanonicalLines(in: scope) || !liveEpisodes(in: scope).isEmpty
        resultCount = hasLines ? 1 : 0
        return hasLines
    }

    private func liveEpisodes(in scope: TranscriptSearchScope) throws -> [Episode] {
        let predicate: Predicate<Episode>
        switch scope {
        case .library:
            predicate = #Predicate { $0.liveTranscriptData != nil }
        case .podcast(let identity):
            var episodes: [Episode] = []
            for podcastID in try podcastIDs(inPodcastScope: identity) {
                episodes += try modelContext.fetch(FetchDescriptor<Episode>(predicate: #Predicate {
                    $0.liveTranscriptData != nil && $0.podcast != nil && $0.podcast!.persistentModelID == podcastID
                }))
            }
            return episodes.filter(Self.hasOnlyLiveTranscript)
        case .episode(let identity):
            guard let id = try resolveEpisodePersistentID(for: identity) else { return [] }
            predicate = #Predicate { $0.liveTranscriptData != nil && $0.persistentModelID == id }
        }
        return try modelContext.fetch(FetchDescriptor<Episode>(predicate: predicate)).filter(Self.hasOnlyLiveTranscript)
    }

    private static func hasOnlyLiveTranscript(_ episode: Episode) -> Bool {
        episode.transcriptLines?.isEmpty != false
            && episode.liveTranscriptData.flatMap { try? JSONDecoder().decode(LiveTranscriptState.self, from: $0) }?.cues.isEmpty == false
    }

    private func livePassages(matching query: String, scope: TranscriptSearchScope) throws -> [TranscriptSearchPassage] {
        try liveEpisodes(in: scope).flatMap { episode -> [TranscriptSearchPassage] in
            guard let data = episode.liveTranscriptData,
                  let state = try? JSONDecoder().decode(LiveTranscriptState.self, from: data),
                  let podcast = episode.podcast else { return [] }
            return state.cues.filter { TranscriptSearchText.matches($0.text, query: query) }.map { cue in
                TranscriptSearchPassage(id: cue.id.uuidString, podcastID: podcast.stablePodcastIdentityKey,
                    podcastTitle: podcast.title, podcastImageURL: podcast.imageURL,
                    episodeID: episode.stableEpisodeIdentity.key, episodeTitle: episode.title,
                    episodeURL: episode.url, episodeImageURL: episode.imageURL, publishDate: episode.publishDate,
                    text: cue.text, snippet: makeSnippet(from: cue.text, query: query), speaker: nil,
                    startTime: cue.start, endTime: cue.end, matchedTerms: queryTerms(from: query))
            }
        }
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
        case .podcast:
            // Not used: search() resolves the podcast scope per episode with
            // podcastLines(matching:episodeIDs:window:).
            return #Predicate<TranscriptLineAndTime> { _ in false }
        case .episode(let episodeID):
            guard let episodePersistentID = try resolveEpisodePersistentID(for: episodeID) else {
                return #Predicate<TranscriptLineAndTime> { _ in false }
            }
            return #Predicate<TranscriptLineAndTime> { line in
                (line.text.localizedStandardContains(query)
                    || line.speaker?.localizedStandardContains(query) == true)
                    && line.episode != nil && line.episode!.persistentModelID == episodePersistentID
            }
        }
    }

    /// Existence check for canonical transcript lines. Library scope has no
    /// relationship predicate; episode scope compares one persistent ID; the
    /// podcast scope walks the podcast's episodes with one bounded,
    /// single-ID query each and stops at the first hit.
    private func hasCanonicalLines(in scope: TranscriptSearchScope) throws -> Bool {
        switch scope {
        case .library:
            var descriptor = FetchDescriptor<TranscriptLineAndTime>()
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).isEmpty == false
        case .podcast(let identity):
            for (index, episodeID) in try episodeIDs(inPodcastScope: identity).enumerated() {
                if index.isMultiple(of: 200) { try Task.checkCancellation() }
                if try hasLines(forEpisodeID: episodeID) { return true }
            }
            return false
        case .episode(let identity):
            guard let episodeID = try resolveEpisodePersistentID(for: identity) else { return false }
            return try hasLines(forEpisodeID: episodeID)
        }
    }

    // Foreign-key comparisons use `x != nil && x!.persistentModelID == id`.
    // SwiftData compiles the optional-chain spelling (`x?.persistentModelID ==
    // id`) to `CASE … END = ?`, which SQLite cannot answer from the
    // relationship index; the short-circuiting force-unwrap form compiles to
    // `ZEPISODE IS NOT NULL AND ZEPISODE = ?` (verified with SQLDebug).
    private func hasLines(forEpisodeID episodeID: PersistentIdentifier) throws -> Bool {
        var descriptor = FetchDescriptor<TranscriptLineAndTime>(
            predicate: #Predicate { $0.episode != nil && $0.episode!.persistentModelID == episodeID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).isEmpty == false
    }

    /// Podcasts addressed by a podcast-scope identity, resolved by the scalar
    /// `feed` or `title` key in this actor's context. Every podcast sharing the
    /// key is included, matching the former relationship predicate.
    private func podcastIDs(inPodcastScope identity: String) throws -> [PersistentIdentifier] {
        let (feed, title) = podcastScopeValues(for: identity)
        if let feed {
            return try modelContext.fetchIdentifiers(FetchDescriptor<Podcast>(
                predicate: #Predicate { $0.feed == feed }
            ))
        }
        if let title {
            return try modelContext.fetchIdentifiers(FetchDescriptor<Podcast>(
                predicate: #Predicate { $0.title == title }
            ))
        }
        return []
    }

    /// Episode IDs of the scoped podcasts via the episode's own foreign key
    /// (`podcast!.persistentModelID` after a nil check), never a nested optional keypath.
    private func episodeIDs(inPodcastScope identity: String) throws -> [PersistentIdentifier] {
        var result: [PersistentIdentifier] = []
        for podcastID in try podcastIDs(inPodcastScope: identity) {
            result += try modelContext.fetchIdentifiers(FetchDescriptor<Episode>(
                predicate: #Predicate { $0.podcast != nil && $0.podcast!.persistentModelID == podcastID }
            ))
        }
        return result
    }

    /// Matching lines of a podcast, ordered by `startTime`, limited to the
    /// first `window` rows (offset + limit), plus the exact total count.
    ///
    /// Each episode is queried by persistent ID. Once `window` candidates are
    /// held, later episodes only fetch lines starting no later than the
    /// current window boundary, so materialization stays bounded by `window`
    /// per matching episode rather than by the podcast's total match count.
    private func podcastLines(
        matching query: String,
        episodeIDs: [PersistentIdentifier],
        window: Int
    ) throws -> (count: Int, lines: [TranscriptLineAndTime]) {
        var total = 0
        var candidates: [(line: TranscriptLineAndTime, order: Int)] = []
        var order = 0
        for episodeID in episodeIDs {
            try Task.checkCancellation()
            let matchCount = try modelContext.fetchCount(FetchDescriptor<TranscriptLineAndTime>(
                predicate: #Predicate { line in
                    line.episode != nil && line.episode!.persistentModelID == episodeID
                        && (line.text.localizedStandardContains(query)
                            || line.speaker?.localizedStandardContains(query) == true)
                }
            ))
            guard matchCount > 0 else { continue }
            total += matchCount

            var descriptor: FetchDescriptor<TranscriptLineAndTime>
            if candidates.count >= window, let boundary = candidates.last?.line.startTime {
                descriptor = FetchDescriptor(
                    predicate: #Predicate { line in
                        line.episode != nil && line.episode!.persistentModelID == episodeID
                            && line.startTime <= boundary
                            && (line.text.localizedStandardContains(query)
                                || line.speaker?.localizedStandardContains(query) == true)
                    },
                    sortBy: [SortDescriptor(\.startTime)]
                )
            } else {
                descriptor = FetchDescriptor(
                    predicate: #Predicate { line in
                        line.episode != nil && line.episode!.persistentModelID == episodeID
                            && (line.text.localizedStandardContains(query)
                                || line.speaker?.localizedStandardContains(query) == true)
                    },
                    sortBy: [SortDescriptor(\.startTime)]
                )
            }
            descriptor.fetchLimit = min(matchCount, window)
            for line in try modelContext.fetch(descriptor) {
                candidates.append((line, order))
                order += 1
            }
            candidates.sort {
                $0.line.startTime == $1.line.startTime ? $0.order < $1.order : $0.line.startTime < $1.line.startTime
            }
            if candidates.count > window {
                candidates.removeLast(candidates.count - window)
            }
        }
        return (total, candidates.map(\.line))
    }

    private func resolveEpisodePersistentID(for identityKey: String) throws -> PersistentIdentifier? {
        guard let components = StableIdentityKey.components(from: identityKey),
              components.count >= 2,
              let feed = URL(string: components[0]) else {
            return nil
        }

        // Resolve the podcast by its scalar feed first, then compare the
        // episode's foreign key, instead of `episode.podcast?.feed == feed`.
        let podcastIDs = try modelContext.fetchIdentifiers(FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.feed == feed }
        ))
        let episodeIdentity = components[1]
        for podcastID in podcastIDs {
            let descriptor: FetchDescriptor<Episode>
            if episodeIdentity.hasPrefix("guid:") {
                let guid = String(episodeIdentity.dropFirst("guid:".count))
                descriptor = FetchDescriptor<Episode>(predicate: #Predicate { episode in
                    episode.podcast != nil && episode.podcast!.persistentModelID == podcastID && episode.guid == guid
                })
            } else if episodeIdentity.hasPrefix("enclosure:") {
                let url = URL(string: String(episodeIdentity.dropFirst("enclosure:".count)))
                descriptor = FetchDescriptor<Episode>(predicate: #Predicate { episode in
                    episode.podcast != nil && episode.podcast!.persistentModelID == podcastID && episode.url == url
                })
            } else if episodeIdentity.hasPrefix("episode:") {
                let url = URL(string: String(episodeIdentity.dropFirst("episode:".count)))
                descriptor = FetchDescriptor<Episode>(predicate: #Predicate { episode in
                    episode.podcast != nil && episode.podcast!.persistentModelID == podcastID && episode.url == url
                })
            } else if episodeIdentity.hasPrefix("link:") {
                let url = URL(string: String(episodeIdentity.dropFirst("link:".count)))
                descriptor = FetchDescriptor<Episode>(predicate: #Predicate { episode in
                    episode.podcast != nil && episode.podcast!.persistentModelID == podcastID && episode.link == url
                })
            } else {
                var fallback = FetchDescriptor<Episode>(predicate: #Predicate { episode in
                    episode.podcast != nil && episode.podcast!.persistentModelID == podcastID
                })
                fallback.fetchLimit = 500
                if let id = try modelContext.fetch(fallback).first(where: {
                    $0.stableEpisodeIdentity.key == identityKey
                })?.persistentModelID {
                    return id
                }
                continue
            }

            var bounded = descriptor
            bounded.fetchLimit = 1
            if let id = try modelContext.fetch(bounded).first?.persistentModelID {
                return id
            }
        }
        return nil
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
