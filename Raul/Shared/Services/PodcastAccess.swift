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

/// A provider is only a hint for onboarding and presentation. It is never the
/// security boundary: authorization is still decided by the access profile's
/// origin and credential kind.
enum PremiumPodcastProviderID: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case patreon
    case substack
    case supercast
    case supportingCast
    case memberful
    case zeit
    case genericPrivateFeed

    var id: String { rawValue }
}

struct PremiumPodcastProviderDescriptor: Codable, Hashable, Sendable, Identifiable {
    let id: PremiumPodcastProviderID
    let displayName: String
    let hosts: [String]
    let helpURL: URL?
    let onboardingText: String
    let supportsAccountAuthentication: Bool
    let supportsThirdPartyPlayback: Bool

    var identifier: PremiumPodcastProviderID { id }

    func matches(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}

enum PremiumPodcastProviderRegistry {
    static let descriptors: [PremiumPodcastProviderDescriptor] = [
        PremiumPodcastProviderDescriptor(
            id: .patreon,
            displayName: "Patreon",
            hosts: ["patreon.com"],
            helpURL: URL(string: "https://support.patreon.com/hc/en-us/articles/360041347732-How-to-use-your-audio-RSS"),
            onboardingText: "Paste the private RSS link from your Patreon membership. Treat it like a password and do not share it.",
            supportsAccountAuthentication: false,
            supportsThirdPartyPlayback: true
        ),
        PremiumPodcastProviderDescriptor(
            id: .substack,
            displayName: "Substack",
            hosts: ["substack.com"],
            helpURL: URL(string: "https://support.substack.com/hc/en-us/articles/360041722272-Will-my-Podcast-RSS-feed-show-paid-only-content"),
            onboardingText: "Paste the subscriber RSS link supplied by the publication.",
            supportsAccountAuthentication: false,
            supportsThirdPartyPlayback: true
        ),
        PremiumPodcastProviderDescriptor(
            id: .supercast,
            displayName: "Supercast",
            hosts: ["supercast.com"],
            helpURL: URL(string: "https://www.supercast.com/blog/what-is-a-private-rss-feed"),
            onboardingText: "Use the private RSS link from your Supercast member page.",
            supportsAccountAuthentication: false,
            supportsThirdPartyPlayback: true
        ),
        PremiumPodcastProviderDescriptor(
            id: .supportingCast,
            displayName: "Supporting Cast",
            hosts: ["supportingcast.fm"],
            helpURL: URL(string: "https://www.supportingcast.fm/"),
            onboardingText: "Paste the personal RSS link provided by the publisher or Supporting Cast.",
            supportsAccountAuthentication: false,
            supportsThirdPartyPlayback: true
        ),
        PremiumPodcastProviderDescriptor(
            id: .memberful,
            displayName: "Memberful",
            hosts: ["memberful.com"],
            helpURL: URL(string: "https://memberful.com/podcasts"),
            onboardingText: "Paste the private podcast feed from your Memberful account.",
            supportsAccountAuthentication: false,
            supportsThirdPartyPlayback: true
        ),
        PremiumPodcastProviderDescriptor(
            id: .zeit,
            displayName: "ZEIT Podcast Abo",
            hosts: ["zeit.de"],
            helpURL: URL(string: "https://www.zeit.de/angebote"),
            onboardingText: "Paste the personal RSS link from your ZEIT Podcast Abo. The link itself grants access.",
            supportsAccountAuthentication: false,
            supportsThirdPartyPlayback: true
        ),
        PremiumPodcastProviderDescriptor(
            id: .genericPrivateFeed,
            displayName: "Private RSS feed",
            hosts: [],
            helpURL: nil,
            onboardingText: "Paste the private RSS link supplied by your podcast provider.",
            supportsAccountAuthentication: false,
            supportsThirdPartyPlayback: true
        )
    ]

    static func descriptor(for providerID: PremiumPodcastProviderID?) -> PremiumPodcastProviderDescriptor? {
        guard let providerID else { return nil }
        return descriptors.first { $0.id == providerID }
    }

