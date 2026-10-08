import Foundation

/// Optional eligibility rules for automatic downloads. Unknown metadata passes
/// duration/date checks so an incomplete feed never silently loses an episode.
struct AutoDownloadEpisodeFilter: Codable, Hashable, Sendable {
    var includedKeywords: [String] = []
    var excludedKeywords: [String] = []
    var minimumDurationSeconds: Double?
    var maximumDurationSeconds: Double?
    var maximumPublicationAgeDays: Int?
    var episodeTypes: Set<String> = []

    static let none = AutoDownloadEpisodeFilter()

    func allows(title: String, duration: Double?, publishDate: Date?, type: EpisodeType?, now: Date = .now) -> Bool {
        let normalizedTitle = Self.normalize(title.plainTextFromHTML() ?? title)
        let includes = includedKeywords.map(Self.normalize).filter { !$0.isEmpty }
        let excludes = excludedKeywords.map(Self.normalize).filter { !$0.isEmpty }

        if includes.isEmpty == false && includes.contains(where: normalizedTitle.contains) == false { return false }
        if excludes.contains(where: normalizedTitle.contains) { return false }

        if let duration {
            if let minimumDurationSeconds, duration < minimumDurationSeconds { return false }
            if let maximumDurationSeconds, duration > maximumDurationSeconds { return false }
        }

        if let maximumPublicationAgeDays, let publishDate {
            let oldestAllowed = now.addingTimeInterval(-Double(maximumPublicationAgeDays) * 86_400)
            if publishDate < oldestAllowed { return false }
        }

        if episodeTypes.isEmpty == false, let type,
           type != .unknown, episodeTypes.contains(type.rawValue) == false {
            return false
        }
        return true
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

extension PodcastSettings {
    var autoDownloadFilter: AutoDownloadEpisodeFilter {
        get {
            guard let data = autoDownloadFilterJSON?.data(using: .utf8),
                  let filter = try? JSONDecoder().decode(AutoDownloadEpisodeFilter.self, from: data) else {
                return .none
            }
            return filter
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            let empty = newValue == .none
            autoDownloadFilterJSON = empty ? nil : String(decoding: data, as: UTF8.self)
        }
    }
}
