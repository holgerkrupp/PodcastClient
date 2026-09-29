import Foundation

/// A UTF-16 range in the immutable shownote source string.
struct ShownoteSourceRange: Codable, Hashable, Sendable {
    let location: Int
    let length: Int

    var end: Int { location + length }

    init(_ range: NSRange) {
        location = range.location
        length = range.length
    }
}

enum ShownoteLinkOccurrenceKind: String, Codable, Hashable, Sendable {
    case plainText
    case publisherAnchor
}

enum ShownoteLinkClassification: String, Codable, Hashable, Sendable {
    case unknown
    case web
    case podcastCandidate
    case podcast
    case unsupported
}

/// A link occurrence extracted from shownotes. The occurrence identity is
/// stable for a particular source document, while `normalizedURL` is used to
/// coalesce resolution work for repeated links.
struct ShownoteLinkCandidate: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let originalURL: URL
    let normalizedURL: URL
    let sourceRange: ShownoteSourceRange
    let publisherAnchorText: String?
    let occurrenceKind: ShownoteLinkOccurrenceKind
    let displayText: String
    let sourceMarkup: String
    var classification: ShownoteLinkClassification

    init(
        id: String,
        originalURL: URL,
        normalizedURL: URL,
        sourceRange: ShownoteSourceRange,
        publisherAnchorText: String?,
        occurrenceKind: ShownoteLinkOccurrenceKind,
        displayText: String,
        sourceMarkup: String,
        classification: ShownoteLinkClassification = .unknown
    ) {
        self.id = id
        self.originalURL = originalURL
        self.normalizedURL = normalizedURL
        self.sourceRange = sourceRange
        self.publisherAnchorText = publisherAnchorText
        self.occurrenceKind = occurrenceKind
        self.displayText = displayText
        self.sourceMarkup = sourceMarkup
        self.classification = classification
    }
}
