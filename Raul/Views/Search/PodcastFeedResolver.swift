import Foundation

enum PodcastFeedResolution {
    case podcast(PodcastFeed)
    case requiresBasicAuth(URL)
}

enum PodcastFeedResolverError: LocalizedError {
    case unsupportedURL
    case couldNotLoad(URL)
    case notAPodcastFeed
    case unreadableFile
    case multipleFeedsInOPML
    case authenticationRequired(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "This link is not a supported podcast feed URL."
        case .couldNotLoad(let url):
            return "Could not load \(url.absoluteString)."
        case .notAPodcastFeed:
            return "This link did not contain a podcast feed."
        case .unreadableFile:
            return "The XML file could not be opened."
        case .multipleFeedsInOPML:
            return "This OPML file contains multiple podcasts. Use Import / Export to review them."
        case .authenticationRequired:
            return "This feed requires authentication."
        }
    }
}

enum PodcastFeedResolver {
    static func canResolve(_ url: URL) -> Bool {
        (try? unwrapIncomingURL(url)) != nil
    }

    static func resolve(url: URL, allowAuthenticationPrompt: Bool = false) async throws -> PodcastFeedResolution {
        let input = try unwrapIncomingURL(url)

        switch input {
        case .remote(let candidates):
            return try await resolveRemote(candidates: candidates, allowAuthenticationPrompt: allowAuthenticationPrompt)
        case .file(let fileURL):
            return .podcast(try resolveFile(fileURL))
        }
    }
}

private extension PodcastFeedResolver {
    enum Input {
        case remote([URL])
        case file(URL)
    }

    static func unwrapIncomingURL(_ url: URL) throws -> Input {
        guard let scheme = url.scheme?.lowercased() else {
            throw PodcastFeedResolverError.unsupportedURL
        }

        switch scheme {
        case "http", "https":
            return .remote([url])
        case "feed", "pcast", "itpc", "rss":
            let candidates = remoteCandidates(fromPodcastSchemeURL: url)
            guard candidates.isEmpty == false else {
                throw PodcastFeedResolverError.unsupportedURL
            }
            return .remote(candidates)
        case "file":
            return .file(url)
        case "upnext":
            guard let nestedURL = nestedURL(from: url) else {
                throw PodcastFeedResolverError.unsupportedURL
            }
            return try unwrapIncomingURL(nestedURL)
        default:
            throw PodcastFeedResolverError.unsupportedURL
        }
    }

