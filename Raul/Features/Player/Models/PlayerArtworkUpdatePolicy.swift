import Foundation

enum PlayerArtworkIdentity: Hashable {
    case url(String, profileID: String?)
    case chapterData(String)
}

enum PlayerArtworkUpdatePolicy {
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
