import Foundation
import SwiftData

extension Notification.Name {
    static let smartPlaylistMembershipCacheDidInvalidate = Notification.Name("smartPlaylistMembershipCacheDidInvalidate")
}

enum SmartPlaylistCandidatePlan: Equatable {
    /// A necessary condition for every match when the filter uses `.all`.
    case publishedAtOrAfter(Date)
}

enum SmartPlaylistEngine {
    static func episodes(
        from allEpisodes: [Episode],
        for playlist: Playlist,
        shouldContinue: () -> Bool = { true }
    ) -> [Episode] {
        guard playlist.isSmartPlaylist else {
            return playlist.ordered.compactMap { $0.episode }
        }
        guard let filter = playlist.smartFilter else { return [] }

        // These values depend only on the filter. Preparing them once avoids
        // allocating and scanning the rules for every episode in a large library.
        let activeRules = filter.rules.filter(isConfigured)
        let explicitlyMatchesArchive = activeRules.contains {
            $0.field == .archived && ($0.values.first ?? $0.query).lowercased() == "yes"
        }

        var filtered: [Episode] = []
        filtered.reserveCapacity(min(allEpisodes.count, 256))
        for (index, episode) in allEpisodes.enumerated() {
            if index.isMultiple(of: 64), shouldContinue() == false { return [] }
            if matches(
                episode,
                filter: filter,
                activeRules: activeRules,
                explicitlyMatchesArchive: explicitlyMatchesArchive,
                shouldContinue: shouldContinue
            ) {
                filtered.append(episode)
            }
        }
        guard shouldContinue() else { return [] }

        filtered.sort { lhs, rhs in
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
        guard shouldContinue() else { return [] }
        if let limit = filter.resultLimit, limit > 0, filtered.count > limit {
            filtered.removeSubrange(limit...)
        }
        return filtered
    }

    static func matches(_ episode: Episode, filter: SmartPlaylistFilter?) -> Bool {
        guard let filter else {
            return false
        }

        let activeRules = filter.rules.filter(isConfigured)
        let explicitlyMatchesArchive = activeRules.contains {
            $0.field == .archived && ($0.values.first ?? $0.query).lowercased() == "yes"
        }
        return matches(
            episode,
            filter: filter,
            activeRules: activeRules,
            explicitlyMatchesArchive: explicitlyMatchesArchive,
            shouldContinue: { true }
        )
    }

    /// Restricts a database fetch only when a supported rule is a necessary
    /// condition for the complete filter. The caller must still evaluate every
    /// rule against the candidates returned here.
    static func candidatePlan(for filter: SmartPlaylistFilter?) -> SmartPlaylistCandidatePlan? {
        guard let filter, filter.matchMode == .all else { return nil }

        let lowerBounds = filter.rules.compactMap { rule -> Date? in
            guard isConfigured(rule),
                  rule.field == .published else { return nil }
            let value = rule.values.first ?? rule.query
            switch rule.comparator {
            case .greaterThan:
                return ISO8601DateFormatter().date(from: value)
            case .withinLastDays:
                guard let days = Double(value), days >= 0 else { return nil }
                return Calendar.current.date(byAdding: .day, value: -Int(days), to: .now)
            default:
                return nil
            }
        }
        guard let lowerBound = lowerBounds.max() else { return nil }
        return .publishedAtOrAfter(lowerBound)
    }

    /// Fetches the complete candidate set used by the user-facing smart
    /// playlist evaluator.
    static func candidateEpisodes(in context: ModelContext, for filter: SmartPlaylistFilter?) throws -> [Episode] {
        guard let plan = candidatePlan(for: filter) else {
            return try context.fetch(FetchDescriptor<Episode>())
        }
        switch plan {
        case let .publishedAtOrAfter(lowerBound):
            let descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { episode in
                    episode.publishDate != nil && episode.publishDate! >= lowerBound
                }
            )
            return try context.fetch(descriptor)
        }
    }

    /// Fetches a bounded candidate window for optional work such as transcript
    /// analysis. This is deliberately not used for the user-facing smart
    /// playlist result, which must remain complete.
    static func boundedCandidateEpisodes(
        in context: ModelContext,
        for filter: SmartPlaylistFilter?,
        limit: Int
    ) throws -> [Episode] {
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor<Episode>(
            sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        guard let plan = candidatePlan(for: filter) else {
            return try context.fetch(descriptor)
        }

        switch plan {
        case let .publishedAtOrAfter(lowerBound):
            descriptor.predicate = #Predicate<Episode> { episode in
                episode.publishDate != nil && episode.publishDate! >= lowerBound
            }
            return try context.fetch(descriptor)
        }
    }

