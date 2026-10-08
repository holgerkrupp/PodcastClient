import Foundation

enum PodcastFeedResolution {
    case podcast(PodcastFeed)
    case requiresBasicAuth(URL)
    case requiresBearerToken(URL)
}

enum PodcastFeedResolverError: LocalizedError {
    case unsupportedURL
    case couldNotLoad(URL)
    case httpStatus(URL, Int, Date?)
    case notAPodcastFeed
    case unreadableFile
    case multipleFeedsInOPML
    case authenticationRequired(URL)
    case bearerAuthenticationRequired(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "This link is not a supported podcast feed URL."
        case .couldNotLoad(let url):
            return "Could not load \(url.redactedPodcastURLString)."
        case .httpStatus(_, let code, _):
            return "The feed server returned HTTP \(code)."
        case .notAPodcastFeed:
            return "This link did not contain a podcast feed."
        case .unreadableFile:
            return "The XML file could not be opened."
        case .multipleFeedsInOPML:
            return "This OPML file contains multiple podcasts. Use Import / Export to review them."
        case .authenticationRequired:
            return "This feed requires authentication."
        case .bearerAuthenticationRequired:
            return "This feed requires a bearer token."
        }
    }
}

enum PodcastFeedResolver {
    struct PreparedExistingEndpoint: Sendable {
        let url: URL
        let firstPage: PreparedPodcastFeedSeed?
    }

    static func resolvePreparedExistingEndpoint(
        from url: URL,
        profile: PodcastAccessProfile? = nil,
        knownEpisodeIdentifiers: KnownPodcastEpisodeIdentifiers = KnownPodcastEpisodeIdentifiers(),
        client: PodcastHTTPClient = .shared
    ) async throws -> PreparedExistingEndpoint {
        let resolved = try await resolveExistingEndpoint(
            from: url,
            profile: profile,
            allowHTMLDiscovery: false,
            knownEpisodeIdentifiers: knownEpisodeIdentifiers,
            client: client
        )
        return try PreparedExistingEndpoint(
            url: resolved.url ?? url,
            firstPage: resolved.initialImportSeed.map(PreparedPodcastFeedSeed.init)
        )
    }

    static func canResolve(_ url: URL) -> Bool {
        (try? unwrapIncomingURL(url)) != nil
    }

    static func resolve(
        url: URL,
        allowAuthenticationPrompt: Bool = false,
        client: PodcastHTTPClient = .shared
    ) async throws -> PodcastFeedResolution {
        let input = try unwrapIncomingURL(url)

        switch input {
        case .remote(let candidates):
            return try await resolveRemote(
                candidates: candidates,
                allowAuthenticationPrompt: allowAuthenticationPrompt,
                client: client
            )
        case .file(let fileURL):
            return .podcast(try await resolveFile(fileURL))
        }
    }

    /// Validates an already stored subscription endpoint before a refresh
    /// parses it. Unlike the onboarding API this retains the caller's access
    /// profile. Refresh callers disable HTML discovery so a stored feed URL
    /// cannot silently turn into the website's different RSS feed. HTTP
    /// redirects are still followed by the transport for the current request.
    static func resolveExistingEndpoint(
        from url: URL,
        profile: PodcastAccessProfile? = nil,
        allowHTMLDiscovery: Bool = true,
        knownEpisodeIdentifiers: KnownPodcastEpisodeIdentifiers = KnownPodcastEpisodeIdentifiers(),
        client: PodcastHTTPClient = .shared
    ) async throws -> PodcastFeed {
        let input = try unwrapIncomingURL(url)
        guard case .remote(let candidates) = input,
              let candidate = candidates.first else {
            throw PodcastFeedResolverError.unsupportedURL
        }
        return try await resolveRemote(
            candidate,
            visited: [],
            client: client,
            profile: profile,
            allowHTMLDiscovery: allowHTMLDiscovery,
            knownEpisodeIdentifiers: knownEpisodeIdentifiers
        )
    }

