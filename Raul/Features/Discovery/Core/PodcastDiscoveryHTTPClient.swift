//
//  PodcastDiscoveryHTTPClient.swift
//  Raul
//
//  The single networking entry point for podcast discovery. Providers never talk
//  to URLSession directly, which keeps timeouts, status/content-type validation,
//  HTTP caching and cancellation behaviour in one place — and lets tests inject
//  a transport instead of hitting broadcaster servers.
//

import Foundation

struct PodcastDiscoveryHTTPClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// What a response is allowed to be. Providers state their expectation so a
    /// captive portal or an HTML error page never reaches a JSON decoder.
    enum ExpectedContent: Sendable {
        case json
        case markup

        func accepts(_ contentType: String?) -> Bool {
            guard let contentType = contentType?.lowercased() else {
                // Some public endpoints omit the header entirely; the decode step
                // is the real gate in that case.
                return true
            }

            switch self {
            case .json:
                return contentType.contains("json") || contentType.contains("javascript")
            case .markup:
                return contentType.contains("html")
                    || contentType.contains("xml")
                    || contentType.contains("text/plain")
            }
        }

        var headerValue: String {
            switch self {
            case .json: return "application/json"
            case .markup: return "text/html,application/xhtml+xml,application/xml;q=0.9"
            }
        }
    }

    static let shared = PodcastDiscoveryHTTPClient()

    private let transport: Transport
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 20, transport: Transport? = nil) {
        self.timeout = timeout
        self.transport = transport ?? Self.sharedSessionTransport
    }

    /// A session of its own so discovery traffic gets an HTTP cache without
    /// competing with feed downloads for `URLSession.shared`'s cache.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            diskPath: "podcast-discovery"
        )
        configuration.waitsForConnectivity = false
        // Accept-Encoding is deliberately left to URLSession: setting it here
        // would hand back still-compressed bytes.
        return URLSession(configuration: configuration)
    }()

    private static let sharedSessionTransport: Transport = { request in
        try await session.data(for: request)
    }

    func data(
        from url: URL,
        expecting expectedContent: ExpectedContent,
        refresh: Bool = false
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.setValue(expectedContent.headerValue, forHTTPHeaderField: "Accept")
        // Nothing about the user's library, subscriptions or listening history is
        // ever sent: a plain GET for a public catalogue is all a provider needs.
        request.cachePolicy = refresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw PodcastDiscoveryError.unavailable
        }

        try Task.checkCancellation()

        if let httpResponse = response as? HTTPURLResponse {
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw PodcastDiscoveryError.unavailable
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
            guard expectedContent.accepts(contentType) else {
                throw PodcastDiscoveryError.invalidResponse
            }
        }

        guard data.isEmpty == false else {
            throw PodcastDiscoveryError.invalidResponse
        }

        return data
    }

    func json<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from url: URL,
        refresh: Bool = false,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Value {
        let data = try await data(from: url, expecting: .json, refresh: refresh)

        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw PodcastDiscoveryError.parsingFailed
        }
    }

    func markup(from url: URL, refresh: Bool = false) async throws -> String {
        let data = try await data(from: url, expecting: .markup, refresh: refresh)

        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        if let text = String(data: data, encoding: .isoLatin1) {
            return text
        }

        throw PodcastDiscoveryError.parsingFailed
    }
}
