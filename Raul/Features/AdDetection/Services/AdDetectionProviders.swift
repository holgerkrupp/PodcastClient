import Foundation
import AVFoundation
#if canImport(FoundationModels)
import FoundationModels
#endif

protocol AdTranscriptProvider: Sendable {
    func lines(for request: AdDetectionRequest) async throws -> [TranscriptDetectionLine]
}

/// Existing transcript text is always preferred. This keeps rolling detection
/// cheap and prevents a complete episode transcription just to classify one
/// upcoming window.
struct RollingSpeechTranscriptProvider: AdTranscriptProvider, Sendable {
    let existingLines: [TranscriptDetectionLine]

    init(existingLines: [TranscriptDetectionLine] = []) {
        self.existingLines = existingLines.sorted { $0.start < $1.start }
    }

    func lines(for request: AdDetectionRequest) async throws -> [TranscriptDetectionLine] {
        let requested = existingLines.filter { $0.range.overlaps(request.range, tolerance: 0.1) }
        if requested.isEmpty == false || request.mediaURL.isFileURL == false {
            return requested
        }

        // Use the same SpeechTranscriber implementation as the full transcript
        // pipeline, but feed it a bounded temporary audio window.
        let snippetURL = try await AudioSnippetWriter.makeSnippet(
            from: request.mediaURL,
            range: request.range
        )
        defer { try? FileManager.default.removeItem(at: snippetURL) }

        let transcriber = await AITranscripts(
            url: snippetURL,
            language: request.languageIdentifier,
            maxSnippetDurationSeconds: 2.5,
            maxWordsPerSnippet: 12,
            analyzerPriority: .utility,
            throttle: .backgroundFriendly
        )
        guard let results = try await transcriber.transcribe() else { return [] }
        return results.compactMap { result in
            let start = CMTimeGetSeconds(result.range.start) + request.range.start
            let end = CMTimeGetSeconds(result.range.end) + request.range.start
            guard start.isFinite, end.isFinite, end >= start else { return nil }
            return TranscriptDetectionLine(text: result.text, start: start, end: end)
        }
    }
}

struct TranscriptAdvertisementSignalProvider: AdSignalProvider {
    let transcriptProvider: any AdTranscriptProvider
    let source: AdSignalSource = .transcript

    func observations(for request: AdDetectionRequest) async throws -> [AdDetectionObservation] {
        let lines = try await transcriptProvider.lines(for: request)
        return lines.compactMap { line in
            let normalized = line.text.lowercased()
            let matches = [
                "sponsored by", "this episode is brought to you", "use code", "promo code",
                "go to", "visit", "get twenty percent", "get 20%", "support for this show"
            ].filter { normalized.contains($0) }
            guard matches.isEmpty == false else { return nil }
            let confidence = min(0.82, 0.48 + Double(matches.count) * 0.09)
            return AdDetectionObservation(
                source: source,
                range: line.range,
                confidence: confidence,
                explanation: "Advertising language: \(matches.joined(separator: ", "))"
            )
        }
    }
}

struct AdSemanticAssessment: Codable, Equatable, Sendable {
    enum Label: String, Codable, Sendable {
        case editorial
        case advertisement
        case uncertain
    }

    let label: Label
    let confidence: Double
    let startHint: TimeInterval?
    let endHint: TimeInterval?
    let explanation: String
}

actor AdvertisementSemanticClassifier {
    private var cache: [String: AdSemanticAssessment] = [:]

    func assess(text: String, context: String) async -> AdSemanticAssessment {
        let key = String((text + "\n" + context).hashValue)
        if let cached = cache[key] { return cached }

        let assessment = await classify(text: text, context: context)
        if cache.count >= 256 {
            cache.removeValue(forKey: cache.keys.first!)
        }
        cache[key] = assessment
        return assessment
    }

    private func classify(text: String, context: String) async -> AdSemanticAssessment {
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if model.isAvailable {
                do {
                    let session = LanguageModelSession(instructions: """
                    Classify podcast transcript windows. Advertisement means a paid sponsor read, commercial, or explicit show promotion. Editorial product discussion, news, business reporting, and ordinary membership context are not advertisements. Use uncertain when evidence is weak. Return boundary hints only when the transcript clearly marks them.
                    """)
                    let response = try await session.respond(
                        to: "Window:\n\(text)\n\nNeighboring context:\n\(context)",
                        generating: [FoundationModelAdvertisementOutput].self,
                        includeSchemaInPrompt: false,
                        options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 220)
                    )
                    if let output = response.content.first {
                        let label = AdSemanticAssessment.Label(rawValue: output.label) ?? .uncertain
                        return AdSemanticAssessment(
                            label: label,
                            confidence: min(max(output.confidence, 0), 1),
                            startHint: nil,
                            endHint: nil,
                            explanation: output.reason
                        )
                    }
                } catch {
                    // Model unavailable/not-ready is a normal fallback state.
                }
            }
        }
