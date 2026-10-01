import Foundation
import mp3ChapterReader
import SwiftData

enum PodcastEpisodeShareImportError: LocalizedError {
    case unsupportedURL
    case noEpisodeFound

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "The shared item is not a valid URL."
        case .noEpisodeFound:
            return "No playable podcast episode could be found on this page."
        }
    }
}

enum SharedEpisodeImportDestination: Sendable, Equatable {
    case inbox
    case playlist(UUID)
}

enum SharedURLResolution {
    case podcastEpisode(feed: PodcastFeed, episode: PodcastEpisodeDraft, sharedURL: URL)
    case podcast(feed: PodcastFeed, sharedURL: URL)
    case standaloneMedia(StandaloneSharedEpisode)
    case unresolved(sharedURL: URL, suggestedSearch: String?)
}

struct PodcastEpisodeShareImporter {
    private let ardAPI: ARDSoundsAPI

    init(ardAPI: ARDSoundsAPI = ARDSoundsAPI()) {
        self.ardAPI = ardAPI
    }

    @MainActor
    func resolve(sharedURL: URL) async -> SharedURLResolution {
        guard isSupportedSharedURL(sharedURL) else {
            return .unresolved(sharedURL: sharedURL, suggestedSearch: nil)
        }

        do {
            switch try await resolveEpisode(from: sharedURL) {
            case .feed(let draft, _, let feed):
                return .podcastEpisode(feed: feed, episode: draft, sharedURL: sharedURL)
            case .podcast(let feed):
                return .podcast(feed: feed, sharedURL: sharedURL)
            case .standalone(let standalone):
                return .standaloneMedia(standalone)
            case .unresolved(let search):
                return .unresolved(sharedURL: sharedURL, suggestedSearch: search)
            }
        } catch {
            return .unresolved(
                sharedURL: sharedURL,
                suggestedSearch: fallbackSearchQuery(for: sharedURL)
            )
        }
    }

    func fallbackSearchQueryForRecovery(_ url: URL) -> String? {
        fallbackSearchQuery(for: url)
    }

    @MainActor
    @discardableResult
    func importEpisode(
        from sharedURL: URL,
        destination: SharedEpisodeImportDestination = .inbox,
        modelContext: ModelContext
    ) async throws -> URL {
        let resolved = try await resolveEpisode(from: sharedURL)
        switch resolved {
        case .feed(_, _, _), .standalone(_):
            break
        case .podcast(_), .unresolved(_):
            throw PodcastEpisodeShareImportError.noEpisodeFound
        }
        return try await upsert(
            resolved,
            sharedURL: sharedURL,
            destination: destination,
            modelContext: modelContext
        )
    }

    /// Imports an episode someone shared by its enclosure URL, e.g. over
    /// SharePlay. Looks it up in its own feed first so it arrives with full
    /// metadata; otherwise imports the bare audio file.
    @MainActor
    @discardableResult
    func importEpisode(episodeURL: URL, feedURL: URL?, modelContext: ModelContext) async throws -> URL {
        if let feedURL,
           let page = try? await PodcastParser.fetchPage(from: feedURL),
           let draft = matchingEpisode(in: page.episodes, sharedURL: episodeURL) {
            return try await upsert(
                .feed(draft: draft, episodes: page.episodes, feed: page.feed),
                sharedURL: episodeURL,
                destination: .inbox,
                modelContext: modelContext
            )
        }
        return try await importEpisode(from: episodeURL, modelContext: modelContext)
    }

