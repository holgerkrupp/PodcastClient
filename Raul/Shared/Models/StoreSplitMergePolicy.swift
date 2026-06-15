import Foundation

enum StoreSplitUpsertDecision: Equatable {
    case insert
    case keepExisting
    case replaceExisting
}

enum StoreSplitMergePolicy {
    static func upsertDecision(
        existingUpdatedAt: Date?,
        incomingUpdatedAt: Date?
    ) -> StoreSplitUpsertDecision {
        guard existingUpdatedAt != nil else { return .insert }
        return prefersIncoming(
            existingUpdatedAt: existingUpdatedAt,
            incomingUpdatedAt: incomingUpdatedAt
        ) ? .replaceExisting : .keepExisting
    }

    static func prefersIncoming(existingUpdatedAt: Date?, incomingUpdatedAt: Date?) -> Bool {
        switch (existingUpdatedAt, incomingUpdatedAt) {
        case (nil, nil):
            return false
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (existing?, incoming?):
            return incoming > existing
        }
    }
}

struct EpisodePlaybackStateValue: Equatable, Sendable {
    var playPosition: Double
    var maxPlayPosition: Double
    var isPlayed: Bool
    var isArchived: Bool

    static let empty = EpisodePlaybackStateValue(
        playPosition: 0,
        maxPlayPosition: 0,
        isPlayed: false,
        isArchived: false
    )
}

enum EpisodePlaybackStateLookup {
    static func resolve(
        synced: EpisodePlaybackStateValue?,
        legacy: EpisodePlaybackStateValue?
    ) -> EpisodePlaybackStateValue {
        synced ?? legacy ?? .empty
    }
}

struct QueueEntryValue: Equatable, Sendable {
    var id: String
    var sortIndex: Int
    var updatedAt: Date
}

enum QueueEntryOrdering {
    static func activeSorted(_ entries: [QueueEntryValue]) -> [QueueEntryValue] {
        entries.sorted {
            if $0.sortIndex != $1.sortIndex {
                return $0.sortIndex < $1.sortIndex
            }
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.id < $1.id
        }
    }

    static func reindexed(
        _ entries: [QueueEntryValue],
        movingID: String,
        to targetIndex: Int
    ) -> [QueueEntryValue] {
        var sorted = activeSorted(entries)
        guard let sourceIndex = sorted.firstIndex(where: { $0.id == movingID }) else {
            return sorted
        }

        let entry = sorted.remove(at: sourceIndex)
        let clampedIndex = max(0, min(targetIndex, sorted.count))
        sorted.insert(entry, at: clampedIndex)

        for index in sorted.indices {
            sorted[index].sortIndex = index
        }
        return sorted
    }
}