    static func resolveRemote(
        candidates: [URL],
        allowAuthenticationPrompt: Bool
    ) async throws -> PodcastFeedResolution {
        var lastError: Error?

        for candidate in candidates {
            do {
                let podcastFeed = try await resolveRemote(candidate, visited: [])
                return .podcast(podcastFeed)
            } catch PodcastFeedResolverError.authenticationRequired(let protectedURL) {
                if allowAuthenticationPrompt {
                    return .requiresBasicAuth(protectedURL)
                }
                throw PodcastFeedResolverError.authenticationRequired(protectedURL)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? PodcastFeedResolverError.notAPodcastFeed
    }

    static func resolveRemote(_ url: URL, visited: Set<String>) async throws -> PodcastFeed {
        let visitKey = url.absoluteString.lowercased()
        guard visited.contains(visitKey) == false else {
            throw PodcastFeedResolverError.notAPodcastFeed
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PodcastFeedResolverError.couldNotLoad(url)
        }

        if httpResponse.statusCode == 401 {
            throw PodcastFeedResolverError.authenticationRequired(url)
        }

        guard (200..<400).contains(httpResponse.statusCode) else {
            throw PodcastFeedResolverError.couldNotLoad(url)
        }

        let finalURL = response.url ?? url

        if looksLikeOPML(data) {
            throw PodcastFeedResolverError.multipleFeedsInOPML
        }

        if looksLikePodcastFeed(data) {
            return try buildPodcastFeed(from: data, sourceURL: finalURL)
        }

        if let html = String(data: data, encoding: .utf8),
           let discoveredFeedURL = extractFeedURL(fromHTML: html, baseURL: finalURL) {
            var updatedVisited = visited
            updatedVisited.insert(visitKey)
            return try await resolveRemote(discoveredFeedURL, visited: updatedVisited)
        }

        throw PodcastFeedResolverError.notAPodcastFeed
    }

    static func resolveFile(_ fileURL: URL) throws -> PodcastFeed {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data

        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw PodcastFeedResolverError.unreadableFile
        }

        if looksLikeOPML(data) {
            let parser = XMLParser(data: data)
            let opmlParser = OPMLParser()
            parser.delegate = opmlParser

            guard parser.parse() else {
                throw PodcastFeedResolverError.unreadableFile
            }

            let feeds = opmlParser.podcastFeeds

            if feeds.count == 1, let feed = feeds.first {
                return feed
            }

            if feeds.count > 1 {
                throw PodcastFeedResolverError.multipleFeedsInOPML
            }

            throw PodcastFeedResolverError.unreadableFile
        }

        return try buildPodcastFeed(from: data, sourceURL: fileURL)
    }

    static func buildPodcastFeed(from data: Data, sourceURL: URL) throws -> PodcastFeed {
        let parserDelegate = PodcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate

        guard parser.parse() else {
            throw PodcastFeedResolverError.notAPodcastFeed
        }

        let parsedFeed = parserDelegate.podcastDictArr
        guard parsedFeed.isEmpty == false else {
            throw PodcastFeedResolverError.notAPodcastFeed
        }

        let canonicalURL = canonicalFeedURL(from: parsedFeed, sourceURL: sourceURL)
        let podcastFeed = PodcastFeed(url: canonicalURL, fetchMetadataIfNeeded: false)
        let fallbackURL = canonicalURL ?? (sourceURL.isFileURL ? nil : sourceURL)
        podcastFeed.apply(parsedFeed: parsedFeed, fallbackURL: fallbackURL)
        return podcastFeed
    }

    static func canonicalFeedURL(from parsedFeed: [String: Any], sourceURL: URL) -> URL? {
        if let selfURLString = parsedFeed["selfURL"] as? String,
           let selfURL = URL(string: selfURLString, relativeTo: sourceURL)?.absoluteURL {
            return selfURL
        }

        if sourceURL.isFileURL {
            return nil
        }

        return sourceURL
    }

    static func nestedURL(from url: URL) -> URL? {
        let host = url.host?.lowercased()
        let path = url.path.lowercased()

        guard host == "subscribe" || path == "/subscribe" else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let rawValue = components?.queryItems?.first {
            let name = $0.name.lowercased()
            return name == "url" || name == "feed"
        }?.value

        guard let rawValue else {
            return nil
        }

        if let nestedURL = URL(string: rawValue), nestedURL.scheme != nil {
            return nestedURL
        }

        return URL(string: "https://\(rawValue)")
    }

    static func remoteCandidates(fromPodcastSchemeURL url: URL) -> [URL] {
        let rawURL = url.absoluteString
        let lowercased = rawURL.lowercased()

        for prefix in ["feed://", "pcast://", "itpc://", "rss://", "feed:", "pcast:", "itpc:", "rss:"] {
            if lowercased.hasPrefix(prefix + "https://") || lowercased.hasPrefix(prefix + "http://") {
                let trimmed = String(rawURL.dropFirst(prefix.count))
                if let nestedURL = URL(string: trimmed) {
                    return [nestedURL]
                }
            }
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              host.isEmpty == false else {
            return []
        }

        var candidates: [URL] = []

        components.scheme = "https"
        if let httpsURL = components.url {
            candidates.append(httpsURL)
        }

        components.scheme = "http"
        if let httpURL = components.url, candidates.contains(httpURL) == false {
            candidates.append(httpURL)
        }

        return candidates
    }

    static func looksLikePodcastFeed(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        return prefix.contains("<rss") || prefix.contains("<feed") || prefix.contains("<channel")
    }

    static func looksLikeOPML(_ data: Data) -> Bool {
        String(decoding: data.prefix(4096), as: UTF8.self).lowercased().contains("<opml")
    }

    static func extractFeedURL(fromHTML html: String, baseURL: URL) -> URL? {
        let tagPattern = #"<link\b[^>]*>"#

        guard let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = tagRegex.matches(in: html, options: [], range: nsRange)

        for match in matches {
            guard let matchRange = Range(match.range, in: html) else { continue }
            let tag = String(html[matchRange])
            let lowercasedTag = tag.lowercased()

            guard lowercasedTag.contains("alternate"),
                  lowercasedTag.contains("application/rss+xml") || lowercasedTag.contains("application/atom+xml"),
                  let href = hrefValue(fromLinkTag: tag),
                  let feedURL = URL(string: href, relativeTo: baseURL)?.absoluteURL else {
                continue
            }

            return feedURL
        }

        return nil
    }

    static func hrefValue(fromLinkTag tag: String) -> String? {
        let hrefPattern = #"href\s*=\s*["']([^"']+)["']"#

        guard let hrefRegex = try? NSRegularExpression(pattern: hrefPattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)

        guard let match = hrefRegex.firstMatch(in: tag, options: [], range: nsRange),
              let hrefRange = Range(match.range(at: 1), in: tag) else {
            return nil
        }

        return String(tag[hrefRange])
    }
}
