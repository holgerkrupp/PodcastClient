import Foundation

enum PlayerArtworkIdentity: Hashable {
    case url(String, profileID: String?)
    case chapterData(String)
    case embeddedFile(String)
}

enum PlayerArtworkUpdatePolicy {
    /// Chapter artwork stays ahead of the episode and podcast fallback in every
    /// player surface. Duplicate URLs are requested once.
    static func orderedImageURLs(
        chapterURL: URL?,
        episodeURL: URL?,
        podcastURL: URL?
    ) -> [URL] {
        var seen = Set<URL>()
        return [chapterURL, episodeURL, podcastURL]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    static func higherPriorityImageURLs(
        than resolvedIdentity: PlayerArtworkIdentity,
        among candidates: [URL],
        profileID: String?
    ) -> [URL] {
        switch resolvedIdentity {
        case .chapterData:
            return []
        case .url(let source, let resolvedProfileID):
            guard resolvedProfileID == profileID,
                  let index = candidates.firstIndex(where: { $0.absoluteString == source }) else {
                return candidates
            }
            return Array(candidates.prefix(index))
        case .embeddedFile:
            return candidates
        }
    }

    /// A resolved image only needs to be published when its source changes.
    /// A nil result clears an existing image after the fallback lookup finishes.
    static func shouldApply(
        resolvedIdentity: PlayerArtworkIdentity?,
        currentIdentity: PlayerArtworkIdentity?,
        hasImage: Bool
    ) -> Bool {
        guard hasImage else { return currentIdentity != nil }
        return resolvedIdentity != currentIdentity
    }
}