    static func descriptor(for url: URL) -> PremiumPodcastProviderDescriptor {
        descriptors.first { $0.matches(host: url.host) && $0.id != .genericPrivateFeed }
            ?? descriptors.first { $0.id == .genericPrivateFeed }!
    }

    static func detectProviderID(for url: URL) -> PremiumPodcastProviderID? {
        guard url.isLikelyPrivatePodcastURL else { return nil }
        return descriptor(for: url).id
    }
}

struct PremiumPodcastProviderAccount: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let providerID: PremiumPodcastProviderID
    let displayIdentifier: String?
    let entitlement: String
    let lastValidatedAt: Date?
}

enum PremiumPodcastProviderAuthError: LocalizedError, Equatable, Sendable {
    case cancelled
    case unsupported
    case expired
    case revoked
    case notEntitled

    var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .unsupported: "This provider does not support account linking in Up Next."
        case .expired: "The provider session has expired."
        case .revoked: "The provider session was revoked."
        case .notEntitled: "This account no longer has access to the podcast."
        }
    }
}

/// Provider integrations stay behind this boundary. Private-RSS providers
/// intentionally use `unsupported` rather than pretending that a website
/// password can be used as an app login.
protocol PremiumPodcastProviderAdapter: Sendable {
    var providerID: PremiumPodcastProviderID { get }
    func authorize() async throws -> PremiumPodcastProviderAccount
    func reauthorize() async throws -> PremiumPodcastProviderAccount
    func signOut() async throws
    func resolveFeeds(for account: PremiumPodcastProviderAccount) async throws -> [URL]
}

extension PremiumPodcastProviderAdapter {
    func resolveFeed(for account: PremiumPodcastProviderAccount) async throws -> URL? {
        try await resolveFeeds(for: account).first
    }
}

/// A deterministic adapter used by tests and previews. It also documents the
/// lifecycle expected from a real OAuth/ASWebAuthenticationSession adapter.
actor MockPremiumPodcastProviderAdapter: PremiumPodcastProviderAdapter {
    nonisolated let providerID: PremiumPodcastProviderID = .genericPrivateFeed
    private var account: PremiumPodcastProviderAccount?
    private let feedURLs: [URL]
    private var entitlement = "active"
    private var nextReauthorizationError: PremiumPodcastProviderAuthError?

    init(feedURL: URL? = nil) {
        self.feedURLs = feedURL.map { [$0] } ?? []
    }

    init(feedURLs: [URL]) {
        self.feedURLs = feedURLs
    }

    func authorize() async throws -> PremiumPodcastProviderAccount {
        let account = PremiumPodcastProviderAccount(
            id: "mock-account",
            providerID: providerID,
            displayIdentifier: "mock@example.com",
            entitlement: entitlement,
            lastValidatedAt: Date()
        )
        self.account = account
        return account
    }

    func reauthorize() async throws -> PremiumPodcastProviderAccount {
        if let error = nextReauthorizationError {
            nextReauthorizationError = nil
            throw error
        }
        return try await authorize()
    }

    func setEntitlement(_ entitlement: String) {
        self.entitlement = entitlement
        guard let account else { return }
        self.account = PremiumPodcastProviderAccount(
            id: account.id,
            providerID: account.providerID,
            displayIdentifier: account.displayIdentifier,
            entitlement: entitlement,
            lastValidatedAt: account.lastValidatedAt
        )
    }

    func failNextReauthorization(with error: PremiumPodcastProviderAuthError) {
        nextReauthorizationError = error
    }

    func signOut() async throws {
        account = nil
    }

    func resolveFeeds(for account: PremiumPodcastProviderAccount) async throws -> [URL] {
        guard self.account?.id == account.id else {
            throw PremiumPodcastProviderAuthError.revoked
        }
        guard self.account?.entitlement == "active" else {
            throw PremiumPodcastProviderAuthError.notEntitled
        }
        return feedURLs
    }
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
    /// Provider hint used for onboarding/help and approved resource origins.
    let providerID: PremiumPodcastProviderID?
    /// Whether the credential is eligible for iCloud Keychain synchronization.
    /// The policy below currently keeps every credential device-only; a future
    /// provider must explicitly opt in before a token or password can leave the
    /// device.
    let synchronizableCredential: Bool

    init(
        id: String,
        kind: PodcastAccessKind,
        resourceURL: URL?,
        synchronizableCredential: Bool = false,
        providerID: PremiumPodcastProviderID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.resourceURL = kind == .publicFeed
            ? resourceURL
            : resourceURL?.podcastNonSecretURL
        self.providerID = providerID
        self.synchronizableCredential = synchronizableCredential
            && PodcastCredentialSyncPolicy.allowsSynchronizableStorage(
                for: kind,
                providerID: providerID
            )
    }

    static func make(
        for url: URL,
        kind: PodcastAccessKind? = nil,
        synchronizableCredential: Bool = false,
        providerID: PremiumPodcastProviderID? = nil
    ) -> PodcastAccessProfile {
        let resolvedKind = kind ?? (url.isLikelyPrivatePodcastURL ? .privateURL : .publicFeed)
        let safeURL = resolvedKind == .publicFeed
            ? url
            : url.podcastNonSecretURL
        return PodcastAccessProfile(
            id: PodcastAccessProfileID.make(for: safeURL),
            kind: resolvedKind,
            resourceURL: safeURL,
            synchronizableCredential: synchronizableCredential,
            providerID: providerID ?? PremiumPodcastProviderRegistry.detectProviderID(for: url)
        )
    }
}

