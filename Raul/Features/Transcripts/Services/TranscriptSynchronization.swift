import Foundation
import Observation
import AVFoundation
import CryptoKit
import SwiftData
import Speech
import OSLog

struct TranscriptSynchronizationAnchor: Codable, Hashable, Sendable {
    let transcriptTime: TimeInterval
    let audioTime: TimeInterval
    let confidence: Double
}

struct TranscriptAudioGap: Codable, Hashable, Sendable {
    let audioStart: TimeInterval
    let audioEnd: TimeInterval
    let transcriptTime: TimeInterval
    /// When set, speech between these transcript times has not been matched.
    /// Do not interpolate or seek inside that interval.
    var transcriptEnd: TimeInterval? = nil
}

/// A monotonic, piecewise mapping between publisher-caption time and played-audio time.
/// Transcript rows remain untouched; a gap maps to no active caption instead of advancing early.
struct TranscriptSynchronizationTimeline: Codable, Hashable, Sendable {
    let anchors: [TranscriptSynchronizationAnchor]
    let gaps: [TranscriptAudioGap]

    init?(anchors: [TranscriptSynchronizationAnchor], gaps: [TranscriptAudioGap] = []) {
        let ordered = anchors.sorted { $0.transcriptTime < $1.transcriptTime }
        guard ordered.count >= 2,
              ordered.allSatisfy({
                  $0.transcriptTime.isFinite && $0.audioTime.isFinite
                      && $0.transcriptTime >= 0 && $0.audioTime >= 0
                      && $0.confidence.isFinite && (0...1).contains($0.confidence)
              }) else { return nil }
        let orderedGaps = gaps.sorted { $0.audioStart < $1.audioStart }
        guard orderedGaps.allSatisfy({
            $0.audioStart.isFinite && $0.audioEnd.isFinite && $0.transcriptTime.isFinite
                && $0.audioStart >= 0 && $0.audioEnd > $0.audioStart && $0.transcriptTime >= 0
        }), zip(orderedGaps, orderedGaps.dropFirst()).allSatisfy({ $0.audioEnd <= $1.audioStart }) else {
            return nil
        }
        guard orderedGaps.allSatisfy({ gap in
            gap.transcriptEnd.map { $0.isFinite && $0 > gap.transcriptTime } ?? true
        }) else { return nil }
        let points = ordered.map { ($0.audioTime, $0.transcriptTime) }
            + orderedGaps.flatMap { [($0.audioStart, $0.transcriptTime), ($0.audioEnd, $0.transcriptEnd ?? $0.transcriptTime)] }
        let audioOrdered = points.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        guard zip(audioOrdered, audioOrdered.dropFirst()).allSatisfy({ left, right in
            left.1 <= right.1 && (left.0 != right.0 || left.1 == right.1)
        }) else { return nil }
        for pair in zip(ordered, ordered.dropFirst()) {
            let transcriptDelta = pair.1.transcriptTime - pair.0.transcriptTime
            let audioDelta = pair.1.audioTime - pair.0.audioTime
            guard transcriptDelta > 0, audioDelta > 0 else { return nil }
            let inserted = orderedGaps.filter {
                $0.audioStart >= pair.0.audioTime && $0.audioEnd <= pair.1.audioTime
            }.reduce(0.0) { $0 + $1.audioEnd - $1.audioStart }
            let uncertainTranscript = orderedGaps.filter {
                $0.audioStart >= pair.0.audioTime && $0.audioEnd <= pair.1.audioTime
            }.reduce(0.0) { $0 + (($1.transcriptEnd ?? $1.transcriptTime) - $1.transcriptTime) }
            let effectiveTranscript = transcriptDelta - uncertainTranscript
            if abs(effectiveTranscript) < 0.001 {
                guard abs(audioDelta - inserted) < 0.001 else { return nil }
                continue
            }
            guard effectiveTranscript > 0 else { return nil }
            let slope = (audioDelta - inserted) / effectiveTranscript
            guard (0.25...4).contains(slope) else { return nil }
        }
        self.anchors = ordered
        self.gaps = orderedGaps
    }

    func transcriptTime(forAudioTime time: TimeInterval) -> TimeInterval? {
        guard time.isFinite, time >= 0,
              let first = anchors.first, let last = anchors.last,
              time >= first.audioTime, time <= last.audioTime,
              gaps.contains(where: { time >= $0.audioStart && time < $0.audioEnd }) == false else {
            return nil
        }
        let points = anchors.map { ($0.audioTime, $0.transcriptTime) }
            + gaps.flatMap { [($0.audioStart, $0.transcriptTime), ($0.audioEnd, $0.transcriptEnd ?? $0.transcriptTime)] }
        return interpolate(time, points: points)
    }

