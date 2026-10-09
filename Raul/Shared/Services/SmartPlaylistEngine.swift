import Foundation
import SwiftData

enum SmartPlaylistEngine {
    static func episodes(from allEpisodes: [Episode], for playlist: Playlist) -> [Episode] {
        guard playlist.isSmartPlaylist else {
            return playlist.ordered.compactMap { $0.episode }
        }

        let filtered = allEpisodes.filter { matches($0, filter: playlist.smartFilter) }
        let sorted = filtered.sorted { lhs, rhs in
            let lhsDate = lhs.publishDate ?? .distantPast
            let rhsDate = rhs.publishDate ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }

            let lhsTitle = lhs.title
            let rhsTitle = rhs.title
            if lhsTitle != rhsTitle {
                return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
            }

            return (lhs.url?.absoluteString ?? "") < (rhs.url?.absoluteString ?? "")
        }
        if let limit = playlist.smartFilter?.resultLimit, limit > 0 { return Array(sorted.prefix(limit)) }
        return sorted
    }

    static func matches(_ episode: Episode, filter: SmartPlaylistFilter?) -> Bool {
        guard let filter else {
            return false
        }

        if filter.requireDownloaded,
           episode.metaData?.calculatedIsAvailableLocally != true {
            return false
        }

        let explicitlyMatchesArchive = filter.rules.contains {
            $0.field == .archived && ($0.values.first ?? $0.query).lowercased() == "yes"
        }
        if filter.includeArchived == false,
           explicitlyMatchesArchive == false,
           episode.metaData?.isArchived == true {
            return false
        }

        let activeRules = filter.rules.filter { isConfigured($0) }

        guard activeRules.isEmpty == false else {
            // The download-only toggle is itself a complete smart-playlist
            // criterion. Its earlier gate above has already excluded every
            // episode that is not available locally.
            return filter.requireDownloaded
        }

        let evaluations = activeRules.map { rule in
            matches(episode, rule: rule)
        }

        switch filter.matchMode {
        case .all:
            return evaluations.allSatisfy { $0 }
        case .any:
            return evaluations.contains(true)
        }
    }

    private static func matches(_ episode: Episode, rule: SmartPlaylistRule) -> Bool {
        let queryValue = rule.values.first ?? rule.query
        if rule.field == .downloaded {
            let expected = queryValue.lowercased() == "yes" || queryValue.lowercased() == "true"
            return (episode.metaData?.calculatedIsAvailableLocally == true) == expected
        }
        if rule.field == .archived {
            let expected = queryValue.lowercased() == "yes" || queryValue.lowercased() == "true"
            return (episode.metaData?.isArchived == true) == expected
        }
        if rule.field == .status {
            switch queryValue.lowercased() {
            case "played": return episode.isPlayed
            case "in progress", "inprogress": return episode.hasPlaybackHistory && !episode.isPlayed
            case "unplayed": return !episode.hasPlaybackHistory && !episode.isPlayed
            default: return false
            }
        }
        if rule.field == .duration {
            guard let duration = episode.duration, duration.isFinite, let amount = Double(queryValue), amount >= 0 else { return false }
            let minutes = duration / 60
            switch rule.comparator {
            case .lessThan: return minutes < amount
            case .greaterThan: return minutes >= amount
            case .equals: return minutes == amount
            default: return false
            }
        }
        if rule.field == .published {
            guard let date = episode.publishDate else { return false }
            if rule.comparator == .withinLastDays, let days = Double(queryValue), days >= 0 {
                return date >= Calendar.current.date(byAdding: .day, value: -Int(days), to: .now) ?? .distantFuture
            }
            guard let target = ISO8601DateFormatter().date(from: queryValue) else { return false }
            return rule.comparator == .greaterThan ? date >= target : date <= target
        }
        if rule.field == .episodeType {
            return episode.type?.rawValue.caseInsensitiveCompare(queryValue) == .orderedSame
        }
        if rule.field == .source {
            let expected = queryValue.lowercased()
            return (episode.source == .sideLoaded ? "sideloaded" : "feed") == expected
        }
        if rule.field == .language {
            guard let language = episode.podcast?.language else { return false }
            let actualBase = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased()
            let wantedBase = queryValue.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased()
            return actualBase == wantedBase
        }
        if rule.field == .category {
            return podcastCategories(episode.podcast?.optionalTags).contains { normalize($0) == normalize(queryValue) }
        }
        let normalizedQuery = normalize(rule.query)
        guard normalizedQuery.isEmpty == false else {
            return true
        }

        return values(for: rule.field, episode: episode).contains { value in
            compare(candidate: normalize(value), query: normalizedQuery, using: rule.comparator)
        }
    }

    private static func isConfigured(_ rule: SmartPlaylistRule) -> Bool {
        if rule.values.isEmpty == false { return rule.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        return !rule.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func podcastCategories(_ tags: PodcastNamespaceOptionalTags?) -> [String] {
        guard let tags else { return [] }
        return namespaceNodes(tags).flatMap { categoryValues($0) }
    }

    private static func namespaceNodes(_ tags: PodcastNamespaceOptionalTags) -> [NamespaceNode] {
        var result: [NamespaceNode] = []
        for child in Mirror(reflecting: tags).children {
            if let nodes = child.value as? [NamespaceNode] { result += nodes; continue }
            let mirror = Mirror(reflecting: child.value)
            if mirror.displayStyle == .optional, let nodes = mirror.children.first?.value as? [NamespaceNode] { result += nodes }
        }
        return result
    }

    private static func categoryValues(_ node: NamespaceNode) -> [String] {
        let name = node.name.lowercased()
        if name.contains("category") {
            return ([node.value] + [node.attributes["text"]]).compactMap { $0 } + node.children.flatMap(categoryValues)
        }
        return node.children.flatMap(categoryValues)
    }

    private static func values(for field: SmartPlaylistField, episode: Episode) -> [String] {
        switch field {
        case .episodeTitle:
            return [episode.title]

        case .podcastTitle:
            if let podcastTitle = episode.podcast?.title {
                return [podcastTitle]
            }
            return []

        case .podcastFeed:
            if let feed = episode.podcast?.feed?.absoluteString {
                return [feed]
            }
            return []

        case .personName:
            let episodePeople = episode.people.map(\.name)
            let podcastPeople = episode.podcast?.people.map(\.name) ?? []
            return episodePeople + podcastPeople

        case .author:
            return [episode.author, episode.podcast?.author].compactMap { $0 }

        case .description:
            return [episode.subtitle, episode.desc, episode.content].compactMap { $0 }

        case .metadata:
            let episodeTags = flattenedNamespaceText(tags: episode.optionalTags)
            let podcastTags = flattenedNamespaceText(tags: episode.podcast?.optionalTags)
            return [episodeTags, podcastTags].compactMap { $0 }
        case .downloaded, .language, .duration, .published, .status, .archived, .episodeType, .source, .category:
            return []
        }
    }

    private static func compare(candidate: String, query: String, using comparator: SmartPlaylistComparator) -> Bool {
        switch comparator {
        case .contains:
            return candidate.contains(query)
        case .equals:
            return candidate == query
        case .startsWith:
            return candidate.hasPrefix(query)
        case .endsWith:
            return candidate.hasSuffix(query)
        case .lessThan, .greaterThan, .withinLastDays:
            return false
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private static func flattenedNamespaceText(tags: PodcastNamespaceOptionalTags?) -> String? {
        guard let tags else { return nil }

        var fragments: [String] = []
        let mirror = Mirror(reflecting: tags)

        for child in mirror.children {
            let nodes: [NamespaceNode]?

            if let directNodes = child.value as? [NamespaceNode] {
                nodes = directNodes
            } else {
                let optionalMirror = Mirror(reflecting: child.value)
                if optionalMirror.displayStyle == .optional,
                   let first = optionalMirror.children.first,
                   let unwrappedNodes = first.value as? [NamespaceNode] {
                    nodes = unwrappedNodes
                } else {
                    nodes = nil
                }
            }

            guard let nodes else { continue }
            for node in nodes {
                fragments.append(contentsOf: nodeFragments(for: node))
            }
        }

        guard fragments.isEmpty == false else { return nil }
        return fragments.joined(separator: " ")
    }

    private static func nodeFragments(for node: NamespaceNode) -> [String] {
        var values: [String] = [node.name]

        if let value = node.value,
           value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            values.append(value)
        }

        for (key, value) in node.attributes {
            values.append(key)
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                values.append(value)
            }
        }

        for child in node.children {
            values.append(contentsOf: nodeFragments(for: child))
        }

        return values
    }
}

/// Evaluates smart-playlist membership in an isolated SwiftData context so a
/// large library never blocks the playlist switch animation or scrolling.
@ModelActor
actor SmartPlaylistEvaluationActor {
    func matchingEpisodeIDs(for playlistID: UUID) throws -> [PersistentIdentifier] {
        let playlistIDValue = playlistID
        var playlistDescriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { $0.id == playlistIDValue }
        )
        playlistDescriptor.fetchLimit = 1
        guard let playlist = try modelContext.fetch(playlistDescriptor).first,
              playlist.isSmartPlaylist else {
            return []
        }

        let episodes = try modelContext.fetch(FetchDescriptor<Episode>())
        return SmartPlaylistEngine.episodes(from: episodes, for: playlist)
            .map(\.persistentModelID)
    }

    func prefetchEpisodeIDs(for requests: [SmartPlaylistPrefetchRequest]) throws -> [UUID: [PersistentIdentifier]] {
        let playlists = try modelContext.fetch(FetchDescriptor<Playlist>())
        let playlistsByID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        let episodes = try modelContext.fetch(FetchDescriptor<Episode>())
        var result: [UUID: [PersistentIdentifier]] = [:]

        for request in requests {
            guard let playlist = playlistsByID[request.playlistID],
                  playlist.isSmartPlaylist,
                  playlist.smartFilter == request.filter else { continue }
            let matching = SmartPlaylistEngine.episodes(from: episodes, for: playlist)
            result[request.playlistID] = matching.map(\.persistentModelID)
        }
        return result
    }
}