/// Explicit credential-sync policy for cross-device recovery. Private RSS
/// URLs and Basic credentials are technically eligible for a future provider
/// opt-in, while bearer tokens are never synchronized by default. No current
/// provider has declared its credential safe to sync, so all current profiles
/// remain device-only.
enum PodcastCredentialSyncPolicy {
    static func allowsSynchronizableStorage(
        for kind: PodcastAccessKind,
        providerID: PremiumPodcastProviderID?
    ) -> Bool {
        switch kind {
        case .privateURL, .httpBasic:
            return providerID == nil
                ? false
                : explicitlyApprovedProviderIDs.contains(providerID!)
        case .bearerToken, .publicFeed:
            return false
        }
    }

    private static let explicitlyApprovedProviderIDs: Set<PremiumPodcastProviderID> = []
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
    static let serviceIdentifier = "de.holgerkrupp.PodcastClient.podcast-credentials"

    private let service = KeychainPodcastCredentialStore.serviceIdentifier

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

/// Namespaces credentials for a system-managed user/profile on a shared
/// device. The scope is hashed before it becomes part of the backing-store
/// account key, so a current-user identifier never appears in Keychain
/// metadata. Synchronized subscription records continue to use the ordinary
/// credential-free profile ID; only the local secret lookup is scoped.
final class ScopedPodcastCredentialStore: PodcastCredentialStore, @unchecked Sendable {
    private let backing: any PodcastCredentialStore
    private let namespace: String

