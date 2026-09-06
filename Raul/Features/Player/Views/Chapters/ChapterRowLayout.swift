import Foundation
import SwiftData

/// The per-row values `ChapterListView` draws, derived in a single pass.
///
/// These used to be computed inside the `ForEach` body, and each one re-entered
/// `displayedMarkers` — a filter plus a sort over the episode's whole chapter
/// list. A row needed several (current chapter, background progress, end time,
/// "is this the last row"), so drawing an n-chapter list cost O(n² log n)
/// SwiftData property reads. `Marker.start` is an accessor, not a stored-property
/// read: it boxes through `Any` and does a dynamic cast whose conformance lookup
/// can fall through to dyld's on-disk table. On a long chapter list that
/// exhausted the 10-second scene-update watchdog and the app was killed with
/// `0x8BADF00D`.
///
/// Deriving the rows once — and reading each marker property once while doing it
/// — makes drawing linear in the number of chapters.
@available(iOS 17.0, macOS 14.0, *)
struct ChapterRowLayout: Identifiable {
    let marker: Marker
    /// The chapter containing the current play position.
    let isCurrent: Bool
    /// Horizontal fill of the row's progress background, 0...1.
    let backgroundProgress: Double
    let isLast: Bool

    var id: Marker.ID { marker.id }

    /// - Parameters:
    ///   - markers: already filtered and sorted by start time.
    ///   - playPosition: nil when the episode has no position to show.
    ///   - hasPlaybackHistory: gates the per-chapter progress shown on rows that
    ///     are not the current one.
    ///   - episodeDuration: end time for the last chapter, which has no successor.
    static func rows(
        markers: [Marker],
        playPosition: Double?,
        hasPlaybackHistory: Bool,
        episodeDuration: Double?
    ) -> [ChapterRowLayout] {
        guard markers.isEmpty == false else { return [] }

        // One read per marker, rather than one per comparison and per row.
        let starts = markers.map(\.start)
        let lastIndex = markers.index(before: markers.endIndex)
        let currentIndex: Int? = playPosition.flatMap { position in
            starts.lastIndex { ($0 ?? 0) <= position }
        }

        return markers.indices.map { index in
            ChapterRowLayout(
                marker: markers[index],
                isCurrent: index == currentIndex,
                backgroundProgress: backgroundProgress(
                    at: index,
                    in: markers,
                    starts: starts,
                    currentIndex: currentIndex,
                    playPosition: playPosition,
                    hasPlaybackHistory: hasPlaybackHistory,
                    episodeDuration: episodeDuration
                ),
                isLast: index == lastIndex
            )
        }
    }

    private static func backgroundProgress(
        at index: Int,
        in markers: [Marker],
        starts: [Double?],
        currentIndex: Int?,
        playPosition: Double?,
        hasPlaybackHistory: Bool,
        episodeDuration: Double?
    ) -> Double {
        guard index == currentIndex else {
            guard hasPlaybackHistory else { return 0.0 }
            return clamped(markers[index].progress)
        }

        guard let playPosition, let start = starts[index] else { return 0.0 }
        let end = endTime(
            at: index,
            in: markers,
            starts: starts,
            start: start,
            episodeDuration: episodeDuration
        )
        guard end > start else { return 0.0 }

        return (min(max(playPosition, start), end) - start) / (end - start)
    }

    /// A chapter's own end, else the next chapter's start, else the episode's
    /// duration. Only the current row needs this, so `Marker.end` — three more
    /// SwiftData reads of its own — is never touched for the other rows.
    private static func endTime(
        at index: Int,
        in markers: [Marker],
        starts: [Double?],
        start: Double,
        episodeDuration: Double?
    ) -> Double {
        if let end = markers[index].end {
            return end
        }

        let next = index + 1
        if next < markers.count, let nextStart = starts[next] {
            return nextStart
        }

        return episodeDuration ?? start
    }

    private static func clamped(_ progress: Double?) -> Double {
        guard let progress, progress.isFinite else { return 0.0 }
        return min(max(progress, 0.0), 1.0)
    }
}
