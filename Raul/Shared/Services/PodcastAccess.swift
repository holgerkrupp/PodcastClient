import Foundation
import CryptoKit

#if canImport(Security)
import Security
#endif

enum PodcastAccessKind: String, Codable, Hashable, Sendable {
    case publicFeed
    case privateURL
    case httpBasic
    case bearerToken
}

enum PodcastCredentialState: String, Codable, Hashable, Sendable {
    case available
    case missing
    case expired
    case revoked
    case needsLogin
    case unsupported
}

enum PodcastCredential: Codable, Equatable, Sendable {
    case privateURL(URL)
    case httpBasic(username: String, password: String)
    case bearerToken(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case url
        case username
        case password
        case token
    }

    private enum Kind: String, Codable {
        case privateURL
        case httpBasic
        case bearerToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .privateURL:
            self = .privateURL(try container.decode(URL.self, forKey: .url))
        case .httpBasic:
            self = .httpBasic(
                username: try container.decode(String.self, forKey: .username),
                password: try container.decode(String.self, forKey: .password)
            )
        case .bearerToken:
            self = .bearerToken(try container.decode(String.self, forKey: .token))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .privateURL(let url):
            try container.encode(Kind.privateURL, forKey: .kind)
            try container.encode(url, forKey: .url)
        case .httpBasic(let username, let password):
            try container.encode(Kind.httpBasic, forKey: .kind)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
        case .bearerToken(let token):
            try container.encode(Kind.bearerToken, forKey: .kind)
            try container.encode(token, forKey: .token)
        }
    }
}

struct PodcastAccessProfile: Codable, Equatable, Hashable, Sendable {
    let id: String
    let kind: PodcastAccessKind
    /// A credential-free URL used to identify the resource origin. It is safe
    /// to place in synchronized user state and diagnostics.
    let resourceURL: URL?
    /// Private URLs and Basic credentials may opt into iCloud Keychain. Bearer
    /// tokens default to device-only storage unless a provider explicitly says
    /// they are safe to synchronize.
    let synchronizableCredential: Bool

    init(
        id: String,
        kind: PodcastAccessKind,
        resourceURL: URL?,
        synchronizableCredential: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.resourceURL = resourceURL?.podcastNonSecretURL
        self.synchronizableCredential = synchronizableCredential
    }

    static func make(
        for url: URL,
        kind: PodcastAccessKind? = nil,
        synchronizableCredential: Bool = false
    ) -> PodcastAccessProfile {
        let resolvedKind = kind ?? (url.isLikelyPrivatePodcastURL ? .privateURL : .publicFeed)
        let safeURL = url.podcastNonSecretURL
        return PodcastAccessProfile(
            id: PodcastAccessProfileID.make(for: safeURL),
            kind: resolvedKind,
            resourceURL: safeURL,
            synchronizableCredential: synchronizableCredential
        )
    }
}

enum PodcastAccessProfileID {
    static func make(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.podcastNonSecretURL.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "podcast-access-" + String(hex.prefix(32))
    }
}

enum PodcastCredentialStoreError: LocalizedError, Equatable {
    case unavailable
    case invalidData
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Secure credential storage is unavailable."
        case .invalidData:
            return "The saved podcast credential could not be read."
        case .keychain(let status):
            return "Secure credential storage failed (\(status))."
        }
    }
}

protocol PodcastCredentialStore: Sendable {
    func save(_ credential: PodcastCredential, for profile: PodcastAccessProfile) throws
    func credential(for profile: PodcastAccessProfile) throws -> PodcastCredential?
    func removeCredential(for profile: PodcastAccessProfile) throws
}

#if canImport(Security)
final class KeychainPodcastCredentialStore: PodcastCredentialStore, @unchecked Sendable {
    static let shared = KeychainPodcastCredentialStore()

    private let service = "de.holgerkrupp.PodcastClient.podcast-credentials"

    func save(_ credential: PodcastCredential, for profile: PodcastAccessProfile) throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(for: profile)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: profile.synchronizableCredential
                ? kSecAttrAccessibleAfterFirstUnlock
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            if profile.synchronizableCredential {
                addQuery[kSecAttrSynchronizable] = kCFBooleanTrue as Any
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw PodcastCredentialStoreError.keychain(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw PodcastCredentialStoreError.keychain(updateStatus)
        }
    }

    func credential(for profile: PodcastAccessProfile) throws -> PodcastCredential? {
        var query = baseQuery(for: profile)
        query[kSecReturnData] = kCFBooleanTrue as Any
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw PodcastCredentialStoreError.keychain(status)
        }
        guard let data = result as? Data else {
            throw PodcastCredentialStoreError.invalidData
        }
        do {
            return try JSONDecoder().decode(PodcastCredential.self, from: data)
        } catch {
            throw PodcastCredentialStoreError.invalidData
        }
    }

    func removeCredential(for profile: PodcastAccessProfile) throws {
        let status = SecItemDelete(baseQuery(for: profile) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PodcastCredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(for profile: PodcastAccessProfile) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: profile.id,
            kSecAttrSynchronizable: profile.synchronizableCredential
                ? kCFBooleanTrue as Any
                : kCFBooleanFalse as Any
        ]
        return query
    }
}
#else
final class KeychainPodcastCredentialStore: PodcastCredentialStore, @unchecked Sendable {
    static let shared = KeychainPodcastCredentialStore()

