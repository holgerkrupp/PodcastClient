import Foundation
import os

private enum ShownoteEnrichmentPerformance {
    static let log = OSLog(subsystem: "de.holgerkrupp.PodcastClient", category: "Shownotes")
}

struct ShownoteHTTPResource: Sendable {
    let data: Data
    let responseURL: URL
    let statusCode: Int
    let mimeType: String?
}

protocol ShownoteResourceLoader: Sendable {
    func load(_ url: URL) async throws -> ShownoteHTTPResource
}

enum ShownoteResolutionError: Error, Sendable {
    case invalidResponse
    case responseTooLarge
    case redirectLimitReached
    case unsupportedResource
}

struct URLSessionShownoteResourceLoader: ShownoteResourceLoader {
    let maximumResponseBytes: Int
    let maximumRedirects: Int
    let timeout: TimeInterval

    init(
        maximumResponseBytes: Int = 512 * 1024,
        maximumRedirects: Int = 4,
        timeout: TimeInterval = 12
    ) {
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumRedirects = maximumRedirects
        self.timeout = timeout
    }

    func load(_ url: URL) async throws -> ShownoteHTTPResource {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html,application/xhtml+xml,application/rss+xml,application/atom+xml,application/xml;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false

        let redirectDelegate = ShownoteRedirectDelegate(maximumRedirects: maximumRedirects)
        let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ShownoteResolutionError.invalidResponse
        }
        guard (200..<400).contains(httpResponse.statusCode) else {
            throw ShownoteResolutionError.unsupportedResource
        }
        if httpResponse.expectedContentLength > Int64(maximumResponseBytes) {
            throw ShownoteResolutionError.responseTooLarge
        }
        guard data.count <= maximumResponseBytes else {
            throw ShownoteResolutionError.responseTooLarge
        }

        return ShownoteHTTPResource(
            data: data,
            responseURL: httpResponse.url ?? url,
            statusCode: httpResponse.statusCode,
            mimeType: httpResponse.mimeType
        )
    }
}

private final class ShownoteRedirectDelegate: NSObject, @unchecked Sendable, URLSessionTaskDelegate {
    private let maximumRedirects: Int
    private var redirectCount = 0

    init(maximumRedirects: Int) {
        self.maximumRedirects = maximumRedirects
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard redirectCount < maximumRedirects else {
            completionHandler(nil)
            return
        }
        redirectCount += 1
        completionHandler(request)
    }
}

private actor ShownoteRequestLimiter {
    static let shared = ShownoteRequestLimiter(limit: 3)

    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        active += 1
    }

    func release() {
        active = max(0, active - 1)
        if let continuation = waiters.first {
            waiters.removeFirst()
            continuation.resume()
        }
    }
}

struct ShownoteEnrichmentResult: Sendable {
    let candidateID: String
    let normalizedURL: URL
    let finalURL: URL?
    let statusCode: Int?
    let mimeType: String?
    let classification: ShownoteLinkClassification
    let podcastFeed: PodcastFeed?
    let preview: ShownotePreviewMetadata?
    let expiresAt: Date
}

