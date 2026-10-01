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
    case email
    case publisherAnchor
}

/// Describes whether a link can be replaced by a rich card without changing
/// the surrounding paragraph or list structure.
enum ShownoteLinkPresentation: String, Codable, Hashable, Sendable {
    case inline
    case standalone
}

enum ShownoteLinkClassification: String, Codable, Hashable, Sendable {
    case unknown
    case web
    case mastodon
    case podcastCandidate
    case podcast
    case unsupported
}

/// Metadata used to render a link without changing the source shownotes.
/// `canonicalURL` is kept separate from the requested URL so cards can open
/// the page the publisher identifies as canonical while the occurrence still
/// retains its original destination as a fallback.
struct ShownotePreviewMetadata: Hashable, Sendable {
    let title: String?
    let description: String?
    let imageURL: URL?
    let siteName: String?
    let canonicalURL: URL?
    let handle: String?

    init(
        title: String? = nil,
        description: String? = nil,
        imageURL: URL? = nil,
        siteName: String? = nil,
        canonicalURL: URL? = nil,
        handle: String? = nil
    ) {
        self.title = title
        self.description = description
        self.imageURL = imageURL
        self.siteName = siteName
        self.canonicalURL = canonicalURL
        self.handle = handle
    }
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
    var presentation: ShownoteLinkPresentation
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
        presentation: ShownoteLinkPresentation = .inline,
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
        self.presentation = presentation
        self.classification = classification
    }
}
