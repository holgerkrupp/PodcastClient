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

struct PlaylistSymbolOption: Identifiable, Hashable, Sendable {
    let symbolName: String
    let title: String

    var id: String { symbolName }
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
    case downloaded
    case language
    case duration
    case published
    case status
    case archived
    case episodeType
    case source
    case category

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
        case .downloaded: return "Downloaded"
        case .language: return "Podcast language"
        case .duration: return "Length (minutes)"
        case .published: return "Published"
        case .status: return "Listening status"
        case .archived: return "Archived"
        case .episodeType: return "Episode type"
        case .source: return "Source"
        case .category: return "Podcast category"
        }
    }
}

enum SmartPlaylistComparator: String, Codable, CaseIterable, Hashable, Sendable {
    case contains
    case equals
    case startsWith
    case endsWith
    case lessThan
    case greaterThan
    case withinLastDays

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
        case .lessThan: return "Less than"
        case .greaterThan: return "At least"
        case .withinLastDays: return "Within last days"
        }
    }
}

struct SmartPlaylistRule: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var field: SmartPlaylistField = .episodeTitle
    var comparator: SmartPlaylistComparator = .contains
    var query: String = ""
    /// Typed value storage for new predicates. Legacy text rules keep using `query`.
    var values: [String] = []

    init(
        id: UUID = UUID(),
        field: SmartPlaylistField,
        comparator: SmartPlaylistComparator = .contains,
        query: String,
        values: [String] = []
    ) {
        self.id = id
        self.field = field
        self.comparator = comparator
        self.query = query
        self.values = values
    }

    private enum CodingKeys: String, CodingKey { case id, field, comparator, query, values }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        field = try container.decodeIfPresent(SmartPlaylistField.self, forKey: .field) ?? .episodeTitle
        comparator = try container.decodeIfPresent(SmartPlaylistComparator.self, forKey: .comparator) ?? .contains
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        values = try container.decodeIfPresent([String].self, forKey: .values) ?? []
    }
}

struct SmartPlaylistFilter: Codable, Hashable, Sendable {
    var matchMode: SmartPlaylistMatchMode = .all
    var requireDownloaded: Bool = false
    var includeArchived: Bool = false
    var rules: [SmartPlaylistRule] = []
    var resultLimit: Int? = nil

    var hasRules: Bool {
        rules.contains { !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.values.isEmpty }
    }
}

@Model
class Playlist {
    static let defaultQueueTitle = "de.holgerkrupp.podbay.queue"
    /// A device-independent identity for the built-in queue in the split store.
    /// Local playlist UUIDs predate split-store sync and differ per installation.
    static let defaultQueueSyncID = "7E9C0B29-10C4-4EE1-9B8D-2FDCB6073C39"
    static let defaultQueueDisplayName = "Up Next"
    static let defaultManualSymbolName = "list.bullet"
    static let defaultQueueSymbolName = "calendar.day.timeline.leading"
    static let smartPlaylistSymbolName = "line.3.horizontal.decrease.circle"
    static let symbolOptions: [PlaylistSymbolOption] = [
        PlaylistSymbolOption(symbolName: "list.bullet", title: "List"),
        PlaylistSymbolOption(symbolName: "music.note.list", title: "Mix"),
        PlaylistSymbolOption(symbolName: "clock", title: "Later"),
        PlaylistSymbolOption(symbolName: "sparkles", title: "Highlights"),
        PlaylistSymbolOption(symbolName: "star", title: "Favorites"),
        PlaylistSymbolOption(symbolName: "heart", title: "Loved"),
        PlaylistSymbolOption(symbolName: "arrow.down.circle.fill", title: "Downloaded"),
        PlaylistSymbolOption(symbolName: "tray.and.arrow.down.fill", title: "Offline"),
        PlaylistSymbolOption(symbolName: "checkmark.circle.fill", title: "Finished"),
        PlaylistSymbolOption(symbolName: "play.circle.fill", title: "Continue"),
        PlaylistSymbolOption(symbolName: "waveform", title: "Audio"),
        PlaylistSymbolOption(symbolName: "timer", title: "Short"),
        PlaylistSymbolOption(symbolName: "calendar.badge.clock", title: "Recent"),
        PlaylistSymbolOption(symbolName: "clock.arrow.circlepath", title: "In Progress"),
        PlaylistSymbolOption(symbolName: "text.book.closed.fill", title: "Learning"),
        PlaylistSymbolOption(symbolName: "globe", title: "Language"),
        PlaylistSymbolOption(symbolName: "square.stack.3d.up.fill", title: "Categories"),
        PlaylistSymbolOption(symbolName: "bolt", title: "Quick"),
        PlaylistSymbolOption(symbolName: "flame", title: "Hot"),
        PlaylistSymbolOption(symbolName: "moon", title: "Night"),
        PlaylistSymbolOption(symbolName: "sun.max", title: "Morning"),
        PlaylistSymbolOption(symbolName: "person.2", title: "People"),
        PlaylistSymbolOption(symbolName: "briefcase", title: "Work"),
        PlaylistSymbolOption(symbolName: "car", title: "Drive"),
        PlaylistSymbolOption(symbolName: "airplane", title: "Travel"),
        PlaylistSymbolOption(symbolName: "house", title: "Home"),
        PlaylistSymbolOption(symbolName: "book", title: "Learning"),
        PlaylistSymbolOption(symbolName: "bubble.left.and.bubble.right", title: "Talk"),
        PlaylistSymbolOption(symbolName: "mic", title: "Interviews"),
        PlaylistSymbolOption(symbolName: "newspaper", title: "News"),
        PlaylistSymbolOption(symbolName: "calendar", title: "Daily"),
        PlaylistSymbolOption(symbolName: "building.columns", title: "Politics"),
        PlaylistSymbolOption(symbolName: "hammer", title: "DIY"),
        PlaylistSymbolOption(symbolName: "macbook.and.iphone", title: "Tech"),
        PlaylistSymbolOption(symbolName: "brain.head.profile", title: "Education"),
        PlaylistSymbolOption(symbolName: "soccerball", title: "Sport"),
        PlaylistSymbolOption(symbolName: "gamecontroller", title: "Games"),
        PlaylistSymbolOption(symbolName: "tv", title: "TV"),
        PlaylistSymbolOption(symbolName: "movieclapper", title: "Movies"),
        PlaylistSymbolOption(symbolName: "book.closed", title: "Books"),
        PlaylistSymbolOption(symbolName: "cross.case", title: "Medical")
        
    ]