    init(
        scopeID: String,
        backing: any PodcastCredentialStore = KeychainPodcastCredentialStore.shared
    ) {
        self.backing = backing
        let digest = SHA256.hash(data: Data(scopeID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        namespace = "podcast-user-scope-" + String(hex.prefix(32))
    }

    func save(_ credential: PodcastCredential, for profile: PodcastAccessProfile) throws {
        try backing.save(credential, for: scopedProfile(profile))
    }

    func credential(for profile: PodcastAccessProfile) throws -> PodcastCredential? {
        try backing.credential(for: scopedProfile(profile))
    }

    func removeCredential(for profile: PodcastAccessProfile) throws {
        try backing.removeCredential(for: scopedProfile(profile))
    }

    private func scopedProfile(_ profile: PodcastAccessProfile) -> PodcastAccessProfile {
        PodcastAccessProfile(
            id: namespace + ":" + profile.id,
            kind: profile.kind,
            resourceURL: profile.resourceURL,
            synchronizableCredential: profile.synchronizableCredential,
            providerID: profile.providerID
        )
    }
}

/// The app-wide credential-store hook. Phone, Mac, and Watch use the ordinary
/// device Keychain by default. A current-user client such as tvOS can install
/// a scoped store during launch before constructing its bootstrap services;
/// synchronized subscription metadata remains unchanged.
final class PodcastCredentialStoreRuntime: @unchecked Sendable {
    static let shared = PodcastCredentialStoreRuntime()

    private let lock = NSLock()
    private var store: any PodcastCredentialStore = KeychainPodcastCredentialStore.shared

    private init() {}

    func current() -> any PodcastCredentialStore {
        lock.lock()
        defer { lock.unlock() }
        return store
    }

    func configure(
        currentUserScopeID: String?,
        backing: any PodcastCredentialStore = KeychainPodcastCredentialStore.shared
    ) {
        lock.lock()
        if let currentUserScopeID, currentUserScopeID.isEmpty == false {
            store = ScopedPodcastCredentialStore(
                scopeID: currentUserScopeID,
                backing: backing
            )
        } else {
            store = backing
        }
        lock.unlock()
    }
}

enum PodcastCredentialStoreProvider {
    static var current: any PodcastCredentialStore {
        PodcastCredentialStoreRuntime.shared.current()
    }

    static func configure(
        currentUserScopeID: String?,
        backing: any PodcastCredentialStore = KeychainPodcastCredentialStore.shared
    ) {
        PodcastCredentialStoreRuntime.shared.configure(
            currentUserScopeID: currentUserScopeID,
            backing: backing
        )
    }
}

enum PodcastAccessError: LocalizedError, Equatable {
    case credentialMissing(String)
    case credentialKindMismatch
    case unauthorizedResource(URL)
    case invalidCredentialURL
    case authenticationFailed

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
        case .authenticationFailed:
            return "The podcast credentials were rejected."
        }
    }
}

/// The result of deciding whether a synchronized subscription may be
/// bootstrapped on this device. The credential-required case always carries a
/// credential-free feed identity. A ready decision may carry the authorized
/// URL transiently for the in-memory bootstrap request; it is never persisted
/// in UserState or emitted in diagnostics.
enum PodcastBootstrapDecision: Equatable, Sendable {
    case publicFeed(URL)
    case ready(URL)
    case credentialsRequired(profileID: String, feedURL: URL)
}

/// Pure manifest-to-bootstrap planning shared by the tvOS bootstrap target
/// and fixture tests. The synchronized record supplies only credential-free
/// metadata; the injected/default resolver decides whether this device can
/// use the local credential namespace.
struct PodcastPremiumBootstrapPlan: Equatable, Sendable {
    let profile: PodcastAccessProfile
    let title: String
    let host: String
    let decision: PodcastBootstrapDecision
}

enum PodcastPremiumBootstrapPlanner {
    static func plan(
        feedURL: URL,
        title: String?,
        accessProfileID: String?,
        accessKindRawValue: String?,
        accessProviderIDRawValue: String?,
        resolver: PodcastAccessResolver = PodcastAccessResolver()
    ) -> PodcastPremiumBootstrapPlan {
        let kind = PodcastAccessKind(rawValue: accessKindRawValue ?? "")
            ?? (feedURL.isLikelyPrivatePodcastURL ? .privateURL : .publicFeed)
        let providerID = accessProviderIDRawValue.flatMap(PremiumPodcastProviderID.init(rawValue:))
        let profile = PodcastAccessProfile(
            id: accessProfileID ?? PodcastAccessProfileID.make(for: feedURL),
            kind: kind,
            resourceURL: feedURL,
            providerID: providerID
        )
        return PodcastPremiumBootstrapPlan(
            profile: profile,
            title: title?.isEmpty == false ? title! : (feedURL.host ?? "Podcast"),
            host: feedURL.host ?? feedURL.absoluteString,
            decision: resolver.bootstrapDecision(for: profile, fallbackURL: feedURL)
        )
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

    var advertisedAuthenticationSchemes: Set<String> {
        guard let wwwAuthenticate else { return [] }
        return Set(wwwAuthenticate
            .split(separator: ",")
            .compactMap { part in
                part.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: " ", maxSplits: 1)
                    .first
                    .map { $0.lowercased() }
            })
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
    private let injectedCredentialStore: (any PodcastCredentialStore)?

    init(credentialStore: (any PodcastCredentialStore)? = nil) {
        self.injectedCredentialStore = credentialStore
    }

    /// An explicitly injected store is stable for deterministic restore and
    /// fixture work. The production default is resolved for each operation so
    /// a current-user/keychain-scope change cannot leave a long-lived client
    /// reading the previous user's credentials.
    private var credentialStore: any PodcastCredentialStore {
        injectedCredentialStore ?? PodcastCredentialStoreProvider.current
    }

    func credentialState(for profile: PodcastAccessProfile) -> PodcastCredentialState {
        do {
            return try credentialStore.credential(for: profile) == nil ? .missing : .available
        } catch {
            return .missing
        }
    }

    func credential(for profile: PodcastAccessProfile) -> PodcastCredential? {
        try? credentialStore.credential(for: profile)
    }

    func save(_ credential: PodcastCredential, for profile: PodcastAccessProfile) throws {
        try credentialStore.save(credential, for: profile)
    }

    func removeCredential(for profile: PodcastAccessProfile) throws {
        try credentialStore.removeCredential(for: profile)
    }

    /// Produces a deterministic, side-effect-free bootstrap decision. Callers
    /// can use `.credentialsRequired` to retain the subscription and present a
    /// re-authentication affordance without attempting the protected feed.
    func bootstrapDecision(
        for profile: PodcastAccessProfile?,
        fallbackURL: URL
    ) -> PodcastBootstrapDecision {
        guard let profile, profile.kind != .publicFeed else {
            return .publicFeed(fallbackURL)
        }

        do {
            guard try credentialStore.credential(for: profile) != nil else {
                return .credentialsRequired(
                    profileID: profile.id,
                    feedURL: fallbackURL.podcastNonSecretURL
                )
            }
            guard let resolvedURL = try resolvedURL(for: profile, fallbackURL: fallbackURL) else {
                return .credentialsRequired(
                    profileID: profile.id,
                    feedURL: fallbackURL.podcastNonSecretURL
                )
            }
            return .ready(resolvedURL)
        } catch {
            return .credentialsRequired(profileID: profile.id, feedURL: fallbackURL.podcastNonSecretURL)
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
              allowsResource(url, for: profile, resourceURL: resourceURL) else {
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

    private func allowsResource(
        _ url: URL,
        for profile: PodcastAccessProfile,
        resourceURL: URL
    ) -> Bool {
        if url.hasPodcastSameOrigin(as: resourceURL) { return true }
        guard let provider = PremiumPodcastProviderRegistry.descriptor(for: profile.providerID),
              provider.supportsThirdPartyPlayback else { return false }
        return provider.matches(host: url.host)
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
        case (.httpBasic, .httpBasic):
            // Basic credentials belong in the request header. Returning a
            // user-info URL here would make restored feed lookup appear to be
            // a different podcast from the credential-free synced record.
            return fallbackURL
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
              canForwardCredentials(
                to: url,
                from: previousURL,
                resourceURL: resourceURL
              ) else {
            return URLRequest(podcastFeedURL: url)
        }
        return try request(for: url, profile: profile)
    }

    /// Redirects are a narrower boundary than direct media/resource access.
    /// A provider may explicitly authorize a CDN for a direct request, but a
    /// redirect must never widen the set of hosts that receive credentials.
    /// The only cross-scheme exception is the conventional HTTP-to-HTTPS
    /// upgrade on the same host and effective port.
    private func canForwardCredentials(
        to url: URL,
        from previousURL: URL,
        resourceURL: URL
    ) -> Bool {
        guard sameStrictCredentialOrigin(previousURL, as: resourceURL),
              sameHostAndPort(url, as: resourceURL) else {
            return false
        }

        let targetScheme = url.scheme?.lowercased()
        let resourceScheme = resourceURL.scheme?.lowercased()
        guard let targetScheme, let resourceScheme else { return false }
        return targetScheme == resourceScheme
            || (resourceScheme == "http" && targetScheme == "https")
    }

    private func sameStrictCredentialOrigin(_ lhs: URL, as rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              ["http", "https"].contains(lhsScheme),
              ["http", "https"].contains(rhsScheme),
              lhsScheme == rhsScheme else {
            return false
        }
        return sameHostAndPort(lhs, as: rhs)
    }

    private func sameHostAndPort(_ lhs: URL, as rhs: URL) -> Bool {
        guard lhs.host?.lowercased() == rhs.host?.lowercased() else {
            return false
        }
        let effectivePort: (URL) -> Int? = { url in
            if let port = url.port { return port }
            return url.scheme?.lowercased() == "http" ? 80 : 443
        }
        return effectivePort(lhs) == effectivePort(rhs)
    }
}

protocol PodcastHTTPTransport: Sendable {
    func data(
        for request: URLRequest,
        profile: PodcastAccessProfile?,
        resolver: PodcastAccessResolver
    ) async throws -> (Data, URLResponse)
}

enum PodcastURLSessionTransportError: Error, Sendable {
    case missingResponse
}

private final class PodcastURLSessionTaskCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isCancelled = false

    func install(_ task: URLSessionDataTask) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// Uses URLSession's callback API so cancellation and nil callback values are
/// handled explicitly instead of relying on Foundation's async bridge.
func podcastURLSessionData(
    for request: URLRequest,
    using session: URLSession
) async throws -> (Data, URLResponse) {
    let cancellationBox = PodcastURLSessionTaskCancellationBox()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: PodcastURLSessionTransportError.missingResponse)
                    return
                }
                continuation.resume(returning: (data, response))
            }
            cancellationBox.install(task)
            task.resume()
        }
    } onCancel: {
        cancellationBox.cancel()
    }
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
        defer { session.finishTasksAndInvalidate() }
        return try await podcastURLSessionData(for: request, using: session)
    }
}

