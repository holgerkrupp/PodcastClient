import Foundation
import SwiftData

struct TranscriptSearchBackfillReport: Sendable {
    let processedEpisodes: Int
    let indexedEpisodes: Int
    let completed: Bool
}

/// Incrementally discovers canonical transcript data without loading the whole
/// library or whole transcript collection into memory at once.
@ModelActor
actor TranscriptSearchBackfillCoordinator {
    private static let cursorKey = "transcriptSearch.backfill.cursor.v1"
    private static let batchSize = 12
    private static let defaultBudget: TimeInterval = 8

    func run(
        budget: TimeInterval = TranscriptSearchBackfillCoordinator.defaultBudget,
        batchSize: Int = TranscriptSearchBackfillCoordinator.batchSize
    ) async -> TranscriptSearchBackfillReport {
        let startedAt = Date()
        let defaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
        var cursor = max(0, defaults.integer(forKey: Self.cursorKey))
        var processed = 0
        var indexed = 0

        do {
            try await TranscriptSearchIndex.shared.setBackfillState(inProgress: true)

            while Date().timeIntervalSince(startedAt) < budget {
                try Task.checkCancellation()
                var descriptor = FetchDescriptor<Episode>(
                    sortBy: [SortDescriptor(\.publishDate, order: .reverse)]
                )
                descriptor.fetchOffset = cursor
                descriptor.fetchLimit = max(1, batchSize)
                let episodes = try modelContext.fetch(descriptor)
                guard episodes.isEmpty == false else {
                    defaults.set(0, forKey: Self.cursorKey)
                    try await TranscriptSearchIndex.shared.setBackfillState(inProgress: false)
                    return TranscriptSearchBackfillReport(
                        processedEpisodes: processed,
                        indexedEpisodes: indexed,
                        completed: true
                    )
                }

                var snapshots: [TranscriptSearchEpisodeSnapshot] = []
                snapshots.reserveCapacity(episodes.count)
                for episode in episodes {
                    try Task.checkCancellation()
                    guard let lines = episode.transcriptLines,
                          lines.isEmpty == false else {
                        cursor += 1
                        processed += 1
                        continue
                    }
                    let values = lines
                        .sorted { $0.startTime < $1.startTime }
                        .map {
                            TranscriptLineSnapshot(
                                speaker: $0.speaker,
                                text: $0.text,
                                startTime: $0.startTime,
                                endTime: $0.endTime
                            )
                        }
                    snapshots.append(
                        TranscriptSearchEpisodeSnapshot(
                            episode: episode,
                            lines: values,
                            source: transcriptSource(for: episode)
                        )
                    )
                    cursor += 1
                    processed += 1
                }

                for snapshot in snapshots {
                    try Task.checkCancellation()
                    if try await TranscriptSearchIndex.shared.upsert(snapshot) {
                        indexed += 1
                    }
                }
                defaults.set(cursor, forKey: Self.cursorKey)
                try await TranscriptSearchIndex.shared.refreshEligibleEpisodeCount()
            }

            try await TranscriptSearchIndex.shared.setBackfillState(inProgress: true)
            AppDiagnostics.log(
                "transcript_search_backfill_batch_completed processed=\(processed) indexed=\(indexed)"
            )
            return TranscriptSearchBackfillReport(
                processedEpisodes: processed,
                indexedEpisodes: indexed,
                completed: false
            )
        } catch is CancellationError {
            try? await TranscriptSearchIndex.shared.setBackfillState(inProgress: true)
            return TranscriptSearchBackfillReport(
                processedEpisodes: processed,
                indexedEpisodes: indexed,
                completed: false
            )
        } catch {
            try? await TranscriptSearchIndex.shared.setBackfillState(
                inProgress: false,
                lastError: error.localizedDescription
            )
            AppDiagnostics.log("transcript_search_backfill_failed")
            return TranscriptSearchBackfillReport(
                processedEpisodes: processed,
                indexedEpisodes: indexed,
                completed: false
            )
        }
    }

    func rebuild() async -> TranscriptSearchBackfillReport {
        try? await TranscriptSearchIndex.shared.rebuild()
        let defaults = UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
        defaults.set(0, forKey: Self.cursorKey)
        return await run(budget: .greatestFiniteMagnitude)
    }

    private func transcriptSource(for episode: Episode) -> String {
        episode.externalFiles.contains { $0.category == .transcript } ? "publisher" : "generated"
    }
}