    func save(_ credential: PodcastCredential, for profile: PodcastAccessProfile) throws {
        throw PodcastCredentialStoreError.unavailable
    }

    func credential(for profile: PodcastAccessProfile) throws -> PodcastCredential? {
        throw PodcastCredentialStoreError.unavailable
    }

    func removeCredential(for profile: PodcastAccessProfile) throws {
        throw PodcastCredentialStoreError.unavailable
    }
}
#endif

final class InMemoryPodcastCredentialStore: PodcastCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: PodcastCredential] = [:]

    func save(_ credential: PodcastCredential, for profile: PodcastAccessProfile) throws {
        lock.lock()
        values[profile.id] = credential
        lock.unlock()
    }

    func credential(for profile: PodcastAccessProfile) throws -> PodcastCredential? {
        lock.lock()
        defer { lock.unlock() }
        return values[profile.id]
    }

    func removeCredential(for profile: PodcastAccessProfile) throws {
        lock.lock()
        values.removeValue(forKey: profile.id)
        lock.unlock()
    }
}

enum PodcastAccessError: LocalizedError, Equatable {
    case credentialMissing(String)
    case credentialKindMismatch
    case unauthorizedResource(URL)
    case invalidCredentialURL

    var errorDescription: String? {
        switch self {
        case .credentialMissing:
            return "Podcast credentials are required on this device."
        case .credentialKindMismatch:
            return "The saved podcast credential has the wrong type."
        case .unauthorizedResource:
            return "The podcast credential cannot be sent to this resource."
        case .invalidCredentialURL:
            return "The saved private podcast URL is invalid."
        }
    }
}

enum PodcastHTTPError: LocalizedError, Equatable {
    case invalidResponse(URL)
    case httpStatus(code: Int, url: URL, wwwAuthenticate: String?)

    var statusCode: Int? {
        guard case .httpStatus(let code, _, _) = self else { return nil }
        return code
    }

    var wwwAuthenticate: String? {
        guard case .httpStatus(_, _, let value) = self else { return nil }
        return value
    }

    var advertisesHTTPBasicAuthentication: Bool {
        guard let wwwAuthenticate else { return false }
        let scheme = wwwAuthenticate
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        return scheme
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("basic") == true
    }

    var url: URL {
        switch self {
        case .invalidResponse(let url), .httpStatus(_, let url, _):
            return url
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The podcast server returned an invalid response."
        case .httpStatus(let code, _, _):
            return "Podcast server returned HTTP \(code)."
        }
    }
}

struct PodcastAccessResolver: Sendable {
    let credentialStore: any PodcastCredentialStore

    init(credentialStore: any PodcastCredentialStore = KeychainPodcastCredentialStore.shared) {
        self.credentialStore = credentialStore
    }

    func credentialState(for profile: PodcastAccessProfile) -> PodcastCredentialState {
        do {
            return try credentialStore.credential(for: profile) == nil ? .missing : .available
        } catch {
            return .missing
        }
    }

    func request(
        for url: URL,
        profile: PodcastAccessProfile? = nil
    ) throws -> URLRequest {
        guard let profile, profile.kind != .publicFeed else {
            return URLRequest(podcastFeedURL: url)
        }

        guard let resourceURL = profile.resourceURL,
              url.hasPodcastSameOrigin(as: resourceURL) else {
            throw PodcastAccessError.unauthorizedResource(url)
        }

        guard let credential = try credentialStore.credential(for: profile) else {
            throw PodcastAccessError.credentialMissing(profile.id)
        }

        var authorizedURL = url
        var request = URLRequest(podcastFeedURL: url)
        switch (profile.kind, credential) {
        case (.privateURL, .privateURL(let privateURL)):
            authorizedURL = url.preservingFeedAccessComponents(from: privateURL)
            request = URLRequest(podcastFeedURL: authorizedURL)
        case (.httpBasic, .httpBasic(let username, let password)):
            let value = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
        case (.bearerToken, .bearerToken(let token)):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        default:
            throw PodcastAccessError.credentialKindMismatch
        }

        request.url = authorizedURL
        return request
    }

    func resolvedURL(
        for profile: PodcastAccessProfile,
        fallbackURL: URL
    ) throws -> URL? {
        guard let credential = try credentialStore.credential(for: profile) else {
            return nil
        }

        switch (profile.kind, credential) {
        case (.privateURL, .privateURL(let url)):
            return url
        case (.httpBasic, .httpBasic(let username, let password)):
            guard var components = URLComponents(url: fallbackURL, resolvingAgainstBaseURL: false) else {
                throw PodcastAccessError.invalidCredentialURL
            }
            components.user = username
            components.password = password
            return components.url
        case (.bearerToken, .bearerToken):
            // Bearer credentials must stay in the request header and cannot be
            // represented by a URL stored in a legacy local model.
            return fallbackURL
        default:
            throw PodcastAccessError.credentialKindMismatch
        }
    }

