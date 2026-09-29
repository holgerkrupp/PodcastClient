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

    func enrich(_ candidates: [ShownoteLinkCandidate]) async -> [ShownoteEnrichmentResult] {
        let unique = Array(
            Dictionary(grouping: candidates, by: \.normalizedURL)
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
            if let feed = try await podcastFeed(from: resource, requestedURL: candidate.normalizedURL, loader: loader) {
                return ShownoteEnrichmentResult(
                    candidateID: candidate.id,
                    normalizedURL: candidate.normalizedURL,
                    finalURL: feed.url ?? resource.responseURL,
                    statusCode: resource.statusCode,
                    mimeType: resource.mimeType,
                    classification: .podcast,
                    podcastFeed: feed,
                    expiresAt: now.addingTimeInterval(24 * 60 * 60)
                )
            }

            return ShownoteEnrichmentResult(
                candidateID: candidate.id,
                normalizedURL: candidate.normalizedURL,
                finalURL: resource.responseURL,
                statusCode: resource.statusCode,
                mimeType: resource.mimeType,
                classification: .web,
                podcastFeed: nil,
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
            return try await parseFeed(resource.data, sourceURL: resource.responseURL, requestedURL: requestedURL)
        }

        guard let html = String(data: resource.data, encoding: .utf8),
              let discoveredURL = PodcastFeedResolver.extractFeedURL(fromHTML: html, baseURL: resource.responseURL) else {
            return nil
        }

        let discovered = try await loader.load(discoveredURL)
        guard looksLikeFeed(discovered.data) else { return nil }
        return try await parseFeed(discovered.data, sourceURL: discovered.responseURL, requestedURL: discoveredURL)
    }

    private static func parseFeed(_ data: Data, sourceURL: URL, requestedURL: URL) async throws -> PodcastFeed {
        let page = try await PodcastParser.parsePage(
            from: PodcastFeedDocument(data: data, sourceURL: sourceURL, requestedURL: requestedURL),
            maximumEpisodes: 1
        )
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
            expiresAt: expiresAt
        )
    }
}