    private static func matches(
        _ episode: Episode,
        filter: SmartPlaylistFilter,
        activeRules: [SmartPlaylistRule],
        explicitlyMatchesArchive: Bool,
        shouldContinue: () -> Bool
    ) -> Bool {
        var isAvailableLocally: Bool?
        if filter.requireDownloaded {
            let available = episode.metaData?.calculatedIsAvailableLocally == true
            isAvailableLocally = available
            guard available else { return false }
        }

        if filter.includeArchived == false,
           explicitlyMatchesArchive == false,
           episode.metaData?.isArchived == true {
            return false
        }

        guard activeRules.isEmpty == false else {
            // The download-only toggle is itself a complete smart-playlist
            // criterion. Its earlier gate above has already excluded every
            // episode that is not available locally.
            return filter.requireDownloaded
        }

        switch filter.matchMode {
        case .all:
            for (index, rule) in activeRules.enumerated() {
                if index.isMultiple(of: 16), shouldContinue() == false { return false }
                guard matches(episode, rule: rule, isAvailableLocally: &isAvailableLocally) else { return false }
            }
            return true
        case .any:
            for (index, rule) in activeRules.enumerated() {
                if index.isMultiple(of: 16), shouldContinue() == false { return false }
                if matches(episode, rule: rule, isAvailableLocally: &isAvailableLocally) { return true }
            }
            return false
        }
    }