    private func resolveEpisode(from sharedURL: URL) async throws -> ResolvedSharedEpisode {
        guard isSupportedSharedURL(sharedURL) else {
            throw PodcastEpisodeShareImportError.unsupportedURL
        }

        if let ardResolution = await resolveARDSoundsEpisode(from: sharedURL) {
            return ardResolution
        }

        if EpisodeMedia.isPlayable(url: sharedURL, mimeType: nil) {
            let duration = await durationForSharedMP3IfNeeded(
                mediaURL: sharedURL,
                existingDuration: nil
            )
            return .standalone(
                StandaloneSharedEpisode(
                    title: fallbackTitle(for: sharedURL),
                    desc: nil,
                    pageURL: sharedURL,
                    mediaURL: sharedURL,
                    mediaType: nil,
                    imageURL: nil,
                    duration: duration
                )
            )
        }

        let page = try await fetchText(from: sharedURL)
        let feedURLs = discoverFeedURLs(in: page, baseURL: sharedURL)
        let canonicalPageURL = discoverCanonicalURL(in: page, baseURL: sharedURL)

        var discoveredPodcastFeed: PodcastFeed?
        for feedURL in feedURLs {
            guard let page = try? await PodcastParser.fetchPage(from: feedURL) else { continue }
            if let draft = matchingEpisode(
                in: page.episodes,
                sharedURLs: [sharedURL, canonicalPageURL].compactMap { $0 }
            ) {
                return .feed(
                    draft: draft,
                    episodes: page.episodes,
                    feed: page.feed
                )
            }
            discoveredPodcastFeed = discoveredPodcastFeed ?? page.feed
        }

        if let mediaURL = discoverMediaURL(in: page, baseURL: sharedURL) {
            let metadataDuration = htmlMetadata(named: "music:duration", in: page).flatMap(Double.init)
            let duration = await durationForSharedMP3IfNeeded(
                mediaURL: mediaURL,
                existingDuration: metadataDuration
            )
            return .standalone(
                StandaloneSharedEpisode(
                    title: htmlMetadata(named: "og:title", in: page)
                        ?? titleTag(in: page)
                        ?? fallbackTitle(for: sharedURL),
                    desc: htmlMetadata(named: "og:description", in: page)
                        ?? htmlMetadata(named: "description", in: page),
                    pageURL: sharedURL,
                    mediaURL: mediaURL,
                    mediaType: mediaType(for: mediaURL),
                    imageURL: htmlMetadata(named: "og:image", in: page).flatMap { URL(string: $0, relativeTo: sharedURL)?.absoluteURL },
                    duration: duration
                )
            )
        }

        if let discoveredPodcastFeed {
            return .podcast(feed: discoveredPodcastFeed)
        }

        return .unresolved(
            suggestedSearch: fallbackSearchQuery(
                for: sharedURL,
                title: htmlMetadata(named: "og:title", in: page) ?? titleTag(in: page)
            )
        )
    }

    private func resolveARDSoundsEpisode(from sharedURL: URL) async -> ResolvedSharedEpisode? {
        guard let itemID = ARDSoundsAPI.itemURN(in: sharedURL),
              let item = try? await ardAPI.item(id: itemID),
              let mediaURL = item.mediaURL else {
            return nil
        }

        let title = item.title ?? fallbackTitle(for: sharedURL)
        let imageURL = item.image?.resolvedURL
        let standalone = StandaloneSharedEpisode(
            title: title,
            desc: item.description,
            pageURL: sharedURL,
            mediaURL: mediaURL,
            mediaType: mediaType(for: mediaURL),
            imageURL: imageURL,
            duration: item.duration
        )

        // ARD usually does not publish an RSS URL. Resolve the owning show by
        // its exact Apple Podcasts title, then prefer the feed's richer draft
        // when it contains the same enclosure or episode title.
        guard let showTitle = item.showTitle,
              let feedURL = await ApplePodcastsFeedResolver(storefront: "de")
                .feedURL(matchingTitle: showTitle, author: item.author),
              let feedPage = try? await PodcastParser.fetchPage(from: feedURL) else {
            return .standalone(standalone)
        }

        if let draft = feedPage.episodes.first(where: {
            urlsMatch($0.episodeURL, mediaURL)
                || normalizedTitle($0.title) == normalizedTitle(title)
        }) {
            return .feed(draft: draft, episodes: feedPage.episodes, feed: feedPage.feed)
        }

        return .podcast(feed: feedPage.feed)
    }

    @MainActor
    private func upsert(
        _ resolved: ResolvedSharedEpisode,
        sharedURL: URL,
        destination: SharedEpisodeImportDestination,
        modelContext: ModelContext
    ) async throws -> URL {
        switch resolved {
        case .feed(let draft, let episodes, let feed):
            let podcast = upsertPodcast(from: feed, modelContext: modelContext)
            let episode = upsertEpisode(from: draft, podcast: podcast, modelContext: modelContext)

            // Keep the feed-backed show browsable even when the user only
            // shared one episode and has not subscribed yet. The selected
            // episode is inserted first so it remains available if a malformed
            // sibling entry cannot be imported.
            for sibling in episodes where sibling.episodeURL != draft.episodeURL {
                _ = upsertEpisode(
                    from: sibling,
                    podcast: podcast,
                    modelContext: modelContext
                )
            }

            modelContext.saveIfNeeded()
            let episodeURL = episode.url ?? draft.episodeURL
            try await apply(
                destination,
                to: episode,
                episodeURL: episodeURL,
                modelContext: modelContext
            )
            return episodeURL

        case .standalone(let standalone):
            let episode = upsertStandaloneEpisode(standalone, sharedURL: sharedURL, modelContext: modelContext)
            modelContext.saveIfNeeded()
            let episodeURL = episode.url ?? standalone.mediaURL
            try await apply(
                destination,
                to: episode,
                episodeURL: episodeURL,
                modelContext: modelContext
            )
            return episodeURL

        case .podcast(_), .unresolved(_):
            throw PodcastEpisodeShareImportError.noEpisodeFound
        }
    }