#endif
        return heuristicAssessment(for: text)
    }

    private func heuristicAssessment(for text: String) -> AdSemanticAssessment {
        let normalized = text.lowercased()
        let strongTerms = ["sponsored by", "promo code", "use code", "brought to you by", "visit our sponsor"]
        let softTerms = ["subscribe", "membership", "support the show", "get 20%", "discount"]
        let strong = strongTerms.filter { normalized.contains($0) }.count
        let soft = softTerms.filter { normalized.contains($0) }.count
        if strong > 0 {
            return AdSemanticAssessment(
                label: .advertisement,
                confidence: min(0.88, 0.66 + Double(strong) * 0.08),
                startHint: nil,
                endHint: nil,
                explanation: "Strong advertising phrase"
            )
        }
        if soft >= 2 {
            return AdSemanticAssessment(
                label: .advertisement,
                confidence: 0.58,
                startHint: nil,
                endHint: nil,
                explanation: "Multiple promotional phrases"
            )
        }
        return AdSemanticAssessment(label: .uncertain, confidence: 0.2, startHint: nil, endHint: nil, explanation: "No decisive advertising language")
    }
}

#if canImport(FoundationModels)
@Generable(description: "A conservative podcast advertisement classification")
private struct FoundationModelAdvertisementOutput {
    @Guide(description: "One of editorial, advertisement, or uncertain")
    var label: String
    @Guide(description: "Confidence from 0 to 1")
    var confidence: Double
    @Guide(description: "Short reason for the classification")
    var reason: String
}
#endif

struct SemanticAdvertisementSignalProvider: AdSignalProvider {
    let transcriptProvider: any AdTranscriptProvider
    let classifier: AdvertisementSemanticClassifier
    let source: AdSignalSource = .semantic

    init(
        transcriptProvider: any AdTranscriptProvider,
        classifier: AdvertisementSemanticClassifier = AdvertisementSemanticClassifier()
    ) {
        self.transcriptProvider = transcriptProvider
        self.classifier = classifier
    }

    func observations(for request: AdDetectionRequest) async throws -> [AdDetectionObservation] {
        let lines = try await transcriptProvider.lines(for: request)
        guard lines.isEmpty == false else { return [] }
        let windowDuration = max(request.configuration.windowDuration, 20)
        let hopDuration = max(request.configuration.hopDuration, 10)
        var results: [AdDetectionObservation] = []
        var windowStart = request.range.start
        let lastEnd = request.range.end ?? (lines.compactMap(\.end).max() ?? windowStart)

        while windowStart <= lastEnd {
            try Task.checkCancellation()
            let window = AdTimeRange(start: windowStart, end: min(windowStart + windowDuration, lastEnd))
            let windowLines = lines.filter { $0.range.overlaps(window, tolerance: 0.1) }
            guard windowLines.isEmpty == false else {
                windowStart += hopDuration
                continue
            }
            let text = windowLines.map(\.text).joined(separator: " ")
            let context = lines
                .filter { $0.start < windowStart || $0.start > windowStart + windowDuration }
                .prefix(4)
                .map(\.text)
                .joined(separator: " ")
            let assessment = await classifier.assess(text: text, context: context)
            if assessment.label == .advertisement {
                results.append(
                    AdDetectionObservation(
                        source: source,
                        range: window,
                        confidence: assessment.confidence,
                        explanation: assessment.explanation
                    )
                )
            }
            windowStart += hopDuration
        }
        return results
    }
}