    func audioTime(forTranscriptTime time: TimeInterval) -> TimeInterval? {
        guard time.isFinite, time >= 0, let first = anchors.first, let last = anchors.last,
              time >= first.transcriptTime, time <= last.transcriptTime else { return nil }
        if gaps.contains(where: { gap in
            guard let end = gap.transcriptEnd else { return false }
            return time > gap.transcriptTime && time < end
        }) { return nil }
        // A seek exactly at an insertion belongs to the speech after the gap.
        if let gap = gaps.last(where: { $0.transcriptEnd == nil && $0.transcriptTime == time }) {
            return gap.audioEnd
        }
        let points = anchors.map { ($0.transcriptTime, $0.audioTime) }
            + gaps.flatMap { [($0.transcriptTime, $0.audioStart), ($0.transcriptEnd ?? $0.transcriptTime, $0.audioEnd)] }
        return interpolate(time, points: points)
    }

    private func interpolate(
        _ value: TimeInterval,
        points: [(TimeInterval, TimeInterval)]
    ) -> TimeInterval {
        let ordered = points.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        guard let first = ordered.first, let last = ordered.last else { return value }
        if value <= first.0 {
            return value + first.1 - first.0
        }
        if value >= last.0 {
            return value + last.1 - last.0
        }
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            guard value >= left.0, value <= right.0, right.0 > left.0 else { continue }
            let fraction = (value - left.0) / (right.0 - left.0)
            return left.1 + fraction * (right.1 - left.1)
        }
        return value
    }
}

struct TranscriptAlignmentCandidate: Codable, Hashable, Sendable {
    let id: String
    let transcriptTime: TimeInterval
    let text: String
    let source: CachedTranscriptSource?
    let endTime: TimeInterval?
    let timedSpans: [TranscriptTimedSpan]?

    init(
        id: String = "",
        transcriptTime: TimeInterval,
        text: String,
        source: CachedTranscriptSource?,
        endTime: TimeInterval? = nil,
        timedSpans: [TranscriptTimedSpan]? = nil
    ) {
        self.id = id
        self.transcriptTime = transcriptTime
        self.text = text
        self.source = source
        self.endTime = endTime
        self.timedSpans = timedSpans
    }
}

enum TranscriptGapInference {
    /// Sparse phrase samples can confirm an offset change but cannot identify
    /// the exact insertion boundaries. Hide the unmatched interval until more
    /// evidence is available instead of stretching speech across it.
    static func infer(from anchors: [TranscriptSynchronizationAnchor]) -> [TranscriptAudioGap]? {
        let ordered = anchors.sorted { $0.transcriptTime < $1.transcriptTime }
        guard ordered.count >= 2 else { return nil }
        func offset(_ anchor: TranscriptSynchronizationAnchor) -> Double { anchor.audioTime - anchor.transcriptTime }
        var gaps: [TranscriptAudioGap] = []
        for index in 0..<(ordered.count - 1) {
            let left = ordered[index], right = ordered[index + 1]
            let jump = offset(right) - offset(left)
            guard jump >= 3 else { continue }
            guard index > 0, index + 2 < ordered.count,
                  [ordered[index - 1], left, right, ordered[index + 2]].allSatisfy({ $0.confidence >= 0.82 }),
                  abs(offset(ordered[index - 1]) - offset(left)) <= 1.5,
                  abs(offset(ordered[index + 2]) - offset(right)) <= 1.5 else { return nil }
            gaps.append(TranscriptAudioGap(audioStart: left.audioTime, audioEnd: right.audioTime,
                                           transcriptTime: left.transcriptTime, transcriptEnd: right.transcriptTime))
        }
        return gaps
    }
}

enum TranscriptSynchronizationRevision {
    static func make(candidates: [TranscriptAlignmentCandidate]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(candidates) else { return nil }
        var versioned = Data("alignment-v2:".utf8)
        versioned.append(data)
        return SHA256.hash(data: versioned).map { String(format: "%02x", $0) }.joined()
    }
}

struct TranscriptSynchronizationInput: Sendable {
    let episodeID: String
    let episodeURL: URL
    let localMediaURL: URL
    let language: String?
    let transcriptRevision: String
    let candidates: [TranscriptAlignmentCandidate]
}

