//
//  Playlist.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData

enum PlaylistPreferenceKeys {
    static let selectedPlaylistID = "selectedPlaylistID"
    static let inboxBasePlaylistID = "inboxBasePlaylistID"
}

enum SmartPlaylistMatchMode: String, Codable, CaseIterable, Hashable, Sendable {
    case all
    case any

    var displayName: String {
        switch self {
        case .all:
            return "Match all filters"
        case .any:
            return "Match any filter"
        }
    }
}

enum SmartPlaylistField: String, Codable, CaseIterable, Hashable, Sendable {
    case episodeTitle
    case podcastTitle
    case podcastFeed
    case personName
    case author
    case description
    case metadata

    var displayName: String {
        switch self {
        case .episodeTitle:
            return "Episode title"
        case .podcastTitle:
            return "Podcast title"
        case .podcastFeed:
            return "Podcast"
        case .personName:
            return "Person"
        case .author:
            return "Author"
        case .description:
            return "Description"
        case .metadata:
            return "Metadata"
        }
    }
}

enum SmartPlaylistComparator: String, Codable, CaseIterable, Hashable, Sendable {
    case contains
    case equals
    case startsWith
    case endsWith

    var displayName: String {
        switch self {
        case .contains:
            return "Contains"
        case .equals:
            return "Is exactly"
        case .startsWith:
            return "Starts with"
        case .endsWith:
            return "Ends with"
        }
    }
}

struct SmartPlaylistRule: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var field: SmartPlaylistField = .episodeTitle
    var comparator: SmartPlaylistComparator = .contains
    var query: String = ""

    init(
        id: UUID = UUID(),
        field: SmartPlaylistField,
        comparator: SmartPlaylistComparator = .contains,
        query: String
    ) {
        self.id = id
        self.field = field
        self.comparator = comparator
        self.query = query
    }
}

struct SmartPlaylistFilter: Codable, Hashable, Sendable {
    var matchMode: SmartPlaylistMatchMode = .all
    var requireDownloaded: Bool = false
    var includeArchived: Bool = false
    var rules: [SmartPlaylistRule] = []