actor ShownoteEnrichmentService {
    static let shared = ShownoteEnrichmentService()

    private struct CacheEntry: Sendable {
        let result: ShownoteEnrichmentResult
        let expiresAt: Date
    }

    private let loader: any ShownoteResourceLoader
    private let maximumCandidatesPerEpisode: Int
    private var cache: [URL: CacheEntry] = [:]
    private var inFlight: [URL: Task<ShownoteEnrichmentResult, Never>] = [:]

    init(
        loader: any ShownoteResourceLoader = URLSessionShownoteResourceLoader(),
        maximumCandidatesPerEpisode: Int = 24
    ) {
        self.loader = loader
        self.maximumCandidatesPerEpisode = maximumCandidatesPerEpisode
    }

    /// Starts low-priority enrichment for feed-owned HTML. This is deliberately
    /// fire-and-forget: feed persistence should not wait for recommendation
    /// pages, and the UI must never be the place that starts this work.
    func enqueue(htmlSources: [String]) {
        let sources = htmlSources.filter { $0.isEmpty == false }
        guard sources.isEmpty == false else { return }

        Task(priority: .utility) {
            for html in sources {
                guard Task.isCancelled == false else { return }
                let document = await ShownoteParser.shared.parse(html)
                _ = await enrich(document.candidates)
            }
        }
    }

    /// Returns only results already held by the in-memory cache. In particular,
    /// this method never invokes the resource loader and is safe for view tasks.
    func cachedResults(
        for candidates: [ShownoteLinkCandidate],
        now: Date = Date()
    ) -> [ShownoteEnrichmentResult] {
        var seen = Set<URL>()
        return candidates.compactMap { candidate in
            guard seen.insert(candidate.normalizedURL).inserted,
                  let entry = cache[candidate.normalizedURL],
                  entry.expiresAt > now else {
                return nil
            }
            return entry.result
        }
    }

    func enrich(_ candidates: [ShownoteLinkCandidate]) async -> [ShownoteEnrichmentResult] {
        let unique = Array(
            Dictionary(grouping: candidates.filter { candidate in
                ["http", "https"].contains(candidate.normalizedURL.scheme?.lowercased())
            }, by: \.normalizedURL)
                .values
                .compactMap(\.first)
                .prefix(maximumCandidatesPerEpisode)
        )

        var results: [ShownoteEnrichmentResult] = []
        for batch in stride(from: 0, to: unique.count, by: 3) {
            let end = min(batch + 3, unique.count)
            let batchResults = await withTaskGroup(of: ShownoteEnrichmentResult.self) { group in
                for candidate in unique[batch..<end] {
                    group.addTask { await self.resolve(candidate) }
                }
                var collected: [ShownoteEnrichmentResult] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            results.append(contentsOf: batchResults)
        }
        return results
    }

    func resolve(_ candidate: ShownoteLinkCandidate) async -> ShownoteEnrichmentResult {
        if Task.isCancelled {
            return Self.negativeResult(for: candidate, classification: .unsupported, expiresAt: Date().addingTimeInterval(60))
        }
        let key = candidate.normalizedURL
        if let cached = cache[key], cached.expiresAt > Date() {
            return cached.result
        }

        if let task = inFlight[key] {
            return await task.value
        }

        let loader = loader
        let task = Task(priority: .utility) {
            await ShownoteRequestLimiter.shared.acquire()
            defer { Task { await ShownoteRequestLimiter.shared.release() } }
            if Task.isCancelled {
                return Self.negativeResult(for: candidate, classification: .unsupported, expiresAt: Date().addingTimeInterval(60))
            }
            return await Self.resolve(candidate: candidate, loader: loader)
        }
        inFlight[key] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inFlight[key] = nil
        cache[key] = CacheEntry(result: result, expiresAt: result.expiresAt)
        return result
    }

    private static func resolve(
        candidate: ShownoteLinkCandidate,
        loader: any ShownoteResourceLoader
    ) async -> ShownoteEnrichmentResult {
        let signpostID = OSSignpostID(log: ShownoteEnrichmentPerformance.log)
        os_signpost(.begin, log: ShownoteEnrichmentPerformance.log, name: "Shownote enrichment", signpostID: signpostID)
        defer { os_signpost(.end, log: ShownoteEnrichmentPerformance.log, name: "Shownote enrichment", signpostID: signpostID) }
        let now = Date()
        do {
            let resource = try await loader.load(candidate.normalizedURL)

            // Mastodon profile pages publish an Atom timeline link as part of
            // their HTML. Identify the profile before looking for a podcast
            // feed so that timeline XML can never acquire podcast semantics.
            if let html = String(data: resource.data, encoding: .utf8),
               let mastodonPreview = ShownotePreviewParser.mastodon(
                   from: html,
                   responseURL: resource.responseURL
               ) {
                return ShownoteEnrichmentResult(
                    candidateID: candidate.id,
                    normalizedURL: candidate.normalizedURL,
                    finalURL: mastodonPreview.canonicalURL ?? resource.responseURL,
                    statusCode: resource.statusCode,
                    mimeType: resource.mimeType,
                    classification: .mastodon,
                    podcastFeed: nil,
                    preview: mastodonPreview,
                    expiresAt: now.addingTimeInterval(12 * 60 * 60)
                )
            }

            if let feed = try await podcastFeed(from: resource, requestedURL: candidate.normalizedURL, loader: loader) {
                return ShownoteEnrichmentResult(
                    candidateID: candidate.id,
                    normalizedURL: candidate.normalizedURL,
                    finalURL: feed.url ?? resource.responseURL,
                    statusCode: resource.statusCode,
                    mimeType: resource.mimeType,
                    classification: .podcast,
                    podcastFeed: feed,
                    preview: nil,
                    expiresAt: now.addingTimeInterval(24 * 60 * 60)
                )
            }

            let preview = String(data: resource.data, encoding: .utf8).map {
                ShownotePreviewParser.web(from: $0, responseURL: resource.responseURL)
            }

            return ShownoteEnrichmentResult(
                candidateID: candidate.id,
                normalizedURL: candidate.normalizedURL,
                finalURL: preview?.canonicalURL ?? resource.responseURL,
                statusCode: resource.statusCode,
                mimeType: resource.mimeType,
                classification: .web,
                podcastFeed: nil,
                preview: preview,
                expiresAt: now.addingTimeInterval(6 * 60 * 60)
            )
        } catch is CancellationError {
            return negativeResult(for: candidate, classification: .unsupported, expiresAt: now.addingTimeInterval(60 * 5))
        } catch {
            return negativeResult(for: candidate, classification: .unsupported, expiresAt: now.addingTimeInterval(15 * 60))
        }
    }

    private static func podcastFeed(
        from resource: ShownoteHTTPResource,
        requestedURL: URL,
        loader: any ShownoteResourceLoader
    ) async throws -> PodcastFeed? {
        if looksLikeFeed(resource.data) {
            // A feed-shaped response is not enough. Only a successful podcast
            // parse is allowed to produce the podcast classification; invalid
            // XML/RSS remains an ordinary web resource.
            return try? await parseFeed(resource.data, sourceURL: resource.responseURL, requestedURL: requestedURL)
        }

        guard let html = String(data: resource.data, encoding: .utf8),
              let discoveredURL = PodcastFeedResolver.extractFeedURL(fromHTML: html, baseURL: resource.responseURL) else {
            return nil
        }

        guard let discovered = try? await loader.load(discoveredURL) else { return nil }
        guard looksLikeFeed(discovered.data) else { return nil }
        return try? await parseFeed(discovered.data, sourceURL: discovered.responseURL, requestedURL: discoveredURL)
    }

    private static func parseFeed(_ data: Data, sourceURL: URL, requestedURL: URL) async throws -> PodcastFeed {
        let page = try await PodcastParser.parsePage(
            from: PodcastFeedDocument(data: data, sourceURL: sourceURL, requestedURL: requestedURL),
            maximumEpisodes: 1
        )
        guard let title = page.parsedFeed["title"] as? String,
              title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ShownoteResolutionError.unsupportedResource
        }
        return page.feed
    }

    private static func looksLikeFeed(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        return prefix.contains("<rss") || prefix.contains("<feed") || prefix.contains("<channel")
    }

    private static func negativeResult(
        for candidate: ShownoteLinkCandidate,
        classification: ShownoteLinkClassification,
        expiresAt: Date
    ) -> ShownoteEnrichmentResult {
        ShownoteEnrichmentResult(
            candidateID: candidate.id,
            normalizedURL: candidate.normalizedURL,
            finalURL: nil,
            statusCode: nil,
            mimeType: nil,
            classification: classification,
            podcastFeed: nil,
            preview: nil,
            expiresAt: expiresAt
        )
    }
}