    @MainActor
    private func apply(
        _ destination: SharedEpisodeImportDestination,
        to episode: Episode,
        episodeURL: URL,
        modelContext: ModelContext
    ) async throws {
        switch destination {
        case .inbox:
            markInInbox(episode)
            modelContext.saveIfNeeded()
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)

        case .playlist(let playlistID):
            // The playlist actor uses its own model context, so the imported
            // episode must be durable before it can look it up by URL.
            modelContext.saveIfNeeded()
            let playlistActor = try PlaylistModelActor(
                modelContainer: modelContext.container,
                playlistID: playlistID
            )
            try await playlistActor.add(episodeURL: episodeURL, to: .end)
        }
    }

    @MainActor
    private func upsertPodcast(from feed: PodcastFeed, modelContext: ModelContext) -> Podcast {
        if let feedURL = feed.url {
            let descriptor = FetchDescriptor<Podcast>(
                predicate: #Predicate<Podcast> { $0.feed == feedURL }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                apply(feed: feed, to: existing)
                return existing
            }
        }

        // A shared page may advertise the current endpoint while an existing
        // subscription still stores an older redirect or an alternate feed.
        // Reuse that podcast so the normal subscription state and navigation
        // remain attached to one show.
        if let podcasts = try? modelContext.fetch(FetchDescriptor<Podcast>()),
           let existing = podcasts.first(where: feed.matchesExistingPodcast) {
            apply(feed: feed, to: existing)
            return existing
        }

        let podcast = Podcast(from: feed)
        podcast.metaData?.isSubscribed = false
        podcast.metaData?.subscriptionDate = nil
        modelContext.insert(podcast)
        return podcast
    }

    @MainActor
    private func upsertEpisode(
        from draft: PodcastEpisodeDraft,
        podcast: Podcast,
        modelContext: ModelContext
    ) -> Episode {
        let episodeURL: URL? = draft.episodeURL
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.url == episodeURL }
        )

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.podcast = podcast
            existing.update(from: draft.rawEpisodeData)
            return existing
        }

        guard let episode = Episode(from: draft.rawEpisodeData, podcast: podcast) else {
            let episode = Episode(
                guid: draft.guid ?? draft.episodeURL.absoluteString,
                title: draft.title,
                publishDate: draft.publishDate,
                url: draft.episodeURL,
                podcast: podcast,
                duration: draft.duration,
                author: draft.author
            )
            episode.subtitle = draft.subtitle
            episode.desc = draft.desc
            episode.content = draft.content
            episode.link = draft.link
            episode.imageURL = draft.imageURL
            episode.number = draft.number
            episode.type = draft.type
            episode.deeplinks = draft.deeplinks
            modelContext.insert(episode)
            return episode
        }

        modelContext.insert(episode)
        return episode
    }

    @MainActor
    private func upsertStandaloneEpisode(
        _ standalone: StandaloneSharedEpisode,
        sharedURL: URL,
        modelContext: ModelContext
    ) -> Episode {
        let mediaURL = standalone.mediaURL
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.url == mediaURL }
        )

        let episode: Episode
        if let existing = try? modelContext.fetch(descriptor).first {
            episode = existing
        } else {
            episode = Episode(
                guid: sharedURL.absoluteString,
                title: standalone.title,
                publishDate: Date(),
                url: mediaURL,
                podcast: nil,
                duration: standalone.duration,
                author: nil
            )
            modelContext.insert(episode)
        }

        episode.guid = sharedURL.absoluteString
        episode.title = standalone.title
        episode.desc = standalone.desc
        episode.link = standalone.pageURL
        episode.imageURL = standalone.imageURL
        episode.mediaType = standalone.mediaType
        episode.duration = standalone.duration
        episode.source = .feedDownload
        return episode
    }

    @MainActor
    private func markInInbox(_ episode: Episode) {
        if episode.metaData == nil {
            let metadata = EpisodeMetaData()
            metadata.episode = episode
            episode.metaData = metadata
        }

        episode.metaData?.setInboxMembership(true)
        episode.metaData?.systemSuppressionReason = nil
    }

    private func apply(feed: PodcastFeed, to podcast: Podcast) {
        podcast.title = feed.title ?? podcast.title
        podcast.desc = feed.description ?? podcast.desc
        podcast.author = feed.artist ?? podcast.author
        podcast.imageURL = feed.artworkURL ?? podcast.imageURL
        podcast.link = feed.link ?? podcast.link
        podcast.copyright = feed.copyright ?? podcast.copyright
        podcast.funding = feed.funding
        podcast.social = feed.social
        podcast.people = feed.people
        podcast.alternativeFeeds = feed.alternativeFeeds
        podcast.optionalTags = feed.optionalTags
        podcast.metaData?.isSubscribed = podcast.metaData?.isSubscribed ?? false
    }

    private func matchingEpisode(in drafts: [PodcastEpisodeDraft], sharedURL: URL) -> PodcastEpisodeDraft? {
        matchingEpisode(in: drafts, sharedURLs: [sharedURL])
    }

    func matchingEpisode(
        in drafts: [PodcastEpisodeDraft],
        sharedURLs: [URL]
    ) -> PodcastEpisodeDraft? {
        let pathIdentifiers = Set(
            sharedURLs
                .map(\.lastPathComponent)
                .filter { $0.isEmpty == false }
        )

        return drafts.first { draft in
            sharedURLs.contains { sharedURL in
                urlsMatch(draft.link, sharedURL)
                    || urlsMatch(draft.episodeURL, sharedURL)
                    || draft.deeplinks.contains { urlsMatch($0, sharedURL) }
            }
                || draft.guid.map(pathIdentifiers.contains) == true
                || pathIdentifiers.contains(draft.id)
        }
    }

    private func urlsMatch(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return normalizedURLString(lhs) == normalizedURLString(rhs)
            || lhs.absoluteString == rhs.absoluteString
    }

    private func normalizedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        components.query = nil
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? url.absoluteString
    }

    private func fetchText(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    func discoverFeedURLs(in html: String, baseURL: URL) -> [URL] {
        let links = linkTags(in: html).compactMap { tag -> URL? in
            let type = attribute("type", in: tag)?.lowercased() ?? ""
            let rel = attribute("rel", in: tag)?.lowercased() ?? ""
            guard rel.contains("alternate"),
                  type.contains("rss") || type.contains("atom") || type.contains("xml"),
                  let href = attribute("href", in: tag) else {
                return nil
            }
            return URL(string: href, relativeTo: baseURL)?.absoluteURL
        }

        return Array(NSOrderedSet(array: links)) as? [URL] ?? links
    }

    func discoverCanonicalURL(in html: String, baseURL: URL) -> URL? {
        for tag in linkTags(in: html) {
            let rel = attribute("rel", in: tag)?.lowercased() ?? ""
            guard rel.split(whereSeparator: { $0.isWhitespace }).contains("canonical"),
                  let href = attribute("href", in: tag) else {
                continue
            }
            return URL(string: href, relativeTo: baseURL)?.absoluteURL
        }

        return htmlMetadata(named: "og:url", in: html)
            .flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
    }

    private func discoverMediaURL(in html: String, baseURL: URL) -> URL? {
        let metadataKeys = ["og:audio", "og:audio:url", "og:video", "og:video:url", "twitter:player:stream"]
        for key in metadataKeys {
            if let value = htmlMetadata(named: key, in: html),
               let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
               EpisodeMedia.isPlayable(url: url, mimeType: nil) {
                return url
            }
        }

        let sourcePattern = #"(?:src|href)=["']([^"']+\.(?:mp3|m4a|aac|flac|wav|mp4|m4v|mov|m3u8)(?:\?[^"']*)?)["']"#
        let sourceURLs = regexCaptures(sourcePattern, in: html)
            .compactMap { URL(string: decodeHTMLEntities($0), relativeTo: baseURL)?.absoluteURL }
        if let url = preferredMediaURL(from: sourceURLs) {
            return url
        }

        let escapedPattern = #"(https?:\\?/\\?/[^"\\]+?\.(?:mp3|m4a|aac|flac|wav|mp4|m4v|mov|m3u8)(?:\?[^"\\]*)?)"#
        let escapedURLs = regexCaptures(escapedPattern, in: html)
            .map { $0.replacingOccurrences(of: #"\/"#, with: "/") }
            .compactMap { URL(string: decodeHTMLEntities($0)) }
        return preferredMediaURL(from: escapedURLs)
    }

    private func preferredMediaURL(from urls: [URL]) -> URL? {
        urls.first { isAudioURL($0) } ?? urls.first
    }

    private func isAudioURL(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "opus":
            return true
        default:
            return false
        }
    }

    private func mediaType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m3u8": return "application/vnd.apple.mpegurl"
        default: return nil
        }
    }

    private func durationForSharedMP3IfNeeded(mediaURL: URL, existingDuration: TimeInterval?) async -> TimeInterval? {
        if let existingDuration, existingDuration > 0 {
            return existingDuration
        }

        guard mediaURL.pathExtension.lowercased() == "mp3" else {
            return existingDuration
        }

        do {
            return try await RemoteMP3DurationReader.duration(from: mediaURL)
        } catch {
            return existingDuration
        }
    }

    private func linkTags(in html: String) -> [String] {
        regexMatches(#"<link\b[^>]*>"#, in: html)
    }

    private func htmlMetadata(named name: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            #"<meta\b[^>]*(?:property|name)=["']\#(escaped)["'][^>]*content=["']([^"']+)["'][^>]*>"#,
            #"<meta\b[^>]*content=["']([^"']+)["'][^>]*(?:property|name)=["']\#(escaped)["'][^>]*>"#
        ]

        for pattern in patterns {
            if let value = firstRegexCapture(pattern, in: html) {
                return decodeHTMLEntities(value)
            }
        }

        return nil
    }

    private func titleTag(in html: String) -> String? {
        firstRegexCapture(#"<title[^>]*>(.*?)</title>"#, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators])
            .map { decodeHTMLEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func attribute(_ name: String, in tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return firstRegexCapture(#"\#(escaped)\s*=\s*["']([^"']+)["']"#, in: tag)
            .map(decodeHTMLEntities)
    }

    private func firstRegexCapture(
        _ pattern: String,
        in string: String,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range), match.numberOfRanges > 1 else { return nil }
        let captureIndex = match.numberOfRanges > 2 ? 2 : 1
        guard let captureRange = Range(match.range(at: captureIndex), in: string) else { return nil }
        return String(string[captureRange])
    }

    private func regexMatches(_ pattern: String, in string: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            Range(match.range, in: string).map { String(string[$0]) }
        }
    }

    private func regexCaptures(
        _ pattern: String,
        in string: String,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            let captureIndex = match.numberOfRanges > 2 ? 2 : 1
            guard match.numberOfRanges > captureIndex,
                  let captureRange = Range(match.range(at: captureIndex), in: string) else {
                return nil
            }
            return String(string[captureRange])
        }
    }

    private func decodeHTMLEntities(_ string: String) -> String {
        string.plainTextFromHTML() ?? string
    }

    private func fallbackTitle(for url: URL) -> String {
        let lastPathComponent = url.deletingPathExtension().lastPathComponent
        if lastPathComponent.isEmpty == false {
            return lastPathComponent.removingPercentEncoding ?? lastPathComponent
        }
        return url.host() ?? url.absoluteString
    }

    private func isSupportedSharedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "feed", "rss"].contains(scheme)
    }

    private func normalizedTitle(_ title: String) -> String {
        title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    private func fallbackSearchQuery(for url: URL, title: String? = nil) -> String? {
        let cleanedTitle = title?
            .replacingOccurrences(of: #"\s*[|–—-]\s*(?:episode|folge|podcast).*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanedTitle, cleanedTitle.isEmpty == false {
            return cleanedTitle
        }

        if let host = url.host(), host.isEmpty == false {
            let path = url.pathComponents
                .dropFirst()
                .filter { $0.isEmpty == false }
                .prefix(2)
                .joined(separator: " ")
                .removingPercentEncoding ?? ""
            return path.isEmpty ? host : "\(host) \(path)"
        }
        return nil
    }
}

private enum ResolvedSharedEpisode {
    case feed(
        draft: PodcastEpisodeDraft,
        episodes: [PodcastEpisodeDraft],
        feed: PodcastFeed
    )
    case standalone(StandaloneSharedEpisode)
    case podcast(feed: PodcastFeed)
    case unresolved(suggestedSearch: String?)
}

struct StandaloneSharedEpisode {
    let title: String
    let desc: String?
    let pageURL: URL
    let mediaURL: URL
    let mediaType: String?
    let imageURL: URL?
    let duration: Double?
}