    private static func matches(
        _ episode: Episode,
        rule: SmartPlaylistRule,
        isAvailableLocally: inout Bool?
    ) -> Bool {
        let queryValue = rule.values.first ?? rule.query
        if rule.field == .downloaded {
            let expected = queryValue.lowercased() == "yes" || queryValue.lowercased() == "true"
            let available = isAvailableLocally ?? (episode.metaData?.calculatedIsAvailableLocally == true)
            isAvailableLocally = available
            return available == expected
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
    func matchingEpisodeIDs(
        for playlistID: UUID,
        expectedFilter: SmartPlaylistFilter?
    ) throws -> [PersistentIdentifier] {
        let startedAt = Date.now
        let candidateSource = SmartPlaylistEngine.candidatePlan(for: expectedFilter) == nil
            ? "full_scan"
            : "published_date_after"
        var candidateCount = 0
        var resultCount = 0
        CrashBreadcrumbs.shared.record(
            "smart_playlist_evaluation_started",
            details: "duration_ms=0 candidate_count=not_yet_fetched result_count=not_yet_evaluated candidate_source=\(candidateSource)"
        )

        do {
            try Task.checkCancellation()
            let playlistIDValue = playlistID
            var playlistDescriptor = FetchDescriptor<Playlist>(
                predicate: #Predicate<Playlist> { $0.id == playlistIDValue }
            )
            playlistDescriptor.fetchLimit = 1
            guard let playlist = try modelContext.fetch(playlistDescriptor).first,
                  playlist.isSmartPlaylist,
                  playlist.smartFilter == expectedFilter else {
                throw CancellationError()
            }

            let episodes = try SmartPlaylistEngine.candidateEpisodes(
                in: modelContext,
                for: playlist.smartFilter
            )
            candidateCount = episodes.count
            try Task.checkCancellation()
            let matching = SmartPlaylistEngine.episodes(
                from: episodes,
                for: playlist,
                shouldContinue: { withUnsafeCurrentTask { $0?.isCancelled == false } }
            )
            try Task.checkCancellation()
            var episodeIDs: [PersistentIdentifier] = []
            episodeIDs.reserveCapacity(matching.count)
            for (index, episode) in matching.enumerated() {
                if index.isMultiple(of: 64), Task.isCancelled {
                    throw CancellationError()
                }
                episodeIDs.append(episode.persistentModelID)
            }
            try Task.checkCancellation()
            resultCount = episodeIDs.count
            CrashBreadcrumbs.shared.record(
                "smart_playlist_evaluation_completed",
                details: "duration_ms=\(elapsedMilliseconds(since: startedAt)) candidate_count=\(candidateCount) result_count=\(resultCount)"
            )
            return episodeIDs
        } catch is CancellationError {
            CrashBreadcrumbs.shared.record(
                "smart_playlist_evaluation_cancelled",
                details: "duration_ms=\(elapsedMilliseconds(since: startedAt)) candidate_count=\(candidateCount) result_count=\(resultCount)"
            )
            throw CancellationError()
        } catch {
            throw error
        }
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        Int(max(0, Date.now.timeIntervalSince(start) * 1_000).rounded())
    }
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

    private struct InFlightEvaluation {
        let filter: SmartPlaylistFilter?
        let generation: Int
        let id: UUID
        let task: Task<[PersistentIdentifier], Error>
    }

    private static var entries: [UUID: Entry] = [:]
    private static var evaluations: [UUID: InFlightEvaluation] = [:]
    private static var notificationObservers: [NSObjectProtocol] = []
    private static var invalidationDebounceTask: Task<Void, Never>?
    private static var invalidationGeneration = 0
    private static let lifetime: TimeInterval = 30

    static func episodeIDs(for playlistID: UUID, filter: SmartPlaylistFilter?) -> [PersistentIdentifier]? {
        ensureObservingMembershipChanges()
        guard let entry = entries[playlistID],
              entry.filter == filter,
              Date.now.timeIntervalSince(entry.createdAt) < lifetime else { return nil }
        return entry.episodeIDs
    }

    static func invalidate() {
        invalidationGeneration &+= 1
        entries.removeAll(keepingCapacity: true)
        let staleEvaluations = evaluations
        for (playlistID, evaluation) in staleEvaluations {
            Task { @MainActor in
                await cancelAndRetire(evaluation, for: playlistID)
            }
        }
    }

    private static func ensureObservingMembershipChanges() {
        guard notificationObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .episodeDownloadFinished,
            .smartPlaylistEpisodeDataDidChange
        ]
        notificationObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { @MainActor in
                    scheduleMembershipInvalidation()
                }
            }
        }
    }

    private static func scheduleMembershipInvalidation() {
        invalidationDebounceTask?.cancel()
        invalidationDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            invalidate()
            NotificationCenter.default.post(name: .smartPlaylistMembershipCacheDidInvalidate, object: nil)
            invalidationDebounceTask = nil
        }
    }

    static func matchingEpisodeIDs(
        for playlistID: UUID,
        filter: SmartPlaylistFilter?,
        using container: ModelContainer
    ) async throws -> [PersistentIdentifier] {
        try Task.checkCancellation()
        if let cached = episodeIDs(for: playlistID, filter: filter) { return cached }

        var generation = invalidationGeneration
        var selectedEvaluation: InFlightEvaluation?
        while selectedEvaluation == nil {
            try Task.checkCancellation()
            generation = invalidationGeneration
            if let cached = episodeIDs(for: playlistID, filter: filter) { return cached }

            if let existing = evaluations[playlistID] {
                if existing.filter == filter,
                   existing.generation == generation,
                   existing.task.isCancelled == false {
                    selectedEvaluation = existing
                } else {
                    await cancelAndRetire(existing, for: playlistID)
                }
                continue
            }

            let id = UUID()
            let evaluator = SmartPlaylistEvaluationActor(modelContainer: container)
            let task = Task<[PersistentIdentifier], Error>(priority: .userInitiated) {
                try await evaluator.matchingEpisodeIDs(for: playlistID, expectedFilter: filter)
            }
            let evaluation = InFlightEvaluation(
                filter: filter,
                generation: generation,
                id: id,
                task: task
            )
            evaluations[playlistID] = evaluation
            selectedEvaluation = evaluation
        }
        guard let evaluation = selectedEvaluation else { throw CancellationError() }

        do {
            let matchedEpisodeIDs = try await withTaskCancellationHandler {
                try await evaluation.task.value
            } onCancel: {
                Task { @MainActor in
                    guard evaluations[playlistID]?.id == evaluation.id else { return }
                    await cancelAndRetire(evaluation, for: playlistID)
                }
            }
            try Task.checkCancellation()
            guard generation == invalidationGeneration else {
                throw CancellationError()
            }
            if evaluations[playlistID]?.id == evaluation.id {
                entries[playlistID] = Entry(filter: filter, episodeIDs: matchedEpisodeIDs, createdAt: .now)
                evaluations[playlistID] = nil
            } else if let cached = episodeIDs(for: playlistID, filter: filter) {
                // Another caller sharing this evaluation may have stored the
                // result first and removed the in-flight entry.
                return cached
            } else {
                throw CancellationError()
            }
            return matchedEpisodeIDs
        } catch {
            if evaluations[playlistID]?.id == evaluation.id,
               Task.isCancelled == false,
               evaluation.task.isCancelled == false {
                evaluations[playlistID] = nil
            }
            throw error
        }
    }

    @MainActor
    private static func cancelAndRetire(_ evaluation: InFlightEvaluation, for playlistID: UUID) async {
        guard evaluations[playlistID]?.id == evaluation.id else { return }
        evaluation.task.cancel()
        _ = try? await evaluation.task.value
        if evaluations[playlistID]?.id == evaluation.id {
            evaluations[playlistID] = nil
        }
    }
}
