import Foundation

enum SmartPlaylistEngine {
    static func episodes(from allEpisodes: [Episode], for playlist: Playlist) -> [Episode] {
        guard playlist.isSmartPlaylist else {
            return playlist.ordered.compactMap { $0.episode }
        }

        let filtered = allEpisodes.filter { matches($0, filter: playlist.smartFilter) }
        return filtered.sorted { lhs, rhs in
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
    }

    static func matches(_ episode: Episode, filter: SmartPlaylistFilter?) -> Bool {
        guard let filter else {
            return false
        }

        if filter.requireDownloaded,
           episode.metaData?.calculatedIsAvailableLocally != true {
            return false
        }

        if filter.includeArchived == false,
           episode.metaData?.isArchived == true {
            return false
        }

        let activeRules = filter.rules.filter {
            !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard activeRules.isEmpty == false else {
            return true
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
        let normalizedQuery = normalize(rule.query)
        guard normalizedQuery.isEmpty == false else {
            return true
        }

        return values(for: rule.field, episode: episode).contains { value in
            compare(candidate: normalize(value), query: normalizedQuery, using: rule.comparator)
        }
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
