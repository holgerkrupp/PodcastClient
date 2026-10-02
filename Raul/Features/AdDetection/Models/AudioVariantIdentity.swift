import Foundation

enum AudioVariantIdentity {
    static func make(episodeURL: URL, mediaURL: URL?) -> String {
        guard let mediaURL else { return StableIdentityKey.make(episodeURL.absoluteString) }

        if mediaURL.isFileURL {
            let values = try? mediaURL.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey
            ])
            return StableIdentityKey.make(
                episodeURL.absoluteString,
                mediaURL.standardizedFileURL.path,
                values?.fileSize.map(String.init) ?? "unknown-size",
                values?.contentModificationDate?.ISO8601Format() ?? "unknown-date"
            )
        }

        return StableIdentityKey.make(episodeURL.absoluteString, mediaURL.absoluteString)
    }
}