struct SmartPlaylistPrefetchRequest: Sendable {
    let playlistID: UUID
    let filter: SmartPlaylistFilter?
}

/// A process-local cache of derived membership. It stores identifiers only;
/// playlist membership remains virtual and is never written as PlaylistEntry.
@MainActor
enum SmartPlaylistMembershipCache {
    private struct Entry {
        let filter: SmartPlaylistFilter?
        let episodeIDs: [PersistentIdentifier]
        let createdAt: Date
    }

    private static var entries: [UUID: Entry] = [:]
    private static var invalidationGeneration = 0
    private static let lifetime: TimeInterval = 30

    static func episodeIDs(for playlistID: UUID, filter: SmartPlaylistFilter?) -> [PersistentIdentifier]? {
        guard let entry = entries[playlistID],
              entry.filter == filter,
              Date.now.timeIntervalSince(entry.createdAt) < lifetime else { return nil }
        return entry.episodeIDs
    }

    static func store(_ episodeIDs: [PersistentIdentifier], for playlistID: UUID, filter: SmartPlaylistFilter?) {
        entries[playlistID] = Entry(filter: filter, episodeIDs: episodeIDs, createdAt: .now)
    }

    static func invalidate(_ playlistID: UUID? = nil) {
        invalidationGeneration &+= 1
        if let playlistID {
            entries[playlistID] = nil
        } else {
            entries.removeAll(keepingCapacity: true)
        }
    }

    static func prefetch(_ requests: [SmartPlaylistPrefetchRequest], using container: ModelContainer) async {
        let missingRequests = requests.filter {
            episodeIDs(for: $0.playlistID, filter: $0.filter) == nil
        }
        guard missingRequests.isEmpty == false else { return }
        let generation = invalidationGeneration

        let evaluator = SmartPlaylistEvaluationActor(modelContainer: container)
        guard let prefetched = try? await evaluator.prefetchEpisodeIDs(for: missingRequests) else { return }
        guard generation == invalidationGeneration else { return }
        for request in missingRequests {
            guard let episodeIDs = prefetched[request.playlistID] else { continue }
            store(episodeIDs, for: request.playlistID, filter: request.filter)
        }
    }
}