    /// Resolves a feed with a credential that has not yet been persisted. This
    /// keeps Bearer tokens out of URLs while still allowing the same parser and
    /// redirect policy to be used during onboarding.
    static func resolve(
        url: URL,
        credential: PodcastCredential
    ) async throws -> PodcastFeedResolution {
        let input = try unwrapIncomingURL(url)
        guard case .remote(let candidates) = input else {
            throw PodcastFeedResolverError.unsupportedURL
        }

        let kind: PodcastAccessKind
        switch credential {
        case .privateURL: kind = .privateURL
        case .httpBasic: kind = .httpBasic
        case .bearerToken: kind = .bearerToken
        }
        let requestURL = requestBaseURL(for: candidates[0], kind: kind)
        let profile = PodcastAccessProfile.make(for: requestURL, kind: kind)
        let store = InMemoryPodcastCredentialStore()
        try store.save(credential, for: profile)
        let client = PodcastHTTPClient(
            resolver: PodcastAccessResolver(credentialStore: store)
        )
        let feed = try await resolveRemote(
            requestURL,
            visited: [],
            client: client,
            profile: profile
        )
        feed.accessCredential = credential
        feed.accessKind = kind
        feed.url = requestURL
        return .podcast(feed)
    }

    /// The explicit private-feed entry point treats the pasted URL as a
    /// credential even when its provider uses an unknown query parameter name.
    /// This keeps arbitrary private-RSS formats safe without classifying every
    /// ordinary public feed query as a secret.
    static func resolvePrivateURL(_ url: URL) async throws -> PodcastFeedResolution {
        try await resolve(url: url, credential: .privateURL(url))
    }

