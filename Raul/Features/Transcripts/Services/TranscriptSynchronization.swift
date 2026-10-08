import Foundation
import Observation
import AVFoundation
import CryptoKit
import SwiftData
import Speech

struct TranscriptSynchronizationAnchor: Codable, Hashable, Sendable {
    let transcriptTime: TimeInterval
    let audioTime: TimeInterval
    let confidence: Double
}

struct TranscriptAudioGap: Codable, Hashable, Sendable {
    let audioStart: TimeInterval
    let audioEnd: TimeInterval
    let transcriptTime: TimeInterval
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
        for pair in zip(ordered, ordered.dropFirst()) {
            let transcriptDelta = pair.1.transcriptTime - pair.0.transcriptTime
            let audioDelta = pair.1.audioTime - pair.0.audioTime
            guard transcriptDelta > 0, audioDelta > 0 else { return nil }
            let slope = audioDelta / transcriptDelta
            guard (0.25...4).contains(slope) else { return nil }
        }
        let orderedGaps = gaps.sorted { $0.audioStart < $1.audioStart }
        guard orderedGaps.allSatisfy({
            $0.audioStart.isFinite && $0.audioEnd.isFinite && $0.transcriptTime.isFinite
                && $0.audioStart >= 0 && $0.audioEnd > $0.audioStart && $0.transcriptTime >= 0
        }), zip(orderedGaps, orderedGaps.dropFirst()).allSatisfy({ $0.audioEnd <= $1.audioStart }) else {
            return nil
        }
        self.anchors = ordered
        self.gaps = orderedGaps
    }

    func transcriptTime(forAudioTime time: TimeInterval) -> TimeInterval? {
        guard time.isFinite, time >= 0,
              gaps.contains(where: { time >= $0.audioStart && time < $0.audioEnd }) == false else {
            return nil
        }
        return interpolate(time, x: \.audioTime, y: \.transcriptTime)
    }

    func audioTime(forTranscriptTime time: TimeInterval) -> TimeInterval? {
        guard time.isFinite, time >= 0 else { return nil }
        return interpolate(time, x: \.transcriptTime, y: \.audioTime)
    }

    private func interpolate(
        _ value: TimeInterval,
        x: KeyPath<TranscriptSynchronizationAnchor, TimeInterval>,
        y: KeyPath<TranscriptSynchronizationAnchor, TimeInterval>
    ) -> TimeInterval {
        guard let first = anchors.first, let last = anchors.last else { return value }
        if value <= first[keyPath: x] {
            return value + first[keyPath: y] - first[keyPath: x]
        }
        if value >= last[keyPath: x] {
            return value + last[keyPath: y] - last[keyPath: x]
        }
        for (left, right) in zip(anchors, anchors.dropFirst()) {
            let lower = left[keyPath: x]
            let upper = right[keyPath: x]
            guard value >= lower, value <= upper else { continue }
            let fraction = (value - lower) / (upper - lower)
            return left[keyPath: y] + fraction * (right[keyPath: y] - left[keyPath: y])
        }
        return value
    }
}

struct TranscriptAlignmentCandidate: Codable, Hashable, Sendable {
    let id: String
    let transcriptTime: TimeInterval
    let text: String
    let source: CachedTranscriptSource?