private enum ShownotePreviewParser {
    private static let mastodonProfilePath = try? NSRegularExpression(
        pattern: #"(?i)(?:^|/)@([a-z0-9_\-\.]+)(?:/|$)"#
    )
    private static let handlePattern = try? NSRegularExpression(
        pattern: #"(?i)@[a-z0-9_\-\.]+@[a-z0-9\.\-]+"#
    )

    static func web(from html: String, responseURL: URL) -> ShownotePreviewMetadata {
        let metadata = Metadata(html: html, responseURL: responseURL)
        return ShownotePreviewMetadata(
            title: metadata.value(for: ["og:title", "twitter:title"]) ?? metadata.title,
            description: metadata.value(for: ["og:description", "twitter:description", "description"]),
            imageURL: metadata.urlValue(for: ["og:image", "twitter:image"]),
            siteName: metadata.value(for: ["og:site_name", "application-name"]),
            canonicalURL: metadata.canonicalURL
        )
    }

    static func mastodon(from html: String, responseURL: URL) -> ShownotePreviewMetadata? {
        guard let host = responseURL.host,
              let pathMatch = mastodonProfilePath?.firstMatch(
                  in: responseURL.path,
                  options: [],
                  range: NSRange(location: 0, length: responseURL.path.utf16.count)
              ) else {
            return nil
        }

        let metadata = Metadata(html: html, responseURL: responseURL)
        let titleValue = metadata.value(for: ["og:title", "twitter:title"])
        let lowercasedHTML = html.lowercased()
        let hasActivityProfile = lowercasedHTML.contains("application/activity+json")
            || lowercasedHTML.contains("name=\"application-name\"") && lowercasedHTML.contains("mastodon")
            || lowercasedHTML.contains("name=\"generator\"") && lowercasedHTML.contains("mastodon")
        let hasHandleTitle = titleValue.flatMap {
            handlePattern?.firstMatch(in: $0, options: [], range: NSRange(location: 0, length: $0.utf16.count))
        } != nil
        guard hasActivityProfile || hasHandleTitle else { return nil }

        let pathUsername = Range(pathMatch.range(at: 1), in: responseURL.path).map {
            String(responseURL.path[$0])
        }
        let handle = titleValue
            .flatMap { handlePattern?.firstMatch(in: $0, options: [], range: NSRange(location: 0, length: $0.utf16.count)) }
            .flatMap { match -> String? in
                guard let range = Range(match.range, in: titleValue ?? "") else {
                    return nil
                }
                return String((titleValue ?? "")[range])
            }
            ?? pathUsername.map { "@\($0)@\(host)" }

        let title = titleValue
            ?? metadata.title
            ?? pathUsername.map { "@\($0)" }
        let canonical = metadata.canonicalURL ?? profileURL(username: pathUsername, host: host, responseURL: responseURL)

        return ShownotePreviewMetadata(
            title: title,
            description: metadata.value(for: ["og:description", "twitter:description", "description"]),
            imageURL: metadata.urlValue(for: ["og:image", "twitter:image"]),
            siteName: metadata.value(for: ["og:site_name", "application-name"]) ?? host,
            canonicalURL: canonical,
            handle: handle
        )
    }