    var title: String = ""
    var symbolName: String = Playlist.defaultManualSymbolName
    var id: UUID = UUID()
    /// The PlaylistSync identity this local projection came from. Keeping it
    /// separate from `id` lets each device retain its local navigation identity
    /// while subsequent edits continue updating the same cloud record.
    var syncID: String?
    var deleteable: Bool = true // to enable standard lists like "play next queue" or similar that can't be deleted by the user
    var hidden: Bool = false
    var sortIndex: Int = 0
    var kindRawValue: String = Kind.manual.rawValue
    var smartFilter: SmartPlaylistFilter?
    /// Keep the episodes of this playlist downloaded without waiting for the
    /// per-podcast auto-download policy, which only ever considers a show's
    /// newest or oldest unplayed episodes.
    var autoDownloadEnabled: Bool = false
    /// How many of the playlist's episodes, counted from the top, are kept
    /// downloaded. `nil` downloads every episode in the playlist.
    var autoDownloadEpisodeLimit: Int?
    /// Whether finishing an episode somewhere else also drops it from this
    /// playlist. On by default, which is how every playlist behaved before the
    /// setting existed: a played episode is not a playlist member.
    ///
    /// Turning it off lets a playlist keep an episode it shares with another
    /// playlist — a favourites or re-listen list — after it was played there.
    var removesEpisodesPlayedElsewhere: Bool = true

    @Relationship var items: [PlaylistEntry]? = [] // we need to ensure that we can create an ordered list. Swiftdata won't ensure that the items are kept in the same order without manually managing that.

    @Transient var ordered: [PlaylistEntry] {
        items?.sorted(by: { $0.order < $1.order }) ?? []
    }