    init(
        id: String = "",
        transcriptTime: TimeInterval,
        text: String,
        source: CachedTranscriptSource?
    ) {
        self.id = id
        self.transcriptTime = transcriptTime
        self.text = text
        self.source = source
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
    /// Match short ASR observations only against nearby publisher rows. A missing or
    /// ambiguous provenance is rejected before text matching.
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

        let eligible = candidates.compactMap { candidate -> (TranscriptAlignmentCandidate, Double)? in
            guard candidate.source == .publisher,
                  abs(candidate.transcriptTime - expectedTranscriptTime) <= 90,
                  let target = normalizedTokens(candidate.text),
                  informativeTokenCount(target) >= 3 else { return nil }
            let score = tokenSimilarity(observed, target)
            return (candidate, score)
        }.sorted { $0.1 > $1.1 }
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
actor TranscriptAlignmentCacheActor {
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
        cacheContainer: ModelContainer,
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
           audioTime - lastTime < 240 {
            return
        }
        lastAnalyzedAudioTime[input.episodeID] = audioTime

        for episodeID in Array(jobs.keys) where episodeID != input.episodeID {
            jobs[episodeID]?.cancel()
            jobs.removeValue(forKey: episodeID)
        }

        let cache = TranscriptAlignmentCacheActor(modelContainer: cacheContainer)
        jobs[input.episodeID] = Task { [weak self] in
            _ = await self?.run(
                input: input,
                audioTime: audioTime,
                cache: cache,
                episodeActor: episodeActor,
                settingsActor: settingsActor
            )
            await self?.finished(episodeID: input.episodeID)
        }
    }

    func runQueuedBackgroundJobs(
        episodeContainer: ModelContainer,
        cacheContainer: ModelContainer,
        episodeLimit: Int
    ) async -> Int {
        guard isEnabled, episodeLimit > 0 else { return 0 }
        let processingTask = Task { [weak self] in
            guard let self else { return 0 }
            return await self.processQueuedBackgroundJobs(
                episodeContainer: episodeContainer,
                cacheContainer: cacheContainer,
                episodeLimit: episodeLimit
            )
        }
        backgroundProcessingTask = processingTask
        let completedCount = await processingTask.value
        backgroundProcessingTask = nil
        return completedCount
    }

    private func processQueuedBackgroundJobs(
        episodeContainer: ModelContainer,
        cacheContainer: ModelContainer,
        episodeLimit: Int
    ) async -> Int {
        let queue = TranscriptAlignmentCacheActor(modelContainer: cacheContainer)
        let episodeActor = EpisodeActor(modelContainer: episodeContainer)
        let settingsActor = PodcastSettingsModelActor(modelContainer: episodeContainer)
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
                cache: queue,
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
        cache: TranscriptAlignmentCacheActor,
        sampleAcrossEpisode: Bool = false,
        episodeActor: EpisodeActor? = nil,
        settingsActor: PodcastSettingsModelActor? = nil
    ) async -> Bool {
        do {
            try Task.checkCancellation()
            let fingerprint = try mediaFingerprint(for: input.localMediaURL)
            let existing = await cache.load(
                episodeID: input.episodeID,
                mediaFingerprint: fingerprint,
                transcriptRevision: input.transcriptRevision
            )
            if let existing {
                await MainActor.run {
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
                if sampleAcrossEpisode {
                    return true
                }
            } else {
                await cache.invalidateOtherRevisions(episodeID: input.episodeID)
                await MainActor.run {
                    TranscriptSynchronizationStore.shared.removeTimeline(for: input.episodeURL)
                }
            }

            // Synchronization must never download speech assets as a side effect.
            guard let installedLocale = await AITranscripts.installedLocale(matching: input.language) else {
                return true
            }
            let duration = try TranscriptAudioSampler.duration(of: input.localMediaURL)
            let sampleCenters: [TimeInterval]
            if sampleAcrossEpisode {
                let sampleCount = min(18, max(3, Int(ceil(duration / 180))))
                sampleCenters = (0..<sampleCount).map { index in
                    duration * Double(index) / Double(max(sampleCount - 1, 1))
                }
            } else {
                sampleCenters = [audioTime - 24, audioTime, audioTime + 24]
                    .map { min(max($0, 0), max(duration - 7, 0)) }
            }
            var observedAnchors: [TranscriptSynchronizationAnchor] = []

            for center in sampleCenters {
                try Task.checkCancellation()
                guard let snippet = try? TranscriptAudioSampler.writeSnippet(
                    from: input.localMediaURL,
                    centeredAt: center,
                    duration: 7
                ) else { continue }
                defer {
                    try? FileManager.default.removeItem(at: snippet.url.deletingLastPathComponent())
                }

                let transcriber = await AITranscripts(
                    url: snippet.url,
                    language: installedLocale,
                    maxSnippetDurationSeconds: 7,
                    maxWordsPerSnippet: 30,
                    analyzerPriority: .utility,
                    allowModelDownload: false
                )
                guard let results = try? await transcriber.transcribe(),
                      results.isEmpty == false else { continue }
                let recognizedText = results.map(\.text).joined(separator: " ")
                let firstSpeechOffset = results.map { CMTimeGetSeconds($0.range.start) }
                    .filter(\.isFinite)
                    .min() ?? 0
                let actualSpeechTime = snippet.startTime + firstSpeechOffset
                let expectedTranscriptTime = existing?.transcriptTime(forAudioTime: actualSpeechTime)
                    ?? actualSpeechTime

                if let anchor = TranscriptAlignmentMatcher.match(
                    recognizedText: recognizedText,
                    actualAudioTime: actualSpeechTime,
                    candidates: input.candidates,
                    expectedTranscriptTime: expectedTranscriptTime
                ) {
                    observedAnchors.append(anchor)
                }
            }
            try Task.checkCancellation()

            let combined = Self.merge(existing?.anchors ?? [], observedAnchors)
            guard combined.count >= 3,
                  combined.map(\.confidence).reduce(0, +) / Double(combined.count) >= 0.82,
                  let timeline = TranscriptSynchronizationTimeline(
                    anchors: combined,
                    gaps: Self.inferredGaps(from: combined)
                  ) else { return sampleAcrossEpisode }

            await cache.save(
                timeline,
                episodeID: input.episodeID,
                episodeURL: input.episodeURL,
                mediaFingerprint: fingerprint,
                transcriptRevision: input.transcriptRevision
            )
            await MainActor.run {
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
            return true
        } catch is CancellationError {
            return false
        } catch {
            AppDiagnostics.log("Publisher transcript synchronization failed: \(error.localizedDescription)")
            return false
        }
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

    private static func inferredGaps(from anchors: [TranscriptSynchronizationAnchor]) -> [TranscriptAudioGap] {
        zip(anchors, anchors.dropFirst()).compactMap { left, right in
            let transcriptDelta = right.transcriptTime - left.transcriptTime
            let audioDelta = right.audioTime - left.audioTime
            let insertedDuration = audioDelta - transcriptDelta
            guard insertedDuration >= 20 else { return nil }
            let gapStart = right.audioTime - insertedDuration
            guard gapStart > left.audioTime else { return nil }
            return TranscriptAudioGap(
                audioStart: gapStart,
                audioEnd: right.audioTime,
                transcriptTime: left.transcriptTime + gapStart - left.audioTime
            )
        }
    }
}

enum TranscriptAudioSnippetError: Error {
    case invalidFormat
    case bufferAllocationFailed
    case emptySample
}

enum TranscriptAudioSampler {
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
        let totalDuration = Double(source.length) / format.sampleRate
        let actualDuration = min(max(duration, 1), totalDuration)
        guard actualDuration > 0 else { throw TranscriptAudioSnippetError.invalidFormat }
        let startTime = min(max(center - actualDuration / 2, 0), max(totalDuration - actualDuration, 0))
        let startFrame = AVAudioFramePosition((startTime * format.sampleRate).rounded(.down))
        let frameCount = AVAudioFrameCount(max(1, actualDuration * format.sampleRate))
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
            let output = try AVAudioFile(forWriting: sampleURL, settings: format.settings)
            try output.write(from: buffer)
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
