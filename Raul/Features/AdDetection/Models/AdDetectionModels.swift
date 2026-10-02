import Foundation

/// The independent signals that can contribute evidence without becoming
/// publisher chapters. Keeping this vocabulary stable makes diagnostics and
/// evaluation data portable across detector implementations.
enum AdSignalSource: String, Codable, CaseIterable, Sendable {
    case transcript
    case semantic
    case acoustic
    case fingerprint
    case publisherMetadata
}

enum AdObservationKind: String, Codable, Sendable {
    case advertisement
    case boundary
    case negativeEvidence
}

enum AdSegmentState: String, Codable, Sendable {
    case provisional
    case confirmed
}

struct AdTimeRange: Codable, Equatable, Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval?

    init(start: TimeInterval, end: TimeInterval? = nil) {
        self.start = start
        self.end = end
    }

    var duration: TimeInterval? {
        guard let end, end >= start else { return nil }
        return end - start
    }

    var isValid: Bool {
        start.isFinite && start >= 0 && (end == nil || (end!.isFinite && end! >= start))
    }

    func overlaps(_ other: AdTimeRange, tolerance: TimeInterval = 0) -> Bool {
        let lhsEnd = end ?? .greatestFiniteMagnitude
        let rhsEnd = other.end ?? .greatestFiniteMagnitude
        return start <= rhsEnd + tolerance && other.start <= lhsEnd + tolerance
    }
}

struct AdEvidence: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: UUID
    let source: AdSignalSource
    let kind: AdObservationKind
    let confidence: Double
    let range: AdTimeRange
    let explanation: String

    init(
        id: UUID = UUID(),
        source: AdSignalSource,
        kind: AdObservationKind = .advertisement,
        confidence: Double,
        range: AdTimeRange,
        explanation: String = ""
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.confidence = min(max(confidence, 0), 1)
        self.range = range
        self.explanation = explanation
    }
}

struct AdDetectionObservation: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: UUID
    let source: AdSignalSource
    let kind: AdObservationKind
    let range: AdTimeRange
    let confidence: Double
    let explanation: String

    init(
        id: UUID = UUID(),
        source: AdSignalSource,
        kind: AdObservationKind = .advertisement,
        range: AdTimeRange,
        confidence: Double,
        explanation: String = ""
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.range = range
        self.confidence = min(max(confidence, 0), 1)
        self.explanation = explanation
    }

    var evidence: AdEvidence {
        AdEvidence(
            id: id,
            source: source,
            kind: kind,
            confidence: confidence,
            range: range,
            explanation: explanation
        )
    }
}

struct AdSegment: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval?
    let confidence: Double
    let evidence: [AdEvidence]
    let state: AdSegmentState
    let episodeIdentity: String

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval?,
        confidence: Double,
        evidence: [AdEvidence],
        state: AdSegmentState,
        episodeIdentity: String
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.confidence = min(max(confidence, 0), 1)
        self.evidence = evidence
        self.state = state
        self.episodeIdentity = episodeIdentity
    }

    var range: AdTimeRange { AdTimeRange(start: start, end: end) }

    func contains(_ position: TimeInterval) -> Bool {
        guard position >= start else { return false }
        return end.map { position < $0 } ?? true
    }

    var hasKnownStableEnd: Bool {
        guard let end else { return false }
        return end.isFinite && end > start
    }
}

struct AdDetectionThresholds: Codable, Equatable, Sendable {
    var displayThreshold: Double
    var manualSkipThreshold: Double
    var automaticSkipThreshold: Double

    static let `default` = Self(
        displayThreshold: 0.58,
        manualSkipThreshold: 0.68,
        automaticSkipThreshold: 0.86
    )

    init(
        displayThreshold: Double,
        manualSkipThreshold: Double,
        automaticSkipThreshold: Double
    ) {
        self.displayThreshold = min(max(displayThreshold, 0), 1)
        self.manualSkipThreshold = min(max(manualSkipThreshold, self.displayThreshold), 1)
        self.automaticSkipThreshold = min(max(automaticSkipThreshold, self.manualSkipThreshold), 1)
    }
}

struct AdDetectionConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var showDetectedAdvertisements: Bool
    var automaticallySkipAdvertisements: Bool
    var thresholds: AdDetectionThresholds
    var windowDuration: TimeInterval
    var hopDuration: TimeInterval

    static let `default` = Self(
        enabled: false,
        showDetectedAdvertisements: false,
        automaticallySkipAdvertisements: false,
        thresholds: .default,
        windowDuration: 30,
        hopDuration: 15
    )

    var isAnalysisActive: Bool { enabled }
}

struct AdDetectionRequest: Codable, Equatable, Sendable {
    let episodeIdentity: String
    let mediaURL: URL
    let languageIdentifier: String?
    let range: AdTimeRange
    let configuration: AdDetectionConfiguration

    init(
        episodeIdentity: String,
        mediaURL: URL,
        languageIdentifier: String? = nil,
        range: AdTimeRange = AdTimeRange(start: 0),
        configuration: AdDetectionConfiguration = .default
    ) {
        self.episodeIdentity = episodeIdentity
        self.mediaURL = mediaURL
        self.languageIdentifier = languageIdentifier
        self.range = range
        self.configuration = configuration
    }
}

struct TranscriptDetectionLine: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: UUID
    let text: String
    let start: TimeInterval
    let end: TimeInterval?

    init(id: UUID = UUID(), text: String, start: TimeInterval, end: TimeInterval? = nil) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
    }

    var range: AdTimeRange { AdTimeRange(start: start, end: end) }
}