    private static func profileURL(username: String?, host: String, responseURL: URL) -> URL? {
        guard let username, var components = URLComponents(url: responseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/@\(username)"
        components.query = nil
        components.fragment = nil
        components.host = host
        return components.url
    }

    private struct Metadata {
        let values: [String: String]
        let title: String?
        let canonicalURL: URL?
        let responseURL: URL

        init(html: String, responseURL: URL) {
            var values: [String: String] = [:]
            let metaTags = Self.matches(of: #"(?is)<meta\b[^>]*>"#, in: html)
            for tag in metaTags {
                guard let key = Self.attribute(named: "property", in: tag)?.lowercased()
                        ?? Self.attribute(named: "name", in: tag)?.lowercased(),
                      let value = Self.attribute(named: "content", in: tag),
                      value.isEmpty == false else { continue }
                values[key] = Self.decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let title = Self.matches(of: #"(?is)<title\b[^>]*>(.*?)</title\s*>"#, in: html)
                .first
                .map { Self.decodeEntities(Self.stripTags($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
            let linkedCanonical = Self.matches(of: #"(?is)<link\b[^>]*>"#, in: html)
                .compactMap { tag -> URL? in
                    guard Self.attribute(named: "rel", in: tag)?.lowercased().split(separator: " ").contains("canonical") == true,
                          let href = Self.attribute(named: "href", in: tag),
                          let url = URL(string: Self.decodeEntities(href), relativeTo: responseURL)?.absoluteURL,
                          ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
                    return url
                }
                .first
            let canonical = linkedCanonical
                ?? values["og:url"].flatMap {
                    URL(string: Self.decodeEntities($0), relativeTo: responseURL)?.absoluteURL
                }
                .flatMap { url in
                    ["http", "https"].contains(url.scheme?.lowercased()) ? url : nil
                }

            self.values = values
            self.title = title
            self.canonicalURL = canonical
            self.responseURL = responseURL
        }

        func value(for keys: [String]) -> String? {
            keys.lazy.compactMap { values[$0] }.first
        }

        func urlValue(for keys: [String]) -> URL? {
            guard let value = value(for: keys) else { return nil }
            return URL(string: value, relativeTo: responseURL)?.absoluteURL
        }

        private static func matches(of pattern: String, in string: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
            let range = NSRange(location: 0, length: string.utf16.count)
            return regex.matches(in: string, options: [], range: range).compactMap { match in
                guard let swiftRange = Range(match.range, in: string) else { return nil }
                return String(string[swiftRange])
            }
        }

        private static func attribute(named name: String, in tag: String) -> String? {
            let pattern = "(?i)\\b" + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(in: tag, options: [], range: NSRange(location: 0, length: tag.utf16.count)) else {
                return nil
            }
            for index in 1...3 {
                guard match.range(at: index).location != NSNotFound,
                      let range = Range(match.range(at: index), in: tag) else { continue }
                return String(tag[range])
            }
            return nil
        }

        private static func stripTags(_ value: String) -> String {
            value.replacingOccurrences(of: #"(?is)<[^>]*>"#, with: "", options: .regularExpression)
        }

        private static func decodeEntities(_ value: String) -> String {
            var result = value
            [
                "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                "&lt;": "<", "&gt;": ">", "&nbsp;": " "
            ].forEach { result = result.replacingOccurrences(of: $0.key, with: $0.value) }
            let decimalPattern = #"&#(\d+);"#
            if let regex = try? NSRegularExpression(pattern: decimalPattern) {
                let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count)).reversed()
                for match in matches {
                    guard let range = Range(match.range, in: result),
                          let numberRange = Range(match.range(at: 1), in: result),
                          let scalarValue = Int(result[numberRange]),
                          let scalar = UnicodeScalar(scalarValue) else { continue }
                    result.replaceSubrange(range, with: String(Character(scalar)))
                }
            }
            return result
        }
    }
}