    func request(
        for url: URL,
        profile: PodcastAccessProfile?,
        redirectingFrom previousURL: URL
    ) throws -> URLRequest {
        guard let profile,
              let resourceURL = profile.resourceURL,
              url.hasPodcastSameOrigin(as: resourceURL) else {
            return URLRequest(podcastFeedURL: url)
        }
        return try request(for: url, profile: profile)
    }
}

protocol PodcastHTTPTransport: Sendable {
    func data(
        for request: URLRequest,
        profile: PodcastAccessProfile?,
        resolver: PodcastAccessResolver
    ) async throws -> (Data, URLResponse)
}

struct URLSessionPodcastHTTPTransport: PodcastHTTPTransport {
    func data(
        for request: URLRequest,
        profile: PodcastAccessProfile?,
        resolver: PodcastAccessResolver
    ) async throws -> (Data, URLResponse) {
        // Use the same redirect policy for public and private feeds. For a
        // same-origin redirect, this preserves access query items such as a
        // personal-feed token when the Location value omits them. The policy
        // never forwards them to another origin.
        let delegate = PodcastRedirectDelegate(resolver: resolver, profile: profile)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)

        let result = try await session.data(for: request)
        session.finishTasksAndInvalidate()
        return result
    }
}

final class PodcastHTTPClient: @unchecked Sendable {
    static let shared = PodcastHTTPClient()

    private let resolver: PodcastAccessResolver
    private let transport: any PodcastHTTPTransport

    init(
        resolver: PodcastAccessResolver = PodcastAccessResolver(),
        transport: any PodcastHTTPTransport = URLSessionPodcastHTTPTransport()
    ) {
        self.resolver = resolver
        self.transport = transport
    }

    func data(
        for url: URL,
        profile: PodcastAccessProfile? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try resolver.request(for: url, profile: profile)
        return try await data(for: request, profile: profile)
    }

    func data(
        for request: URLRequest,
        profile: PodcastAccessProfile? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let requestedURL = request.url ?? URL(string: "about:blank")!
        let (data, response) = try await transport.data(
            for: request,
            profile: profile,
            resolver: resolver
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PodcastHTTPError.invalidResponse(response.url ?? requestedURL)
        }
        guard (200..<400).contains(httpResponse.statusCode) else {
            throw PodcastHTTPError.httpStatus(
                code: httpResponse.statusCode,
                url: httpResponse.url ?? requestedURL,
                wwwAuthenticate: httpResponse.value(forHTTPHeaderField: "WWW-Authenticate")
            )
        }
        return (data, httpResponse)
    }
}

private final class PodcastRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let resolver: PodcastAccessResolver
    private let profile: PodcastAccessProfile?

    init(resolver: PodcastAccessResolver, profile: PodcastAccessProfile?) {
        self.resolver = resolver
        self.profile = profile
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(nil)
            return
        }

        let previousURL = task.currentRequest?.url ?? response.url ?? url
        do {
            if let profile {
                completionHandler(
                    try resolver.request(
                        for: url,
                        profile: profile,
                        redirectingFrom: previousURL
                    )
                )
            } else {
                let redirectedURL = url
                    .preservingFeedAccessComponents(from: previousURL)
                var redirectedRequest = URLRequest(podcastFeedURL: redirectedURL)
                redirectedRequest.httpMethod = request.httpMethod
                redirectedRequest.timeoutInterval = request.timeoutInterval
                completionHandler(redirectedRequest)
            }
        } catch {
            // A redirect outside the authorized origin is followed without
            // credentials by the resolver's redirecting overload. If the
            // request cannot be reconstructed, stop rather than leaking the
            // original request's headers.
            completionHandler(nil)
        }
    }
}

extension URL {
    var isLikelyPrivatePodcastURL: Bool {
        if user != nil || password != nil { return true }
        return URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.isEmpty == false
    }

    var podcastNonSecretURL: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url ?? self
    }

    var redactedPodcastURLString: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return "<invalid-url>"
        }

        let hasSensitiveComponents = user != nil
            || password != nil
            || URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.isEmpty == false
        components.user = components.user.map { _ in "<redacted>" }
        components.password = components.password.map { _ in "<redacted>" }
        if let queryItems = components.queryItems, queryItems.isEmpty == false {
            components.queryItems = queryItems.map { URLQueryItem(name: $0.name, value: "<redacted>") }
        }
        if hasSensitiveComponents, components.path.isEmpty == false {
            components.path = "/<redacted-path>"
        }
        return components.string ?? "<invalid-url>"
    }

    func hasPodcastSameOrigin(as other: URL) -> Bool {
        guard scheme?.lowercased() == other.scheme?.lowercased(),
              host?.lowercased() == other.host?.lowercased() else {
            return false
        }
        func effectivePort(_ url: URL) -> Int? {
            if let port = url.port { return port }
            return url.scheme?.lowercased() == "http" ? 80 : 443
        }
        return effectivePort(self) == effectivePort(other)
    }
}