struct TranscriptAlignmentMatcher {
    /// Prefer nearby rows, then widen the bounded search for large insertions.
    /// Ambiguous matches are never rescued by widening the search.
    static func match(
        recognizedText: String,
        actualAudioTime: TimeInterval,
        candidates: [TranscriptAlignmentCandidate],
        expectedTranscriptTime: TimeInterval
    ) -> TranscriptSynchronizationAnchor? {
        guard actualAudioTime.isFinite, actualAudioTime >= 0,
              expectedTranscriptTime.isFinite,
              let observed = normalizedTokens(recognizedText),
              informativeTokenCount(observed) >= 3 else { return nil }

        func ranked(within radius: TimeInterval) -> [(TranscriptAlignmentCandidate, Double)] {
            candidates.compactMap { candidate -> (TranscriptAlignmentCandidate, Double)? in
                guard candidate.source == .publisher,
                      candidate.transcriptTime.isFinite,
                      abs(candidate.transcriptTime - expectedTranscriptTime) <= radius,
                      let target = normalizedTokens(candidate.text),
                      informativeTokenCount(target) >= 3 else { return nil }
                return (candidate, tokenSimilarity(observed, target))
            }.sorted { $0.1 > $1.1 }
        }

        var eligible = ranked(within: 90)
        if eligible.first?.1 ?? 0 < 0.78 {
            eligible = ranked(within: 600)
        }
        guard let best = eligible.first, best.1 >= 0.78 else { return nil }
        if eligible.count > 1, best.1 - eligible[1].1 < 0.08 { return nil }
        return TranscriptSynchronizationAnchor(
            transcriptTime: best.0.transcriptTime,
            audioTime: actualAudioTime,
            confidence: best.1
        )
    }

    private static func normalizedTokens(_ text: String) -> [String]? {
        let tokens = text.lowercased().components(
            separatedBy: CharacterSet.alphanumerics.inverted
        ).filter { $0.isEmpty == false }
        return tokens.isEmpty ? nil : tokens
    }

    private static func informativeTokenCount(_ tokens: [String]) -> Int {
        Set(tokens.filter { $0.count > 2 && !commonWords.contains($0) }).count
    }

    private static func tokenSimilarity(_ left: [String], _ right: [String]) -> Double {
        let leftSet = Set(left)
        let rightSet = Set(right)
        let intersection = leftSet.intersection(rightSet).count
        guard intersection > 0 else { return 0 }
        let overlap = Double(intersection) / Double(max(leftSet.count, rightSet.count))
        let ordered = Double(longestCommonSubsequence(left, right)) / Double(max(left.count, right.count))
        return overlap * 0.55 + ordered * 0.45
    }

