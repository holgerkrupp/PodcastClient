import Foundation

/// Precomputed seek targets for chapter runs that the listener disabled.
///
/// Keeping this plan in memory lets the player's boundary callback seek immediately,
/// rather than fetching every chapter from SwiftData as playback crosses its start.
struct ChapterSkipPlan: Equatable {
    struct Entry {
        let id: UUID?
        let start: TimeInterval
        let shouldPlay: Bool
    }

    struct Segment: Equatable {
        let start: TimeInterval
        let resumeAt: TimeInterval?
        let chapterIDs: [UUID]

        func contains(_ position: TimeInterval) -> Bool {
            position >= start && (resumeAt.map { position < $0 } ?? true)
        }
    }

    let segments: [Segment]

    init(entries: [Entry]) {
        let chapters = entries
            .filter { $0.start.isFinite && $0.start >= 0 }
            .sorted { $0.start < $1.start }

        var result: [Segment] = []
        var index = 0
        while index < chapters.count {
            guard chapters[index].shouldPlay == false else {
                index += 1
                continue
            }

            let start = chapters[index].start
            var skippedIDs: [UUID] = []
            while index < chapters.count, chapters[index].shouldPlay == false {
                if let id = chapters[index].id {
                    skippedIDs.append(id)
                }
                index += 1
            }

            result.append(Segment(
                start: start,
                resumeAt: index < chapters.count ? chapters[index].start : nil,
                chapterIDs: skippedIDs
            ))
        }
        segments = result
    }

    var boundaryTimes: [TimeInterval] {
        segments.map(\.start)
    }

    func segment(at position: TimeInterval) -> Segment? {
        segments.last { $0.start <= position && $0.contains(position) }
    }
}