    /// Header credentials must not change ordinary feed query parameters (for
    /// example `?format=rss`). A tokenized private URL is different: its query
    /// is the credential and is supplied by the private-URL credential itself.
    static func requestBaseURL(for url: URL, kind: PodcastAccessKind) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return kind == .privateURL ? url.podcastNonSecretURL : url
        }

        components.user = nil
        components.password = nil
        components.fragment = nil
        if kind == .privateURL {
            components.query = nil
        }
        return components.url ?? url
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
        case "feed", "pcast", "rss":
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
        allowAuthenticationPrompt: Bool,
        client: PodcastHTTPClient
    ) async throws -> PodcastFeedResolution {
        var lastError: Error?

        for candidate in candidates {
            do {
                let podcastFeed = try await resolveRemote(candidate, visited: [], client: client)
                return .podcast(podcastFeed)
            } catch PodcastFeedResolverError.authenticationRequired(let protectedURL) {
                if allowAuthenticationPrompt {
                    return .requiresBasicAuth(protectedURL)
                }
                throw PodcastFeedResolverError.authenticationRequired(protectedURL)
            } catch PodcastFeedResolverError.bearerAuthenticationRequired(let protectedURL) {
                if allowAuthenticationPrompt {
                    return .requiresBearerToken(protectedURL)
                }
                throw PodcastFeedResolverError.bearerAuthenticationRequired(protectedURL)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? PodcastFeedResolverError.notAPodcastFeed
    }

    static func resolveRemote(
        _ url: URL,
        visited: Set<String>,
        client: PodcastHTTPClient = .shared,
        profile: PodcastAccessProfile? = nil,
        allowHTMLDiscovery: Bool = true,
        knownEpisodeIdentifiers: KnownPodcastEpisodeIdentifiers = KnownPodcastEpisodeIdentifiers()
    ) async throws -> PodcastFeed {
        let visitKey = url.absoluteString.lowercased()
        guard visited.contains(visitKey) == false else {
            throw PodcastFeedResolverError.notAPodcastFeed
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.data(for: url, profile: profile)
        } catch let error as PodcastHTTPError {
            if error.advertisesHTTPBasicAuthentication {
                throw PodcastFeedResolverError.authenticationRequired(url)
            }
            if error.advertisedAuthenticationSchemes.contains("bearer") {
                throw PodcastFeedResolverError.bearerAuthenticationRequired(url)
            }
            if let statusCode = error.statusCode {
                throw PodcastFeedResolverError.httpStatus(error.url, statusCode, error.retryAfter)
            }
            throw PodcastFeedResolverError.couldNotLoad(error.url)
        }

        let httpResponse = response

        guard (200..<400).contains(httpResponse.statusCode) else {
            throw PodcastFeedResolverError.httpStatus(url, httpResponse.statusCode, nil)
        }

        let finalURL = response.url ?? url

        if looksLikeOPML(data) {
            throw PodcastFeedResolverError.multipleFeedsInOPML
        }

        if looksLikePodcastFeed(data) {
            return try await buildPodcastFeed(
                from: data,
                sourceURL: finalURL,
                requestedURL: url,
                knownEpisodeIdentifiers: knownEpisodeIdentifiers
            )
        }

        if allowHTMLDiscovery,
           let html = String(data: data, encoding: .utf8),
           let discoveredFeedURL = extractFeedURL(fromHTML: html, baseURL: finalURL) {
            var updatedVisited = visited
            updatedVisited.insert(visitKey)
            let feedURL = discoveredFeedURL.preservingFeedAccessComponents(from: finalURL)
            return try await resolveRemote(
                feedURL,
                visited: updatedVisited,
                client: client,
                profile: profile,
                allowHTMLDiscovery: allowHTMLDiscovery,
                knownEpisodeIdentifiers: knownEpisodeIdentifiers
            )
        }

        throw PodcastFeedResolverError.notAPodcastFeed
    }

    static func resolveFile(_ fileURL: URL) async throws -> PodcastFeed {
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

        return try await buildPodcastFeed(from: data, sourceURL: fileURL)
    }

    static func buildPodcastFeed(
        from data: Data,
        sourceURL: URL,
        requestedURL: URL? = nil,
        knownEpisodeIdentifiers: KnownPodcastEpisodeIdentifiers = KnownPodcastEpisodeIdentifiers()
    ) async throws -> PodcastFeed {
        let document = PodcastFeedDocument(
            data: data,
            sourceURL: sourceURL,
            requestedURL: requestedURL
        )
        let page = try await PodcastParser.parsePage(
            from: document,
            maximumEpisodes: 5_000,
            knownEpisodeIdentifiers: knownEpisodeIdentifiers
        )
        page.feed.initialImportSeed = PodcastFeedImportSeed(page: page, sourceURL: page.feed.url ?? sourceURL)
        return page.feed
    }

    static func nestedURL(from url: URL) -> URL? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let rawValue = components?.queryItems?.first(where: {
            let name = $0.name.lowercased()
            return name == "url" || name == "feed" || name == "rss"
        })?.value {
            return nestedURL(fromPayload: rawValue)
        }

        let rawURL = url.absoluteString
        let lowercasedURL = rawURL.lowercased()
        let prefix: String

        if lowercasedURL.hasPrefix("upnext://") {
            prefix = "upnext://"
        } else if lowercasedURL.hasPrefix("upnext:") {
            prefix = "upnext:"
        } else {
            return nil
        }

        var payload = String(rawURL.dropFirst(prefix.count))

        if payload.lowercased().hasPrefix("subscribe/") {
            payload = String(payload.dropFirst("subscribe/".count))
        } else if payload.lowercased().hasPrefix("subscribe?") {
            return nil
        }

        return nestedURL(fromPayload: payload)
    }

    static func nestedURL(fromPayload payload: String) -> URL? {
        let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedPayload.isEmpty == false else {
            return nil
        }

        let rawValue = trimmedPayload.removingPercentEncoding ?? trimmedPayload

        guard rawValue.lowercased() != "subscribe" else {
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

        for prefix in ["feed://", "pcast://", "rss://", "feed:", "pcast:", "rss:"] {
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
}

// Feed discovery from an HTML page. Shared with public-broadcaster discovery,
// whose directory-backed providers reach a feed the same way.
extension PodcastFeedResolver {
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
