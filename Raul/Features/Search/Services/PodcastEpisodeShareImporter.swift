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

struct PodcastEpisodeShareImporter {
    @MainActor
    @discardableResult
    func importEpisode(from sharedURL: URL, modelContext: ModelContext) async throws -> URL {
        let resolved = try await resolveEpisode(from: sharedURL)
        return try upsert(resolved, sharedURL: sharedURL, modelContext: modelContext)
    }

    private func resolveEpisode(from sharedURL: URL) async throws -> ResolvedSharedEpisode {
        guard sharedURL.scheme?.isEmpty == false else {
            throw PodcastEpisodeShareImportError.unsupportedURL
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

        for feedURL in feedURLs {
            guard let page = try? await PodcastParser.fetchPage(from: feedURL) else { continue }
            if let draft = matchingEpisode(in: page.episodes, sharedURL: sharedURL) {
                return .feed(draft: draft, feed: page.feed)
            }
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

        throw PodcastEpisodeShareImportError.noEpisodeFound
    }

    @MainActor
    private func upsert(
        _ resolved: ResolvedSharedEpisode,
        sharedURL: URL,
        modelContext: ModelContext
    ) throws -> URL {
        switch resolved {
        case .feed(let draft, let feed):
            let podcast = upsertPodcast(from: feed, modelContext: modelContext)
            let episode = upsertEpisode(from: draft, podcast: podcast, modelContext: modelContext)
            markInInbox(episode)
            modelContext.saveIfNeeded()
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
            return episode.url ?? draft.episodeURL

        case .standalone(let standalone):
            let episode = upsertStandaloneEpisode(standalone, sharedURL: sharedURL, modelContext: modelContext)
            markInInbox(episode)
            modelContext.saveIfNeeded()
            NotificationCenter.default.post(name: .inboxDidChange, object: nil)
            return episode.url ?? standalone.mediaURL
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

        episode.metaData?.isInbox = true
        episode.metaData?.isArchived = false
        episode.metaData?.status = .inbox
        episode.metaData?.archivedAt = nil
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
        drafts.first { draft in
            urlsMatch(draft.link, sharedURL)
            || urlsMatch(draft.episodeURL, sharedURL)
            || draft.deeplinks.contains { urlsMatch($0, sharedURL) }
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

    private func discoverFeedURLs(in html: String, baseURL: URL) -> [URL] {
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
        guard let data = string.data(using: .utf8),
              let decoded = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ).string else {
            return string
        }

        return decoded
    }

    private func fallbackTitle(for url: URL) -> String {
        let lastPathComponent = url.deletingPathExtension().lastPathComponent
        if lastPathComponent.isEmpty == false {
            return lastPathComponent.removingPercentEncoding ?? lastPathComponent
        }
        return url.host() ?? url.absoluteString
    }
}

private enum ResolvedSharedEpisode {
    case feed(draft: PodcastEpisodeDraft, feed: PodcastFeed)
    case standalone(StandaloneSharedEpisode)
}

private struct StandaloneSharedEpisode {
    let title: String
    let desc: String?
    let pageURL: URL
    let mediaURL: URL
    let mediaType: String?
    let imageURL: URL?
    let duration: Double?
}