    private static func longestCommonSubsequence(_ left: [String], _ right: [String]) -> Int {
        var previous = Array(repeating: 0, count: right.count + 1)
        for lhs in left {
            var current = Array(repeating: 0, count: right.count + 1)
            for (index, rhs) in right.enumerated() {
                current[index + 1] = lhs == rhs
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return previous[right.count]
    }

    private static let commonWords: Set<String> = [
        "the", "and", "that", "this", "with", "you", "for", "are", "was", "have", "from",
        "but", "not", "what", "when", "where", "your", "our", "they", "them", "then"
    ]
}

/// Main-actor snapshot used synchronously by transcript views and seek controls.
/// Disabling it drops active mappings in the same turn; cached data can be reloaded later.
@MainActor
@Observable
final class TranscriptSynchronizationStore {
    static let shared = TranscriptSynchronizationStore()

    private(set) var isEnabled = false
    private struct Entry {
        let mediaFingerprint: String
        let transcriptRevision: String
        let timeline: TranscriptSynchronizationTimeline
    }
    private var timelinesByEpisodeKey: [String: Entry] = [:]

    private init() {}

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled == false {
            timelinesByEpisodeKey.removeAll()
        }
    }

    func install(
        _ timeline: TranscriptSynchronizationTimeline,
        episodeURL: URL,
        mediaFingerprint: String,
        transcriptRevision: String
    ) {
        timelinesByEpisodeKey[episodeURL.absoluteString] = Entry(
            mediaFingerprint: mediaFingerprint,
            transcriptRevision: transcriptRevision,
            timeline: timeline
        )
    }

    func timeline(
        for episodeURL: URL,
        mediaFingerprint: String,
        transcriptRevision: String
    ) -> TranscriptSynchronizationTimeline? {
        guard let entry = timelinesByEpisodeKey[episodeURL.absoluteString],
              entry.mediaFingerprint == mediaFingerprint,
              entry.transcriptRevision == transcriptRevision else { return nil }
        return entry.timeline
    }

    func clearActiveTimelines() {
        timelinesByEpisodeKey.removeAll()
    }

    func removeTimeline(for episodeURL: URL) {
        timelinesByEpisodeKey.removeValue(forKey: episodeURL.absoluteString)
    }

    func hasVerifiedTimeline(for episodeURL: URL?) -> Bool {
        guard isEnabled, let episodeURL else { return false }
        return timelinesByEpisodeKey[episodeURL.absoluteString] != nil
    }

    func isUnverifiedAudioTime(_ time: TimeInterval, episodeURL: URL?) -> Bool {
        guard isEnabled, time.isFinite, let episodeURL,
              let entry = timelinesByEpisodeKey[episodeURL.absoluteString] else { return false }
        guard let first = entry.timeline.anchors.first, let last = entry.timeline.anchors.last else { return true }
        if time < first.audioTime || time > last.audioTime { return true }
        return entry.timeline.gaps.contains {
            $0.transcriptEnd != nil && time >= $0.audioStart && time < $0.audioEnd
        }
    }

    func transcriptTime(forAudioTime time: TimeInterval, episodeURL: URL?) -> TimeInterval? {
        guard isEnabled, let episodeURL,
              let entry = timelinesByEpisodeKey[episodeURL.absoluteString] else { return time }
        return entry.timeline.transcriptTime(forAudioTime: time)
    }

    func audioTime(forTranscriptTime time: TimeInterval, episodeURL: URL?) -> TimeInterval? {
        guard isEnabled, let episodeURL,
              let entry = timelinesByEpisodeKey[episodeURL.absoluteString] else { return time }
        return entry.timeline.audioTime(forTranscriptTime: time)
    }
}

@ModelActor
actor TranscriptAlignmentStoreActor {
    func enqueue(episodeURL: URL) {
        let url = episodeURL.absoluteString
        let jobID = StableIdentityKey.make("publisher-transcript-sync", url)
        var descriptor = FetchDescriptor<CachedTranscriptSynchronizationJob>(
            predicate: #Predicate { $0.id == jobID }
        )
        descriptor.fetchLimit = 1
        guard (try? modelContext.fetch(descriptor).first) == nil else { return }
        modelContext.insert(CachedTranscriptSynchronizationJob(id: jobID, episodeURL: url))
        try? modelContext.save()
    }

    func pendingJobs(limit: Int) -> [URL] {
        var descriptor = FetchDescriptor<CachedTranscriptSynchronizationJob>(
            sortBy: [SortDescriptor(\.enqueuedAt)]
        )
        descriptor.fetchLimit = max(limit, 0)
        return ((try? modelContext.fetch(descriptor)) ?? []).compactMap { URL(string: $0.episodeURL) }
    }

    func removeJob(for episodeURL: URL) {
        let url = episodeURL.absoluteString
        let jobID = StableIdentityKey.make("publisher-transcript-sync", url)
        let descriptor = FetchDescriptor<CachedTranscriptSynchronizationJob>(
            predicate: #Predicate { $0.id == jobID }
        )
        for job in (try? modelContext.fetch(descriptor)) ?? [] {
            modelContext.delete(job)
        }
        try? modelContext.save()
    }

    func hasPendingJobs() -> Bool {
        var descriptor = FetchDescriptor<CachedTranscriptSynchronizationJob>()
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    func clearPendingJobs() {
        let descriptor = FetchDescriptor<CachedTranscriptSynchronizationJob>()
        for job in (try? modelContext.fetch(descriptor)) ?? [] {
            modelContext.delete(job)
        }
        try? modelContext.save()
    }

    func load(
        episodeID: String,
        mediaFingerprint: String,
        transcriptRevision: String
    ) -> TranscriptSynchronizationTimeline? {
        let key = StableIdentityKey.make(episodeID, mediaFingerprint, transcriptRevision)
        var descriptor = FetchDescriptor<CachedTranscriptAlignment>(
            predicate: #Predicate { $0.id == key }
        )
        descriptor.fetchLimit = 1
        guard let row = try? modelContext.fetch(descriptor).first,
              let anchorData = row.anchorsJSON.data(using: .utf8),
              let anchors = try? JSONDecoder().decode([TranscriptSynchronizationAnchor].self, from: anchorData),
              let gapData = row.gapsJSON.data(using: .utf8),
              let gaps = try? JSONDecoder().decode([TranscriptAudioGap].self, from: gapData) else {
            return nil
        }
        return TranscriptSynchronizationTimeline(anchors: anchors, gaps: gaps)
    }

    func invalidateOtherRevisions(episodeID: String) {
        let episodeKey = episodeID
        let descriptor = FetchDescriptor<CachedTranscriptAlignment>(
            predicate: #Predicate { $0.episodeID == episodeKey }
        )
        for stale in (try? modelContext.fetch(descriptor)) ?? [] {
            modelContext.delete(stale)
        }
        try? modelContext.save()
    }

    func save(
        _ timeline: TranscriptSynchronizationTimeline,
        episodeID: String,
        episodeURL: URL,
        mediaFingerprint: String,
        transcriptRevision: String
    ) {
        let key = StableIdentityKey.make(episodeID, mediaFingerprint, transcriptRevision)
        let episodeKey = episodeID
        let staleDescriptor = FetchDescriptor<CachedTranscriptAlignment>(
            predicate: #Predicate { $0.episodeID == episodeKey && $0.id != key }
        )
        for stale in (try? modelContext.fetch(staleDescriptor)) ?? [] {
            modelContext.delete(stale)
        }

        let rowDescriptor = FetchDescriptor<CachedTranscriptAlignment>(
            predicate: #Predicate { $0.id == key }
        )
        let row = (try? modelContext.fetch(rowDescriptor).first)
            ?? CachedTranscriptAlignment(
                id: key,
                episodeID: episodeID,
                episodeURL: episodeURL.absoluteString,
                mediaFingerprint: mediaFingerprint,
                transcriptRevision: transcriptRevision,
                anchorsJSON: "[]",
                gapsJSON: "[]"
            )
        if row.modelContext == nil { modelContext.insert(row) }
        row.episodeURL = episodeURL.absoluteString
        row.mediaFingerprint = mediaFingerprint
        row.transcriptRevision = transcriptRevision
        row.anchorsJSON = Self.jsonString(timeline.anchors)
        row.gapsJSON = Self.jsonString(timeline.gaps)
        row.updatedAt = .now
        try? modelContext.save()
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

/// Compatibility name for existing test fixtures; production callers use the
/// SharedDatabase-backed `TranscriptAlignmentStoreActor` above.
typealias TranscriptAlignmentCacheActor = TranscriptAlignmentStoreActor

actor TranscriptSynchronizationService {
    static let shared = TranscriptSynchronizationService()

    private var isEnabled = false
    private var jobs: [String: Task<Void, Never>] = [:]
    private var backgroundProcessingTask: Task<Int, Never>?
    private var lastAnalyzedAudioTime: [String: TimeInterval] = [:]
    private var cachedFingerprints: [String: (size: Int64, modifiedAt: Date?, digest: String)] = [:]

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard enabled == false else { return }
        jobs.values.forEach { $0.cancel() }
        jobs.removeAll()
        backgroundProcessingTask?.cancel()
        backgroundProcessingTask = nil
        lastAnalyzedAudioTime.removeAll()
    }

    func cancelAll() {
        jobs.values.forEach { $0.cancel() }
        jobs.removeAll()
        backgroundProcessingTask?.cancel()
        backgroundProcessingTask = nil
        lastAnalyzedAudioTime.removeAll()
    }

    func schedule(
        input: TranscriptSynchronizationInput,
        audioTime: TimeInterval,
        libraryContainer: ModelContainer,
        episodeActor: EpisodeActor?,
        settingsActor: PodcastSettingsModelActor?
    ) {
        guard isEnabled,
              audioTime.isFinite, audioTime >= 0,
              input.candidates.count >= 3,
              input.candidates.allSatisfy({ $0.source == .publisher }),
              jobs[input.episodeID] == nil else { return }

        if let lastTime = lastAnalyzedAudioTime[input.episodeID],
           audioTime >= lastTime,
           audioTime - lastTime < 15 {
            return
        }
        lastAnalyzedAudioTime[input.episodeID] = audioTime

        for episodeID in Array(jobs.keys) where episodeID != input.episodeID {
            jobs[episodeID]?.cancel()
            jobs.removeValue(forKey: episodeID)
        }

        let alignmentStore = TranscriptAlignmentStoreActor(modelContainer: libraryContainer)
        jobs[input.episodeID] = Task { [weak self] in
            _ = await self?.run(
                input: input,
                audioTime: audioTime,
                alignmentStore: alignmentStore,
                episodeActor: episodeActor,
                settingsActor: settingsActor
            )
            await self?.finished(episodeID: input.episodeID)
        }
    }

    func runQueuedBackgroundJobs(
        libraryContainer: ModelContainer,
        episodeLimit: Int
    ) async -> Int {
        guard isEnabled, episodeLimit > 0 else { return 0 }
        let processingTask = Task { [weak self] in
            guard let self else { return 0 }
            return await self.processQueuedBackgroundJobs(
                libraryContainer: libraryContainer,
                episodeLimit: episodeLimit
            )
        }
        backgroundProcessingTask = processingTask
        let completedCount = await processingTask.value
        backgroundProcessingTask = nil
        return completedCount
    }

    private func processQueuedBackgroundJobs(
        libraryContainer: ModelContainer,
        episodeLimit: Int
    ) async -> Int {
        let queue = TranscriptAlignmentStoreActor(modelContainer: libraryContainer)
        let episodeActor = EpisodeActor(modelContainer: libraryContainer)
        let settingsActor = PodcastSettingsModelActor(modelContainer: libraryContainer)
        let pendingURLs = await queue.pendingJobs(limit: episodeLimit)
        var completedCount = 0

        for episodeURL in pendingURLs {
            guard isEnabled, Task.isCancelled == false else { break }
            guard let input = await episodeActor.transcriptSynchronizationInput(for: episodeURL) else {
                // No downloaded publisher transcript is available. Playback
                // analysis remains a fallback if one is imported later.
                await queue.removeJob(for: episodeURL)
                continue
            }

            let completed = await run(
                input: input,
                audioTime: 0,
                alignmentStore: queue,
                sampleAcrossEpisode: true,
                episodeActor: episodeActor,
                settingsActor: settingsActor
            )
            guard Task.isCancelled == false else { break }
            if completed {
                await queue.removeJob(for: episodeURL)
                completedCount += 1
            }
        }
        return completedCount
    }

    private func finished(episodeID: String) {
        jobs.removeValue(forKey: episodeID)
    }

    private func mediaFingerprint(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let fileSize = values.fileSize else { throw TranscriptAudioSnippetError.invalidFormat }
        let key = url.standardizedFileURL.path
        if let cached = cachedFingerprints[key],
           cached.size == Int64(fileSize),
           cached.modifiedAt == values.contentModificationDate {
            return cached.digest
        }
        let digest = try TranscriptMediaFingerprint.make(for: url)
        cachedFingerprints[key] = (Int64(fileSize), values.contentModificationDate, digest)
        return digest
    }

    private func run(
        input: TranscriptSynchronizationInput,
        audioTime: TimeInterval,
        alignmentStore: TranscriptAlignmentStoreActor,
        sampleAcrossEpisode: Bool = false,
        episodeActor: EpisodeActor? = nil,
        settingsActor: PodcastSettingsModelActor? = nil
    ) async -> Bool {
        do {
            try Task.checkCancellation()
            let fingerprint = try mediaFingerprint(for: input.localMediaURL)
            let existing = await alignmentStore.load(
                episodeID: input.episodeID,
                mediaFingerprint: fingerprint,
                transcriptRevision: input.transcriptRevision
            )
            if let existing {
                await MainActor.run {
                    guard Player.shared.isPlayingTranscriptMedia(episodeURL: input.episodeURL, localMediaURL: input.localMediaURL) else { return }
                    TranscriptSynchronizationStore.shared.install(
                        existing,
                        episodeURL: input.episodeURL,
                        mediaFingerprint: fingerprint,
                        transcriptRevision: input.transcriptRevision
                    )
                }
                await materializeGapChaptersIfEnabled(
                    existing,
                    input: input,
                    fingerprint: fingerprint,
                    episodeActor: episodeActor,
                    settingsActor: settingsActor
                )
                if sampleAcrossEpisode,
                   let duration = try? TranscriptAudioSampler.duration(of: input.localMediaURL),
                   let first = existing.anchors.first, let last = existing.anchors.last,
                   first.audioTime <= 30, last.audioTime >= duration - 30,
                   existing.gaps.allSatisfy({ gap in gap.transcriptEnd.map { $0 - gap.transcriptTime <= 7 } ?? true }) {
                    return true
                }
            } else {
                await alignmentStore.invalidateOtherRevisions(episodeID: input.episodeID)
                await MainActor.run {
                    TranscriptSynchronizationStore.shared.removeTimeline(for: input.episodeURL)
                }
            }

            // Synchronization must never download speech assets as a side effect.
            guard let installedLocale = await AITranscripts.installedLocale(matching: input.language) else {
                return false
            }
            let duration = try TranscriptAudioSampler.duration(of: input.localMediaURL)
            let sampleCenters: [TimeInterval]
            if sampleAcrossEpisode {
                let sampleCount = min(18, max(3, Int(ceil(duration / 180))))
                sampleCenters = (0..<sampleCount).map { index in
                    duration * Double(index) / Double(max(sampleCount - 1, 1))
                }
            } else {
                sampleCenters = [audioTime - 48, audioTime - 24, audioTime, audioTime + 24, audioTime + 48]
                    .map { min(max($0, 0), max(duration - 7, 0)) }
                    .reduce(into: []) { result, center in
                        if !result.contains(where: { abs($0 - center) < 1 }) { result.append(center) }
                    }
            }
            var observedAnchors: [TranscriptSynchronizationAnchor] = []

            for center in sampleCenters {
                try Task.checkCancellation()
                if let anchor = try await sampleAnchor(input: input, center: center, locale: installedLocale, existing: existing) {
                    observedAnchors.append(anchor)
                }
            }
            try Task.checkCancellation()

            var combined = Self.merge(existing?.anchors ?? [], observedAnchors)
            // Narrow a corroborated offset transition with a few more bounded
            // samples. Unmatched audio remains explicitly unverified.
            if let preliminaryGaps = TranscriptGapInference.infer(from: combined) {
                var budget = 4
                for gap in preliminaryGaps where budget > 0 {
                    guard let transcriptEnd = gap.transcriptEnd else { continue }
                    var low = gap.audioStart, high = gap.audioEnd
                    let leftOffset = gap.audioStart - gap.transcriptTime
                    let rightOffset = gap.audioEnd - transcriptEnd
                    for fraction in [0.5, 0.25, 0.75, 0.125] where budget > 0 && high - low > 7 {
                        let center = low + (high - low) * fraction
                        budget -= 1
                        try Task.checkCancellation()
                        guard let anchor = try await sampleAnchor(input: input, center: center, locale: installedLocale, existing: existing),
                              anchor.confidence >= 0.9,
                              anchor.transcriptTime > gap.transcriptTime,
                              anchor.transcriptTime < transcriptEnd else { continue }
                        let offset = anchor.audioTime - anchor.transcriptTime
                        if abs(offset - leftOffset) <= 1.5 {
                            low = max(low, anchor.audioTime)
                        } else if abs(offset - rightOffset) <= 1.5 {
                            high = min(high, anchor.audioTime)
                        } else { continue }
                        observedAnchors.append(anchor)
                    }
                }
                combined = Self.merge(existing?.anchors ?? [], observedAnchors)
            }
            guard combined.count >= 3,
                  combined.map(\.confidence).reduce(0, +) / Double(combined.count) >= 0.82,
                  let gaps = TranscriptGapInference.infer(from: combined),
                  let timeline = TranscriptSynchronizationTimeline(
                    anchors: combined,
                    gaps: gaps
                  ) else { return false }

            await alignmentStore.save(
                timeline,
                episodeID: input.episodeID,
                episodeURL: input.episodeURL,
                mediaFingerprint: fingerprint,
                transcriptRevision: input.transcriptRevision
            )
            await MainActor.run {
                guard Player.shared.isPlayingTranscriptMedia(episodeURL: input.episodeURL, localMediaURL: input.localMediaURL) else { return }
                TranscriptSynchronizationStore.shared.install(
                    timeline,
                    episodeURL: input.episodeURL,
                    mediaFingerprint: fingerprint,
                    transcriptRevision: input.transcriptRevision
                )
            }
            await materializeGapChaptersIfEnabled(
                timeline,
                input: input,
                fingerprint: fingerprint,
                episodeActor: episodeActor,
                settingsActor: settingsActor
            )
            if sampleAcrossEpisode, let first = timeline.anchors.first, let last = timeline.anchors.last {
                return first.audioTime <= 30 && last.audioTime >= duration - 30
                    && timeline.gaps.allSatisfy { gap in gap.transcriptEnd.map { $0 - gap.transcriptTime <= 7 } ?? true }
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            AppDiagnostics.log("Publisher transcript synchronization failed: \(error.localizedDescription)")
            return false
        }
    }

    private func sampleAnchor(input: TranscriptSynchronizationInput, center: TimeInterval, locale: String,
                              existing: TranscriptSynchronizationTimeline?) async throws -> TranscriptSynchronizationAnchor? {
        try Task.checkCancellation()
        guard let snippet = try? TranscriptAudioSampler.writeSnippet(from: input.localMediaURL, centeredAt: center, duration: 7) else { return nil }
        defer { try? FileManager.default.removeItem(at: snippet.url.deletingLastPathComponent()) }
        let transcriber = await AITranscripts(url: snippet.url, language: locale, maxSnippetDurationSeconds: 7,
            maxWordsPerSnippet: 30, analyzerPriority: .utility, allowModelDownload: false,
            modelRetention: .lingering, diagnosticPurpose: "publisher_sync")
        guard let results = try? await transcriber.transcribe(), !results.isEmpty else {
            try Task.checkCancellation()
            return nil
        }
        let firstOffset = results.map { CMTimeGetSeconds($0.range.start) }.filter(\.isFinite).min() ?? 0
        let actualTime = snippet.startTime + firstOffset
        let expected = existing?.transcriptTime(forAudioTime: actualTime) ?? actualTime
        return TranscriptAlignmentMatcher.match(recognizedText: results.map(\.text).joined(separator: " "),
            actualAudioTime: actualTime, candidates: input.candidates, expectedTranscriptTime: expected)
    }

    private func materializeGapChaptersIfEnabled(
        _ timeline: TranscriptSynchronizationTimeline,
        input: TranscriptSynchronizationInput,
        fingerprint: String,
        episodeActor: EpisodeActor?,
        settingsActor: PodcastSettingsModelActor?
    ) async {
        guard await settingsActor?.getCreateTranscriptGapChaptersEnabled() == true,
              let episodeActor else { return }
        let updated = await episodeActor.updateTranscriptGapChapters(
            for: input.episodeURL,
            gaps: timeline.gaps,
            audioVariantID: fingerprint
        )
        if updated {
            await MainActor.run {
                Player.shared.refreshChaptersAfterTranscriptGapUpdate(for: input.episodeURL)
            }
        }
    }

    private static func merge(
        _ existing: [TranscriptSynchronizationAnchor],
        _ incoming: [TranscriptSynchronizationAnchor]
    ) -> [TranscriptSynchronizationAnchor] {
        var bestByTranscriptTime: [Int: TranscriptSynchronizationAnchor] = [:]
        for anchor in existing + incoming {
            let key = Int((anchor.transcriptTime * 2).rounded())
            if let current = bestByTranscriptTime[key], current.confidence >= anchor.confidence { continue }
            bestByTranscriptTime[key] = anchor
        }
        let ordered = bestByTranscriptTime.values.sorted { $0.transcriptTime < $1.transcriptTime }
        var monotonic: [TranscriptSynchronizationAnchor] = []
        for anchor in ordered {
            if let last = monotonic.last,
               anchor.audioTime <= last.audioTime || anchor.transcriptTime <= last.transcriptTime {
                continue
            }
            monotonic.append(anchor)
        }
        return monotonic
    }

}

enum TranscriptAudioSnippetError: Error {
    case invalidFormat
    case bufferAllocationFailed
    case emptySample
    case durationLimitExceeded
}

enum TranscriptAudioSampler {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PodcastClient", category: "TranscriptionIO")
    private static let maximumSnippetDuration: TimeInterval = 7

    struct Snippet: Sendable {
        let url: URL
        let startTime: TimeInterval
    }

    static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { throw TranscriptAudioSnippetError.invalidFormat }
        return Double(file.length) / sampleRate
    }

    static func writeSnippet(
        from sourceURL: URL,
        centeredAt center: TimeInterval,
        duration: TimeInterval = 7
    ) throws -> Snippet {
        let source = try AVAudioFile(forReading: sourceURL)
        let format = source.processingFormat
        guard format.sampleRate > 0, source.length > 0 else {
            throw TranscriptAudioSnippetError.invalidFormat
        }
        guard duration.isFinite, duration > 0, duration <= maximumSnippetDuration else {
            throw TranscriptAudioSnippetError.durationLimitExceeded
        }
        let totalDuration = Double(source.length) / format.sampleRate
        let actualDuration = min(duration, totalDuration)
        guard actualDuration > 0 else { throw TranscriptAudioSnippetError.invalidFormat }
        let startTime = min(max(center - actualDuration / 2, 0), max(totalDuration - actualDuration, 0))
        let startFrame = AVAudioFramePosition((startTime * format.sampleRate).rounded(.down))
        let frameCount = AVAudioFrameCount(max(1, actualDuration * format.sampleRate))
        let estimatedPCMBytes = Int64(frameCount) * Int64(format.channelCount) * Int64(MemoryLayout<Float>.size)
        // The sampler is intentionally bounded to one seven-second float PCM buffer.
        // Refuse malformed media formats rather than allocating an unexpectedly large buffer.
        guard estimatedPCMBytes <= 16 * 1_024 * 1_024 else {
            throw TranscriptAudioSnippetError.bufferAllocationFailed
        }
        source.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TranscriptAudioSnippetError.bufferAllocationFailed
        }
        try source.read(into: buffer, frameCount: frameCount)
        guard buffer.frameLength > 0 else { throw TranscriptAudioSnippetError.emptySample }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TranscriptSync-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sampleURL = folder.appendingPathComponent("sample.caf")
        do {
            // Speech needs 16 kHz mono at most. The source format wrote up to about
            // 2.5 MB per snippet, or 44 MB of temporary files per episode.
            let outputRate = min(format.sampleRate, 16_000)
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputRate,
                channels: 1,
                interleaved: false
            ), let converter = AVAudioConverter(from: format, to: outputFormat),
               let converted = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputRate / format.sampleRate) + 1_024)
               ) else {
                throw TranscriptAudioSnippetError.invalidFormat
            }
            var didSupplyInput = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                guard didSupplyInput == false else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                didSupplyInput = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if let conversionError { throw conversionError }
            guard status != .error else { throw TranscriptAudioSnippetError.invalidFormat }
            let output = try AVAudioFile(
                forWriting: sampleURL,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: outputRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try output.write(from: converted)
            Self.logger.info("publisher_sync_snippet_written duration_seconds=\(Double(buffer.frameLength) / format.sampleRate, format: .fixed(precision: 2)) estimated_pcm_bytes=\(estimatedPCMBytes)")
            return Snippet(url: sampleURL, startTime: startTime)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

enum TranscriptMediaFingerprint {
    static func make(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            guard chunk.isEmpty == false else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