    var hasRules: Bool {
        rules.contains { !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

@Model
class Playlist {
    static let defaultQueueTitle = "de.holgerkrupp.podbay.queue"
    static let defaultQueueDisplayName = "Up Next"

    var title: String = ""
    var id: UUID = UUID()
    var deleteable: Bool = true // to enable standard lists like "play next queue" or similar that can't be deleted by the user
    var hidden: Bool = false
    var sortIndex: Int = 0
    var kindRawValue: String = Kind.manual.rawValue
    var smartFilter: SmartPlaylistFilter?

    @Relationship var items: [PlaylistEntry]? = [] // we need to ensure that we can create an ordered list. Swiftdata won't ensure that the items are kept in the same order without manually managing that.

    @Transient var ordered: [PlaylistEntry] {
        items?.sorted(by: { $0.order < $1.order }) ?? []
    }

    init() {
        self.title = Self.defaultQueueTitle
        self.deleteable = false
        self.sortIndex = 0
        self.kindRawValue = Kind.manual.rawValue
    }

    enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case manual
        case smart
    }

    var kind: Kind {
        get {
            Kind(rawValue: kindRawValue) ?? .manual
        }
        set {
            kindRawValue = newValue.rawValue
        }
    }

    var isSmartPlaylist: Bool {
        kind == .smart
    }

    var displayTitle: String {
        title == Self.defaultQueueTitle ? Self.defaultQueueDisplayName : title
    }

    static func visibleSorted(_ playlists: [Playlist]) -> [Playlist] {
        playlists
            .filter { $0.hidden == false }
            .sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex {
                    return lhs.sortIndex < rhs.sortIndex
                }
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
    }

    static func manualVisibleSorted(_ playlists: [Playlist]) -> [Playlist] {
        visibleSorted(playlists).filter { $0.kind == .manual }
    }

    static func ensureDefaultQueue(in context: ModelContext) -> Playlist {
        let allPlaylists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        let isLegacyDefaultTitle: (String) -> Bool = { title in
            title.localizedCaseInsensitiveCompare(Playlist.defaultQueueDisplayName) == .orderedSame
        }

        let keyMatches = allPlaylists.filter { $0.title == Playlist.defaultQueueTitle }
        let legacyMatches = allPlaylists.filter { isLegacyDefaultTitle($0.title) }

        let defaultPlaylist: Playlist = {
            if let existing = keyMatches.first {
                return existing
            }
            if let legacy = legacyMatches.first {
                return legacy
            }

            let playlist = Playlist()
            context.insert(playlist)
            return playlist
        }()

        var changed = false

        if defaultPlaylist.title != defaultQueueTitle {
            defaultPlaylist.title = defaultQueueTitle
            changed = true
        }
        if defaultPlaylist.deleteable {
            defaultPlaylist.deleteable = false
            changed = true
        }
        if defaultPlaylist.kind != .manual {
            defaultPlaylist.kind = .manual
            changed = true
        }
        if defaultPlaylist.hidden {
            defaultPlaylist.hidden = false
            changed = true
        }
        if defaultPlaylist.sortIndex != 0 {
            defaultPlaylist.sortIndex = 0
            changed = true
        }
        if defaultPlaylist.smartFilter != nil {
            defaultPlaylist.smartFilter = nil
            changed = true
        }

        let duplicateCandidates = allPlaylists.filter { playlist in
            guard playlist.id != defaultPlaylist.id else { return false }
            return playlist.title == Playlist.defaultQueueTitle || isLegacyDefaultTitle(playlist.title)
        }

        var mergedEpisodeURLs = Set(defaultPlaylist.ordered.compactMap { $0.episode?.url })
        var mergedEpisodeIDs = Set(defaultPlaylist.ordered.compactMap { $0.episode?.persistentModelID })
        var nextOrder = (defaultPlaylist.ordered.map(\.order).max() ?? -1) + 1

        for duplicate in duplicateCandidates {
            for entry in duplicate.ordered {
                guard let episode = entry.episode else {
                    context.delete(entry)
                    changed = true
                    continue
                }

                let alreadyExists: Bool
                if let episodeURL = episode.url {
                    alreadyExists = mergedEpisodeURLs.contains(episodeURL) || mergedEpisodeIDs.contains(episode.persistentModelID)
                } else {
                    alreadyExists = mergedEpisodeIDs.contains(episode.persistentModelID)
                }

                if alreadyExists {
                    context.delete(entry)
                    changed = true
                    continue
                }

                entry.playlist = defaultPlaylist
                entry.order = nextOrder
                nextOrder += 1
                mergedEpisodeIDs.insert(episode.persistentModelID)
                if let episodeURL = episode.url {
                    mergedEpisodeURLs.insert(episodeURL)
                }
                changed = true
            }

            context.delete(duplicate)
            changed = true
        }

        for (index, entry) in defaultPlaylist.ordered.enumerated() {
            if entry.order != index {
                entry.order = index
                changed = true
            }
        }

        if changed {
            context.saveIfNeeded()
        }

        return defaultPlaylist
    }

    static func normalizedPlaylistName(_ raw: String?, existing: [Playlist]) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Playlist" : trimmed
        let existingNames = Set(existing.map { $0.displayTitle.lowercased() })

        if existingNames.contains(baseName.lowercased()) == false {
            return baseName
        }

        var suffix = 2
        while existingNames.contains("\(baseName) \(suffix)".lowercased()) {
            suffix += 1
        }

        return "\(baseName) \(suffix)"
    }

    static func resolvePlaylistID(from rawValue: String?) -> UUID? {
        guard let rawValue,
              let uuid = UUID(uuidString: rawValue) else {
            return nil
        }

        return uuid
    }

    enum Position: Identifiable, Codable, CaseIterable, Hashable, Sendable {
        case front
        case end
        case none

        var id: Self { self }
    }
}

@Model
class PlaylistEntry: Equatable, Identifiable {
    var id: UUID = UUID()
    @Relationship var episode: Episode?
    var dateAdded: Date?
    var order: Int = 0
    @Relationship var playlist: Playlist?

    init(episode: Episode, order: Int?) {
        self.order = order ?? 0
        self.dateAdded = Date()
        self.episode = episode
    }
}
