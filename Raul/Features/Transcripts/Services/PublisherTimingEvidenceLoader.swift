import Foundation

extension Notification.Name {
    /// Posted on the main actor after new publisher word timing was merged into the
    /// overlay cache. `userInfo[PublisherTimingEvidenceLoader.episodeURLKey]` is the
    /// episode URL (`URL`). Observers reload evidence with ``PublisherTimingEvidenceLoader``.
    static let publisherTranscriptTimingDidChange = Notification.Name("publisherTranscriptTimingDidChange")
}

/// Reads verified publisher word timing for playback UI (#492). Read-only: never
/// writes the overlay cache or starts Speech work.
enum PublisherTimingEvidenceLoader {
    static let episodeURLKey = "episodeURL"

    /// Returns cached word timing for `audioWindow`, keyed to the document's episode,
    /// the media's bounded fingerprint and the transcript revision, so
    /// `TranscriptPresentationSnapshot.resolve` rejects it if any of them changes.
    /// Pass `evidence.mediaFingerprint` as `resolve`'s `mediaFingerprint` only when it
    /// still describes the media being shown.
    nonisolated static func load(
        document: TranscriptDocumentSnapshot,
        episodeURL: URL,
        localMediaURL: URL,
        audioWindow: Range<TimeInterval>,
        service: TranscriptSynchronizationService = .shared,
        cache: PublisherTranscriptTimingOverlayCache = .shared
    ) async -> PublisherTranscriptTimingEvidence? {
        guard document.source == .publisher, let revision = document.timingRevision, !revision.isEmpty,
              !document.episodeID.isEmpty, !audioWindow.isEmpty,
              audioWindow.lowerBound.isFinite, audioWindow.upperBound.isFinite,
              localMediaURL.isFileURL, FileManager.default.fileExists(atPath: localMediaURL.path),
              let fingerprint = try? await service.boundedFingerprint(for: localMediaURL) else { return nil }
        let key = PublisherTranscriptTimingOverlay.Key(episodeID: document.episodeID, mediaFingerprint: fingerprint,
                                                       transcriptRevision: revision)
        guard let mappings = try? await cache.mappings(for: key, in: audioWindow), !Task.isCancelled else { return nil }
        let wordsByLine = wordsByLine(from: mappings, lineIDs: Set(document.lines.map(\.id)))
        guard !wordsByLine.isEmpty else { return nil }
        // Optional: the verified timeline is only reused when it is already in memory.
        var timeline: TranscriptSynchronizationTimeline?
        if let full = await service.cachedFullFingerprint(for: localMediaURL) {
            timeline = await MainActor.run {
                TranscriptSynchronizationStore.shared.timeline(for: episodeURL, mediaFingerprint: full,
                                                               transcriptRevision: revision)
            }
        }
        return PublisherTranscriptTimingEvidence(episodeID: document.episodeID, mediaFingerprint: fingerprint,
                                                 transcriptRevision: revision, timeline: timeline,
                                                 wordsByLine: wordsByLine)
    }

    /// Groups cache mappings by line, ordered by offset, dropping lines the document lacks.
    nonisolated static func wordsByLine(
        from mappings: [PublisherTranscriptTimingOverlay.Mapping],
        lineIDs: Set<UUID>
    ) -> [UUID: [TranscriptTimedSpan]] {
        var result: [UUID: [TranscriptTimedSpan]] = [:]
        for mapping in mappings where lineIDs.contains(mapping.lineID) {
            result[mapping.lineID, default: []].append(TranscriptTimedSpan(
                location: mapping.location, length: mapping.length,
                startTime: mapping.audioStart, endTime: mapping.audioEnd))
        }
        for id in result.keys { result[id]?.sort { ($0.location, $0.startTime) < ($1.location, $1.startTime) } }
        return result
    }
}