struct AcousticChangePointDetector: Sendable {
    var loudnessThreshold: Double = 0.16
    var zeroCrossingThreshold: Double = 0.12

    func score(previous: PCMAnalysisChunk, current: PCMAnalysisChunk) -> Double {
        let previousRMS = rms(previous.samples)
        let currentRMS = rms(current.samples)
        let loudnessDelta = min(abs(currentRMS - previousRMS) / max(max(previousRMS, currentRMS), 0.05), 1)
        let previousZCR = zeroCrossingRate(previous.samples)
        let currentZCR = zeroCrossingRate(current.samples)
        let zcrDelta = min(abs(currentZCR - previousZCR) / 0.5, 1)
        let score = loudnessDelta * 0.65 + zcrDelta * 0.35
        return score >= loudnessThreshold || zcrDelta >= zeroCrossingThreshold ? min(score, 1) : 0
    }

    private func rms(_ samples: [Float]) -> Double {
        guard samples.isEmpty == false else { return 0 }
        return sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count))
    }

    private func zeroCrossingRate(_ samples: [Float]) -> Double {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for index in 1..<samples.count where (samples[index - 1] >= 0) != (samples[index] >= 0) {
            crossings += 1
        }
        return Double(crossings) / Double(samples.count - 1)
    }
}

struct AcousticBoundarySignalProvider: AdSignalProvider {
    let source: AdSignalSource = .acoustic
    let audioSource: any AudioAnalysisSource
    let detector: AcousticChangePointDetector

    init(audioSource: any AudioAnalysisSource, detector: AcousticChangePointDetector = AcousticChangePointDetector()) {
        self.audioSource = audioSource
        self.detector = detector
    }

    func observations(for request: AdDetectionRequest) async throws -> [AdDetectionObservation] {
        let chunks = try await audioSource.chunks(
            in: request.range,
            windowDuration: request.configuration.windowDuration,
            hopDuration: request.configuration.hopDuration
        )
        guard chunks.count > 1 else { return [] }
        return zip(chunks, chunks.dropFirst()).compactMap { previous, current in
            let score = detector.score(previous: previous, current: current)
            guard score > 0 else { return nil }
            return AdDetectionObservation(
                source: source,
                range: AdTimeRange(start: current.start, end: current.start + min(current.duration, 4)),
                confidence: min(score * 0.7, 0.48),
                explanation: "Acoustic change point; boundary evidence only"
            )
        }
    }
}

struct AdFingerprint: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case advertisement, negative }
    let id: UUID
    let podcastIdentity: String?
    let signature: [Float]
    let kind: Kind
    let createdAt: Date
    let expiresAt: Date
}