    init() {
        self.title = Self.defaultQueueTitle
        self.symbolName = Self.defaultQueueSymbolName
        self.syncID = id.uuidString
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

    static let autoDownloadEpisodeLimitRange = 1...50
    static let defaultAutoDownloadEpisodeLimit = 5

    /// The limit the download policy actually applies. `nil` means "no limit",
    /// and a stored value is clamped so an out-of-range import can never make
    /// the policy download nothing at all.
    var resolvedAutoDownloadEpisodeLimit: Int? {
        guard let autoDownloadEpisodeLimit else { return nil }
        return min(
            max(autoDownloadEpisodeLimit, Self.autoDownloadEpisodeLimitRange.lowerBound),
            Self.autoDownloadEpisodeLimitRange.upperBound
        )
    }

    var displayTitle: String {
        title == Self.defaultQueueTitle ? Self.defaultQueueDisplayName : title
    }

    var displaySymbolName: String {
        if isSmartPlaylist {
            return Self.normalizedSymbolName(symbolName, fallback: Self.smartPlaylistSymbolName)
        }

        let fallback = title == Self.defaultQueueTitle ? Self.defaultQueueSymbolName : Self.defaultManualSymbolName
        return Self.normalizedSymbolName(symbolName, fallback: fallback)
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

    /// Finds the built-in queue without repairing or creating it.
    ///
    /// Background entry points such as WatchConnectivity must use this lookup
    /// rather than `ensureDefaultQueue(in:)`. The latter is intentionally a
    /// foreground maintenance routine and can merge duplicate queues, which
    /// requires walking every queue entry and its episode relationship.
    static func existingDefaultQueue(in context: ModelContext) -> Playlist? {
        let defaultQueueSyncID: String? = Self.defaultQueueSyncID
        var syncIDDescriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { playlist in
                playlist.syncID == defaultQueueSyncID
            }
        )
        syncIDDescriptor.fetchLimit = 1
        if let playlist = try? context.fetch(syncIDDescriptor).first {
            return playlist
        }

        let defaultQueueTitle = Self.defaultQueueTitle
        var reservedTitleDescriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { playlist in
                playlist.title == defaultQueueTitle
            }
        )
        reservedTitleDescriptor.fetchLimit = 1
        if let playlist = try? context.fetch(reservedTitleDescriptor).first {
            return playlist
        }

        // Older installations stored the display title directly. Keep that
        // migration compatibility without resorting to an unbounded fetch.
        let defaultQueueDisplayName = Self.defaultQueueDisplayName
        var legacyTitleDescriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { playlist in
                playlist.title == defaultQueueDisplayName
            }
        )
        legacyTitleDescriptor.fetchLimit = 1
        return try? context.fetch(legacyTitleDescriptor).first
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
        if defaultPlaylist.syncID != defaultQueueSyncID {
            defaultPlaylist.syncID = defaultQueueSyncID
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
        // Only fill in a missing icon. This runs on every launch, so matching the
        // generic list symbol here as well would make it impossible to ever pick
        // that icon for the built-in queue in playlist settings.
        if defaultPlaylist.symbolName.isEmpty {
            defaultPlaylist.symbolName = defaultQueueSymbolName
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

        // Most launches have exactly one valid queue. Do not fault every
        // queued Episode merely to prepare a duplicate-repair operation that
        // will not run. Besides avoiding needless launch work, this keeps the
        // explicit maintenance path out of Watch background refreshes.
        guard duplicateCandidates.isEmpty == false else {
            if changed {
                context.saveIfNeeded()
            }
            return defaultPlaylist
        }

        var orderedEntries = defaultPlaylist.ordered
        var mergedEpisodeURLs = Set(orderedEntries.compactMap { $0.episode?.url })
        var mergedEpisodeIDs = Set(orderedEntries.compactMap { $0.episode?.persistentModelID })
        var nextOrder = (orderedEntries.map(\.order).max() ?? -1) + 1

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
                orderedEntries.append(entry)
                mergedEpisodeIDs.insert(episode.persistentModelID)
                if let episodeURL = episode.url {
                    mergedEpisodeURLs.insert(episodeURL)
                }
                changed = true
            }

            context.delete(duplicate)
            changed = true
        }

        for (index, entry) in orderedEntries.sorted(by: { $0.order < $1.order }).enumerated() {
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

    static func normalizedSymbolName(_ raw: String?, fallback: String = defaultManualSymbolName) -> String {
        let candidate = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? fallback : candidate
    }

    static func resolvePlaylistID(from rawValue: String?) -> UUID? {
        guard let rawValue,
              let uuid = UUID(uuidString: rawValue) else {
            return nil
        }

        return uuid
    }

    @discardableResult
    static func resolvedSelectedManualPlaylistID(
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) -> UUID {
        let defaultPlaylist = ensureDefaultQueue(in: context)
        let allPlaylists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? [defaultPlaylist]
        let manualPlaylists = manualVisibleSorted(allPlaylists)
        let fallbackPlaylist = manualPlaylists.first(where: { $0.id == defaultPlaylist.id })
            ?? manualPlaylists.first
            ?? defaultPlaylist

        let storedPlaylistID = resolvePlaylistID(
            from: defaults.string(forKey: PlaylistPreferenceKeys.selectedPlaylistID)
        )
        let selectedPlaylist = storedPlaylistID.flatMap { selectedID in
            manualPlaylists.first(where: { $0.id == selectedID })
        } ?? fallbackPlaylist

        if defaults.string(forKey: PlaylistPreferenceKeys.selectedPlaylistID) != selectedPlaylist.id.uuidString {
            defaults.set(selectedPlaylist.id.uuidString, forKey: PlaylistPreferenceKeys.selectedPlaylistID)
        }

        return selectedPlaylist.id
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
    /// Queue and playlist reads are all ordered by `order`, as is the
    /// `playlist_entries` migration phase. See the note on
    /// `Episode.publishDate`.
    #Index<PlaylistEntry>([\.order])

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