final class PodcastHTTPClient: @unchecked Sendable {
    static let shared = PodcastHTTPClient()

    private let injectedResolver: PodcastAccessResolver?
    private let transport: any PodcastHTTPTransport

    init(
        resolver: PodcastAccessResolver? = nil,
        transport: any PodcastHTTPTransport = URLSessionPodcastHTTPTransport()
    ) {
        self.injectedResolver = resolver
        self.transport = transport
    }

    private var resolver: PodcastAccessResolver {
        injectedResolver ?? PodcastAccessResolver()
    }

    func data(
        for url: URL,
        profile: PodcastAccessProfile? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let activeResolver = resolver
        let request = try activeResolver.request(for: url, profile: profile)
        return try await perform(
            request: request,
            profile: profile,
            resolver: activeResolver
        )
    }

    func data(
        for request: URLRequest,
        profile: PodcastAccessProfile? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let activeResolver = resolver
        let authorizedRequest = try requestUsingCurrentCredential(
            for: request,
            profile: profile,
            resolver: activeResolver
        )
        return try await perform(
            request: authorizedRequest,
            profile: profile,
            resolver: activeResolver
        )
    }

    private func requestUsingCurrentCredential(
        for request: URLRequest,
        profile: PodcastAccessProfile?,
        resolver: PodcastAccessResolver
    ) throws -> URLRequest {
        guard let profile, let url = request.url else { return request }
        let freshRequest = try resolver.request(for: url, profile: profile)
        var result = request
        result.url = freshRequest.url

        // Preserve caller-owned method/cache/timeout and non-auth headers, but
        // never preserve a stale Authorization header across token rotation
        // or a current-user scope change.
        if let fields = result.allHTTPHeaderFields {
            for field in fields.keys {
                if field.caseInsensitiveCompare("Authorization") == .orderedSame {
                    result.setValue(nil, forHTTPHeaderField: field)
                }
            }
        }
        if let authorization = freshRequest.value(forHTTPHeaderField: "Authorization") {
            result.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return result
    }

    private func perform(
        request: URLRequest,
        profile: PodcastAccessProfile?,
        resolver: PodcastAccessResolver
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
        let secretParameterNames: Set<String> = [
            "access_token", "access-token", "api_key", "api-key", "apikey",
            "auth", "auth_token", "auth-token", "credential", "feed_token",
            "freebie", "key", "password", "private", "rss_token", "secret",
            "token"
        ]
        return URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            secretParameterNames.contains($0.name.lowercased())
        } == true
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