actor AdFingerprintStore {
    static let shared = AdFingerprintStore()
    private static let storageKey = "AdDetection.fingerprints.v1"

    private let maxRecords: Int
    private let expiry: TimeInterval
    private var records: [AdFingerprint]

    init(maxRecords: Int = 256, expiry: TimeInterval = 90 * 24 * 60 * 60) {
        self.maxRecords = max(maxRecords, 1)
        self.expiry = max(expiry, 60)
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let persisted = try? JSONDecoder().decode([AdFingerprint].self, from: data) {
            self.records = persisted
        } else {
            self.records = []
        }
    }

    func remember(signature: [Float], podcastIdentity: String?, kind: AdFingerprint.Kind = .advertisement, now: Date = Date()) {
        guard signature.isEmpty == false else { return }
        prune(now: now)
        records.append(
            AdFingerprint(
                id: UUID(),
                podcastIdentity: podcastIdentity,
                signature: signature,
                kind: kind,
                createdAt: now,
                expiresAt: now.addingTimeInterval(expiry)
            )
        )
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        persist()
    }

    func bestMatch(signature: [Float], podcastIdentity: String?, now: Date = Date()) -> (strength: Double, duration: TimeInterval, kind: AdFingerprint.Kind)? {
        prune(now: now)
        return records.compactMap { record in
            guard record.podcastIdentity == nil || record.podcastIdentity == podcastIdentity else { return nil }
            let strength = Self.similarity(signature, record.signature)
            return (strength, 1, record.kind)
        }
        .max { $0.strength < $1.strength }
    }

    private func prune(now: Date) {
        let originalCount = records.count
        records.removeAll { $0.expiresAt <= now }
        if records.count != originalCount {
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static func similarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.isEmpty == false, lhs.count == rhs.count else { return 0 }
        let distance = zip(lhs, rhs).reduce(0) { $0 + abs(Double($1.0 - $1.1)) }
        return max(0, 1 - distance / Double(lhs.count))
    }
}

enum AudioFingerprintBuilder {
    static func signature(samples: [Float], bucketCount: Int = 16) -> [Float] {
        guard samples.isEmpty == false, bucketCount > 0 else { return [] }
        let bucketSize = max(samples.count / bucketCount, 1)
        return (0..<bucketCount).map { index in
            let start = min(index * bucketSize, samples.count)
            let end = min(start + bucketSize, samples.count)
            guard start < end else { return 0 }
            let energy = samples[start..<end].reduce(0) { $0 + abs($1) }
            return energy / Float(end - start)
        }
    }
}

struct FingerprintAdvertisementSignalProvider: AdSignalProvider {
    let source: AdSignalSource = .fingerprint
    let audioSource: any AudioAnalysisSource
    let store: AdFingerprintStore
    let podcastIdentity: String?

    func observations(for request: AdDetectionRequest) async throws -> [AdDetectionObservation] {
        let chunks = try await audioSource.chunks(
            in: request.range,
            windowDuration: request.configuration.windowDuration,
            hopDuration: request.configuration.hopDuration
        )
        var results: [AdDetectionObservation] = []
        for chunk in chunks {
            let signature = AudioFingerprintBuilder.signature(samples: chunk.samples)
            guard let match = await store.bestMatch(signature: signature, podcastIdentity: podcastIdentity), match.strength >= 0.82 else { continue }
            guard match.kind == .advertisement else { continue }
            results.append(
                AdDetectionObservation(
                    source: source,
                    range: AdTimeRange(start: chunk.start, end: chunk.start + chunk.duration),
                    confidence: min(match.strength, 0.98),
                    explanation: "Local repeated-audio match (strength \(match.strength.formatted(.number.precision(.fractionLength(2)))))"
                )
            )
        }
        return results
    }
}

struct AdPublisherMarker: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval?
    let title: String
}

struct PublisherMetadataAdSignalProvider: AdSignalProvider {
    let source: AdSignalSource = .publisherMetadata
    let markers: [AdPublisherMarker]

    func observations(for request: AdDetectionRequest) async throws -> [AdDetectionObservation] {
        let keywords = ["ad", "advert", "sponsor", "sponsored", "promotion", "promo", "commercial"]
        return markers.compactMap { marker in
            guard marker.range.overlaps(request.range, tolerance: 0.1),
                  keywords.contains(where: { marker.title.lowercased().contains($0) }) else { return nil }
            return AdDetectionObservation(
                source: source,
                range: AdTimeRange(start: marker.start, end: marker.end),
                confidence: 0.48,
                explanation: "Publisher metadata suggests advertising; retained separately from chapters"
            )
        }
    }
}

private extension AdPublisherMarker {
    var range: AdTimeRange { AdTimeRange(start: start, end: end) }
}

private enum AudioSnippetWriter {
    static func makeSnippet(from url: URL, range: AdTimeRange) async throws -> URL {
        guard url.isFileURL else {
            throw AudioAnalysisSourceError.unsupported("Rolling transcription needs a downloaded audio file.")
        }
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let sampleRate = format.sampleRate
        let startFrame = AVAudioFramePosition(max(range.start, 0) * sampleRate)
        let endFrame = AVAudioFramePosition((range.end ?? (Double(input.length) / sampleRate)) * sampleRate)
        let frameCount = AVAudioFrameCount(max(endFrame - startFrame, 0))
        guard frameCount > 0 else { throw AudioAnalysisSourceError.noAudioTrack }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdDetection-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = try AVAudioFile(forWriting: outputURL, settings: settings)
        input.framePosition = min(startFrame, input.length)
        var remaining = min(frameCount, AVAudioFrameCount(input.length - input.framePosition))
        while remaining > 0 {
            try Task.checkCancellation()
            let count = min(remaining, AVAudioFrameCount(max(sampleRate * 10, 1)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }
            try input.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= buffer.frameLength
        }
        return outputURL
    }
}
