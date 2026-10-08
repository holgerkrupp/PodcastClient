import Foundation
import XCTest
@testable import UpNext

private final class UnavailablePodcastCredentialStore: PodcastCredentialStore, @unchecked Sendable {
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

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?

    func store(_ request: URLRequest) {
        lock.lock()
        value = request
        lock.unlock()
    }

    func load() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct RequestCaptureTransport: PodcastHTTPTransport {
    let capture: RequestCapture

    func data(
        for request: URLRequest,
        profile: PodcastAccessProfile?,
        resolver: PodcastAccessResolver
    ) async throws -> (Data, URLResponse) {
        capture.store(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/rss+xml"]
        )!
        return (Data("<rss><channel><title>Fixture</title></channel></rss>".utf8), response)
    }
}

private struct StatusFixtureTransport: PodcastHTTPTransport {
    let statusCode: Int
    let wwwAuthenticate: String?

    func data(
        for request: URLRequest,
        profile: PodcastAccessProfile?,
        resolver: PodcastAccessResolver
    ) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: wwwAuthenticate.map { ["WWW-Authenticate": $0] }
        )!
        return (Data(), response)
    }
}

final class PodcastPrivateFeedTests: XCTestCase {
    private struct FixtureTransport: PodcastHTTPTransport {
        let fixture: Data

        func data(
            for request: URLRequest,
            profile: PodcastAccessProfile?,
            resolver: PodcastAccessResolver
        ) async throws -> (Data, URLResponse) {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/rss+xml"]
            )!
            return (fixture, response)
        }
    }

    func testHTTPClientFetchesTheSameFixtureThroughEveryAccessMode() async throws {
        let fixture = Data("<rss><channel><title>Fixture</title></channel></rss>".utf8)
        let endpoint = URL(string: "https://example.com/private.xml")!
        let store = InMemoryPodcastCredentialStore()
        let resolver = PodcastAccessResolver(credentialStore: store)
        let client = PodcastHTTPClient(
            resolver: resolver,
            transport: FixtureTransport(fixture: fixture)
        )

        let publicResult = try await client.data(for: endpoint)
        XCTAssertEqual(publicResult.0, fixture)

        let privateProfile = PodcastAccessProfile(id: "private", kind: .privateURL, resourceURL: endpoint)
        try store.save(.privateURL(URL(string: "https://example.com/private.xml?token=fake-token")!), for: privateProfile)
        let privateResult = try await client.data(for: endpoint, profile: privateProfile)
        XCTAssertEqual(privateResult.0, fixture)

        let basicProfile = PodcastAccessProfile(id: "basic", kind: .httpBasic, resourceURL: endpoint)
        try store.save(.httpBasic(username: "alice", password: "s3cret"), for: basicProfile)
        let basicResult = try await client.data(for: endpoint, profile: basicProfile)
        XCTAssertEqual(basicResult.0, fixture)

        let bearerProfile = PodcastAccessProfile(id: "bearer", kind: .bearerToken, resourceURL: endpoint)
        try store.save(.bearerToken("fake-bearer"), for: bearerProfile)
        let bearerResult = try await client.data(for: endpoint, profile: bearerProfile)
        XCTAssertEqual(bearerResult.0, fixture)
    }

    func testHTTPClientRequestOverloadRebuildsRotatedAuthorization() async throws {
        let endpoint = URL(string: "https://example.com/private.xml")!
        let profile = PodcastAccessProfile(id: "rotating-request", kind: .httpBasic, resourceURL: endpoint)
        let store = InMemoryPodcastCredentialStore()
        try store.save(.httpBasic(username: "alice", password: "old-password"), for: profile)
        let capture = RequestCapture()
        let client = PodcastHTTPClient(
            resolver: PodcastAccessResolver(credentialStore: store),
            transport: RequestCaptureTransport(capture: capture)
        )

        var request = URLRequest(podcastFeedURL: endpoint)
        request.httpMethod = "HEAD"
        request.setValue("Basic stale-header", forHTTPHeaderField: "Authorization")
        request.setValue("fixture-header", forHTTPHeaderField: "X-Fixture")

        _ = try await client.data(for: request, profile: profile)
        XCTAssertEqual(capture.load()?.httpMethod, "HEAD")
        XCTAssertEqual(capture.load()?.value(forHTTPHeaderField: "X-Fixture"), "fixture-header")
        XCTAssertEqual(
            capture.load()?.value(forHTTPHeaderField: "Authorization"),
            "Basic YWxpY2U6b2xkLXBhc3N3b3Jk"
        )

        try store.save(.httpBasic(username: "alice", password: "new-password"), for: profile)
        _ = try await client.data(for: request, profile: profile)
        XCTAssertEqual(
            capture.load()?.value(forHTTPHeaderField: "Authorization"),
            "Basic YWxpY2U6bmV3LXBhc3N3b3Jk"
        )
    }

    func testAccessProfileRedactsPrivateURLAndUsesStableNonSecretIdentity() {
        let privateURL = URL(string: "https://alice:s3cret@example.com/private.xml?token=fake-token")!
        let profile = PodcastAccessProfile.make(for: privateURL)

        XCTAssertEqual(profile.kind, .privateURL)
        XCTAssertEqual(profile.resourceURL?.absoluteString, "https://example.com/private.xml")
        XCTAssertFalse(profile.resourceURL?.absoluteString.contains("fake-token") == true)
        XCTAssertFalse(privateURL.redactedPodcastURLString.contains("fake-token"))
        XCTAssertTrue(privateURL.redactedPodcastURLString.localizedCaseInsensitiveContains("redacted"))
    }

    func testPublicFeedQueryIsPreservedAndNotClassifiedAsPrivate() {
        let publicURL = URL(string: "https://example.com/feed.xml?format=rss")!
        let podcast = Podcast(feed: publicURL)
        let profile = PodcastAccessProfile.make(for: publicURL)

        XCTAssertFalse(publicURL.isLikelyPrivatePodcastURL)
        XCTAssertEqual(podcast.feed, publicURL)
        XCTAssertNil(podcast.metaData?.accessKindRawValue)
        XCTAssertEqual(profile.kind, .publicFeed)
        XCTAssertEqual(profile.resourceURL, publicURL)
        XCTAssertEqual(PodcastFeedIdentity.normalizedFeedURLString(publicURL), publicURL.absoluteString)
    }

    func testPodcastFeedModelPreservesPublicQueryButSanitizesExplicitPrivateQuery() {
        let publicURL = URL(string: "https://example.com/feed.xml?format=rss")!
        let publicPodcast = Podcast(from: PodcastFeed(url: publicURL, accessKind: .publicFeed))
        XCTAssertEqual(publicPodcast.feed, publicURL)

        let privateURL = URL(string: "https://example.com/feed.xml?subscription_code=fake-code")!
        let privatePodcast = Podcast(
            from: PodcastFeed(url: privateURL, accessKind: .privateURL)
        )
        XCTAssertEqual(privatePodcast.feed, privateURL.podcastNonSecretURL)
        XCTAssertFalse(privatePodcast.feed?.absoluteString.contains("fake-code") == true)
    }

    func testExplicitPrivateProfileStripsUnknownCredentialQueryParameter() {
        let privateURL = URL(string: "https://example.com/feed.xml?subscription_code=fake-code")!
        let profile = PodcastAccessProfile.make(for: privateURL, kind: .privateURL)

        XCTAssertEqual(profile.resourceURL?.absoluteString, "https://example.com/feed.xml")
        XCTAssertEqual(profile.kind, .privateURL)
    }

    func testHeaderCredentialRetryPreservesOrdinaryFeedQuery() {
        let input = URL(string: "https://example.com/feed.xml?format=rss&page=1")!
        XCTAssertEqual(
            PodcastFeedResolver.requestBaseURL(for: input, kind: .httpBasic),
            input
        )
        XCTAssertEqual(
            PodcastFeedResolver.requestBaseURL(for: input, kind: .bearerToken),
            input
        )
        XCTAssertEqual(
            PodcastFeedResolver.requestBaseURL(for: input, kind: .privateURL),
            URL(string: "https://example.com/feed.xml")!
        )
    }

    func testAccessResolverSupportsPrivateURLBasicAndBearerCredentials() throws {
        let store = InMemoryPodcastCredentialStore()
        let resolver = PodcastAccessResolver(credentialStore: store)
        let endpoint = URL(string: "https://example.com/private.xml")!

        let privateProfile = PodcastAccessProfile(
            id: "private-profile",
            kind: .privateURL,
            resourceURL: endpoint
        )
        try store.save(
            .privateURL(URL(string: "https://example.com/private.xml?token=fake-token")!),
            for: privateProfile
        )
        let privateRequest = try resolver.request(for: endpoint, profile: privateProfile)
        XCTAssertEqual(privateRequest.url?.absoluteString, "https://example.com/private.xml?token=fake-token")

        let basicProfile = PodcastAccessProfile(id: "basic-profile", kind: .httpBasic, resourceURL: endpoint)
        try store.save(.httpBasic(username: "alice", password: "s3cret"), for: basicProfile)
        let basicRequest = try resolver.request(for: endpoint, profile: basicProfile)
        XCTAssertEqual(
            basicRequest.value(forHTTPHeaderField: "Authorization"),
            "Basic YWxpY2U6czNjcmV0"
        )

        let bearerProfile = PodcastAccessProfile(id: "bearer-profile", kind: .bearerToken, resourceURL: endpoint)
        try store.save(.bearerToken("fake-bearer"), for: bearerProfile)
        let bearerRequest = try resolver.request(for: endpoint, profile: bearerProfile)
        XCTAssertEqual(bearerRequest.value(forHTTPHeaderField: "Authorization"), "Bearer fake-bearer")
    }

    func testCredentialRotationUsesTheLatestCredentialWithoutChangingProfileIdentity() throws {
        let store = InMemoryPodcastCredentialStore()
        let resolver = PodcastAccessResolver(credentialStore: store)
        let feedURL = URL(string: "https://example.com/private.xml")!
        let firstURL = URL(string: "https://example.com/private.xml?token=first")!
        let rotatedURL = URL(string: "https://example.com/private.xml?token=rotated")!
        let profile = PodcastAccessProfile.make(for: feedURL, kind: .privateURL)

        try store.save(.privateURL(firstURL), for: profile)
        XCTAssertEqual(
            try resolver.request(for: feedURL, profile: profile).url,
            firstURL
        )

        try store.save(.privateURL(rotatedURL), for: profile)
        XCTAssertEqual(
            try resolver.request(for: feedURL, profile: profile).url,
            rotatedURL
        )
        XCTAssertEqual(profile.id, PodcastAccessProfile.make(for: rotatedURL, kind: .privateURL).id)
    }

    func testBasicCredentialResolutionKeepsTheSyncedFeedIdentityCredentialFree() throws {
        let store = InMemoryPodcastCredentialStore()
        let resolver = PodcastAccessResolver(credentialStore: store)
        let feedURL = URL(string: "https://example.com/private.xml")!
        let profile = PodcastAccessProfile(
            id: "basic-identity-profile",
            kind: .httpBasic,
            resourceURL: feedURL
        )
        try store.save(
            .httpBasic(username: "alice@example.com", password: "p@ss:word"),
            for: profile
        )

        XCTAssertEqual(
            try resolver.resolvedURL(for: profile, fallbackURL: feedURL),
            feedURL
        )
    }

    func testLegacyHTTPBasicCredentialRecoversAfterCanonicalTrailingSlash() throws {
        // The original username/password URL is never persisted. This fixture
        // models an older Keychain entry whose feed was later canonicalized by
        // the server from /feed/plus to /feed/plus/.
        let legacyURL = URL(
            string: "http://fixture%40example.com:p%40ss%3Aword@www.example.com/feed/plus"
        )!
        let canonicalURL = URL(string: "http://www.example.com/feed/plus/")!
        let legacyProfile = PodcastAccessProfile.make(for: legacyURL, kind: .httpBasic)
        let store = InMemoryPodcastCredentialStore()
        let resolver = PodcastAccessResolver(credentialStore: store)
        try store.save(
            .httpBasic(username: "fixture@example.com", password: "p@ss:word"),
            for: legacyProfile
        )

        let recovered = try XCTUnwrap(
            resolver.recoverLegacyHTTPBasicProfile(for: canonicalURL)
        )
        let request = try resolver.request(for: canonicalURL, profile: recovered)

        XCTAssertEqual(recovered.id, legacyProfile.id)
        XCTAssertEqual(recovered.kind, .httpBasic)
        XCTAssertEqual(recovered.resourceURL, canonicalURL)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Basic Zml4dHVyZUBleGFtcGxlLmNvbTpwQHNzOndvcmQ="
        )
        XCTAssertFalse(recovered.resourceURL?.absoluteString.contains("fixture") == true)
        XCTAssertFalse(recovered.resourceURL?.absoluteString.contains("p%40ss") == true)
    }

    func testProtectedArtworkCacheScopeIsSeparateFromPublicArtwork() {
        let artworkURL = URL(string: "https://example.com/artwork.jpg")!
        XCTAssertNotEqual(
            SharedImageRepository.imageCacheKey(for: artworkURL, maxPixelSize: 400),
            SharedImageRepository.imageCacheKey(
                for: artworkURL,
                maxPixelSize: 400,
                profileID: "private-profile"
            )
        )
        XCTAssertNotEqual(
            SharedImageRepository.blurredCacheKey(
                for: artworkURL,
                radius: 8,
                maxPixelSize: 400
            ),
            SharedImageRepository.blurredCacheKey(
                for: artworkURL,
                radius: 8,
                maxPixelSize: 400,
                profileID: "private-profile"
            )
        )
    }

    func testPrivateProviderRegistryDetectsKnownHostsWithoutUsingHostAsSecurityBoundary() {
        let zeitURL = URL(string: "https://www.zeit.de/podcasts/show/rss-podcatcher?token=fake")!
        let genericURL = URL(string: "https://feeds.example.com/private.xml?token=fake")!

        XCTAssertEqual(
            PremiumPodcastProviderRegistry.detectProviderID(for: zeitURL),
            .zeit
        )
        XCTAssertEqual(
            PremiumPodcastProviderRegistry.descriptor(for: genericURL).id,
            .genericPrivateFeed
        )

        let profile = PodcastAccessProfile.make(for: zeitURL, kind: .privateURL)
        XCTAssertEqual(profile.providerID, .zeit)
    }

    func testMembershipProvidersUseTheSameTokenizedPrivateFeedFlow() {
        for descriptor in PremiumPodcastProviderRegistry.descriptors where descriptor.id != .genericPrivateFeed {
            let host = descriptor.hosts[0]
            let firstURL = URL(string: "https://rss.\(host)/show.xml?token=fake-one")!
            let rotatedURL = URL(string: "https://rss.\(host)/show.xml?token=fake-two")!

            XCTAssertEqual(PremiumPodcastProviderRegistry.detectProviderID(for: firstURL), descriptor.id)
            XCTAssertEqual(
                PodcastAccessProfile.make(for: firstURL).id,
                PodcastAccessProfile.make(for: rotatedURL).id
            )
        }
    }

    func testMockProviderCanAuthorizeResolveAndSignOut() async throws {
        let feedURLs = [
            URL(string: "https://example.com/private-one.xml?token=fake-one")!,
            URL(string: "https://example.com/private-two.xml?token=fake-two")!
        ]
        let adapter = MockPremiumPodcastProviderAdapter(feedURLs: feedURLs)

        let account = try await adapter.authorize()
        XCTAssertEqual(account.entitlement, "active")
        let resolvedFeeds = try await adapter.resolveFeeds(for: account)
        XCTAssertEqual(resolvedFeeds, feedURLs)
        let resolvedFeed = try await adapter.resolveFeed(for: account)
        XCTAssertEqual(resolvedFeed, feedURLs.first)

        try await adapter.signOut()
        do {
            _ = try await adapter.resolveFeed(for: account)
            XCTFail("A signed-out provider must not resolve a feed")
        } catch let error as PremiumPodcastProviderAuthError {
            XCTAssertEqual(error, .revoked)
        }
    }

    func testProviderLifecycleCoversExpiredRefreshCancellationRenewalAndRevocation() async throws {
        let feedURL = URL(string: "https://example.com/member.xml?token=fixture")!
        let adapter = MockPremiumPodcastProviderAdapter(feedURL: feedURL)
        let account = try await adapter.authorize()

        await adapter.failNextReauthorization(with: .expired)
        do {
            _ = try await adapter.reauthorize()
            XCTFail("An expired provider session must be surfaced")
        } catch let error as PremiumPodcastProviderAuthError {
            XCTAssertEqual(error, .expired)
        }

        let refreshed = try await adapter.reauthorize()
        XCTAssertEqual(refreshed.entitlement, "active")
        let refreshedFeed = try await adapter.resolveFeed(for: refreshed)
        XCTAssertEqual(refreshedFeed, feedURL)

        await adapter.setEntitlement("cancelled")
        do {
            _ = try await adapter.resolveFeed(for: refreshed)
            XCTFail("A cancelled membership must not resolve protected feeds")
        } catch let error as PremiumPodcastProviderAuthError {
            XCTAssertEqual(error, .notEntitled)
        }

        await adapter.setEntitlement("active")
        let renewed = try await adapter.reauthorize()
        let renewedFeed = try await adapter.resolveFeed(for: renewed)
        XCTAssertEqual(renewedFeed, feedURL)

        try await adapter.signOut()
        do {
            _ = try await adapter.resolveFeed(for: account)
            XCTFail("Signing out must revoke the local provider session")
        } catch let error as PremiumPodcastProviderAuthError {
            XCTAssertEqual(error, .revoked)
        }
    }

    func testMissingCredentialStateIsRecoverableWithoutChangingPodcastIdentity() throws {
        let feedURL = URL(string: "https://example.com/private.xml?token=fake")!
        let podcast = Podcast(feed: feedURL)
        let profile = PodcastAccessProfile.make(for: feedURL, kind: .privateURL)
        let store = InMemoryPodcastCredentialStore()
        try store.save(.privateURL(feedURL), for: profile)
        try store.removeCredential(for: profile)

        XCTAssertEqual(PodcastAccessResolver(credentialStore: store).credentialState(for: profile), .missing)
        XCTAssertEqual(podcast.feed, feedURL.podcastNonSecretURL)
        XCTAssertEqual(podcast.metaData?.accessProfileID, profile.id)
    }

    func testBootstrapDecisionExposesCredentialRequirementWithoutLeakingSecret() throws {
        let protectedURL = URL(string: "https://example.com/private.xml?token=not-for-logs")!
        let profile = PodcastAccessProfile.make(for: protectedURL, kind: .privateURL)
        let resolver = PodcastAccessResolver(credentialStore: InMemoryPodcastCredentialStore())

        let decision = resolver.bootstrapDecision(for: profile, fallbackURL: profile.resourceURL!)

        XCTAssertEqual(
            decision,
            .credentialsRequired(profileID: profile.id, feedURL: profile.resourceURL!)
        )
        if case .credentialsRequired(_, let feedURL) = decision {
            XCTAssertNil(URLComponents(url: feedURL, resolvingAgainstBaseURL: false)?.query)
            XCTAssertFalse(feedURL.absoluteString.contains("not-for-logs"))
        } else {
            XCTFail("A missing credential must not start protected bootstrap")
        }
    }

    func testUnavailableCredentialStoreProducesRecoverableCredentialRequiredState() {
        let feedURL = URL(string: "https://example.com/keychain-unavailable.xml")!
        let profile = PodcastAccessProfile.make(for: feedURL, kind: .privateURL)
        let resolver = PodcastAccessResolver(credentialStore: UnavailablePodcastCredentialStore())

        XCTAssertEqual(
            resolver.bootstrapDecision(for: profile, fallbackURL: feedURL),
            .credentialsRequired(profileID: profile.id, feedURL: feedURL)
        )
    }

    func testPrivatePodcastCreationReportsMissingWhenSecureStoreRejectsCredential() {
        let feedURL = URL(string: "https://example.com/fresh-device.xml?token=fake-token")!
        let unavailableStore = UnavailablePodcastCredentialStore()
        defer {
            PodcastCredentialStoreProvider.configure(
                currentUserScopeID: nil,
                backing: KeychainPodcastCredentialStore.shared
            )
        }

        PodcastCredentialStoreProvider.configure(
            currentUserScopeID: nil,
            backing: unavailableStore
        )
        let podcast = Podcast(feed: feedURL)

        XCTAssertEqual(podcast.metaData?.credentialState, .missing)
        XCTAssertEqual(podcast.feed, feedURL.podcastNonSecretURL)
        XCTAssertEqual(
            podcast.metaData?.accessProfileID,
            PodcastAccessProfile.make(for: feedURL, kind: .privateURL).id
        )
    }

    func testDownloadAssociationSurvivesPrivateURLTokenRotation() {
        let first = URL(string: "https://example.com/episode.mp3?token=old-token")!
        let rotated = URL(string: "https://example.com/episode.mp3?token=new-token")!

        let firstKey = PodcastDownloadAssociationKey.url(for: first)
        let rotatedKey = PodcastDownloadAssociationKey.url(for: rotated)

        XCTAssertEqual(firstKey, rotatedKey)
        XCTAssertFalse(firstKey.absoluteString.contains("old-token"))
        XCTAssertFalse(firstKey.absoluteString.contains("new-token"))
    }

    func testProtectedDownloadAuthFailuresPreserveExplicitRetryAssociation() {
        XCTAssertTrue(PodcastDownloadCompletionPolicy.preservesAuthorization(for: 401))
        XCTAssertTrue(PodcastDownloadCompletionPolicy.preservesAuthorization(for: 403))
        XCTAssertFalse(PodcastDownloadCompletionPolicy.preservesAuthorization(for: 404))
        XCTAssertFalse(PodcastDownloadCompletionPolicy.preservesAuthorization(for: nil))
    }

    func testAccessResolverRejectsCrossOriginCredentialForwarding() throws {
        let store = InMemoryPodcastCredentialStore()
        let resolver = PodcastAccessResolver(credentialStore: store)
        let profile = PodcastAccessProfile(
            id: "basic-profile",
            kind: .httpBasic,
            resourceURL: URL(string: "https://example.com/private.xml")!
        )
        try store.save(.httpBasic(username: "alice", password: "s3cret"), for: profile)

        XCTAssertThrowsError(
            try resolver.request(
                for: URL(string: "https://cdn.example.net/episode.mp3")!,
                profile: profile
            )
        ) { error in
            XCTAssertEqual(error as? PodcastAccessError, .unauthorizedResource(URL(string: "https://cdn.example.net/episode.mp3")!))
        }
    }

    func testRedirectsDoNotForwardCredentialsAcrossOrigins() throws {
        let store = InMemoryPodcastCredentialStore()
        let resolver = PodcastAccessResolver(credentialStore: store)
        let feedURL = URL(string: "https://example.com/private.xml")!
        let profile = PodcastAccessProfile(
            id: "redirect-profile",
            kind: .httpBasic,
            resourceURL: feedURL
        )
        try store.save(.httpBasic(username: "alice", password: "p@ss:word"), for: profile)

        let sameOrigin = try resolver.request(
            for: URL(string: "https://example.com/episode.mp3")!,
            profile: profile,
            redirectingFrom: feedURL
        )
        XCTAssertEqual(
            sameOrigin.value(forHTTPHeaderField: "Authorization"),
            "Basic YWxpY2U6cEBzczp3b3Jk"
        )

        let crossOrigin = try resolver.request(
            for: URL(string: "https://cdn.example.net/episode.mp3")!,
            profile: profile,
            redirectingFrom: feedURL
        )
        XCTAssertNil(crossOrigin.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(crossOrigin.url?.user)
        XCTAssertNil(crossOrigin.url?.password)
    }

    func testSynchronizedFeedIdentityAndManifestNeverContainPrivateToken() throws {
        let privateURL = URL(string: "https://example.com/private.xml?token=fake-token")!
        let identity = PodcastFeedIdentity.normalizedFeedURLString(privateURL)
        XCTAssertEqual(identity, "https://example.com/private.xml")

        let profile = PodcastAccessProfile.make(for: privateURL)
        let entry = SubscriptionManifestEntry(
            feedURL: identity,
            accessProfileID: profile.id,
            accessKindRawValue: profile.kind.rawValue,
            title: "Private Show"
        )
        let encoded = try JSONEncoder().encode(entry)
        let payload = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(payload.contains("fake-token"))
        XCTAssertTrue(payload.contains(profile.id))
    }

    func testSynchronizedProfileMetadataSurvivesSafeFeedMigration() {
        let sourceURL = URL(string: "https://example.com/private.xml?token=fake-token")!
        let podcast = Podcast(feed: sourceURL)

        let profile = storedPodcastAccessProfile(for: podcast)

        XCTAssertEqual(profile?.kind, .privateURL)
        XCTAssertEqual(profile?.resourceURL, sourceURL.podcastNonSecretURL)
        XCTAssertEqual(profile?.id, podcast.metaData?.accessProfileID)
        XCTAssertFalse(profile?.synchronizableCredential == true)
    }

    func testCredentialSyncPolicyKeepsCurrentCredentialKindsDeviceOnly() {
        XCTAssertFalse(PodcastCredentialSyncPolicy.allowsSynchronizableStorage(for: .privateURL, providerID: .zeit))
        XCTAssertFalse(PodcastCredentialSyncPolicy.allowsSynchronizableStorage(for: .httpBasic, providerID: .genericPrivateFeed))
        XCTAssertFalse(PodcastCredentialSyncPolicy.allowsSynchronizableStorage(for: .bearerToken, providerID: .patreon))
    }

    func testCredentialStoreScopesSecretsByCurrentUser() throws {
        let backing = InMemoryPodcastCredentialStore()
        let firstUser = ScopedPodcastCredentialStore(scopeID: "tv-user-a", backing: backing)
        let secondUser = ScopedPodcastCredentialStore(scopeID: "tv-user-b", backing: backing)
        let profile = PodcastAccessProfile.make(
            for: URL(string: "https://example.com/private.xml")!,
            kind: .privateURL
        )
        let firstCredential = PodcastCredential.privateURL(
            URL(string: "https://example.com/private.xml?token=first")!
        )
        let secondCredential = PodcastCredential.privateURL(
            URL(string: "https://example.com/private.xml?token=second")!
        )

        try firstUser.save(firstCredential, for: profile)
        XCTAssertNil(try secondUser.credential(for: profile))

        try secondUser.save(secondCredential, for: profile)
        XCTAssertEqual(try firstUser.credential(for: profile), firstCredential)
        XCTAssertEqual(try secondUser.credential(for: profile), secondCredential)

        try firstUser.removeCredential(for: profile)
        XCTAssertNil(try firstUser.credential(for: profile))
        XCTAssertEqual(try secondUser.credential(for: profile), secondCredential)
    }

    func testCredentialStoreProviderRoutesProductionAccessThroughCurrentUserScope() throws {
        let feedURL = URL(string: "https://example.com/provider-scope.xml")!
        let profile = PodcastAccessProfile.make(for: feedURL, kind: .privateURL)
        let backing = InMemoryPodcastCredentialStore()
        let credential = PodcastCredential.privateURL(
            URL(string: feedURL.absoluteString + "?token=provider-scope")!
        )
        defer {
            PodcastCredentialStoreProvider.configure(
                currentUserScopeID: nil,
                backing: KeychainPodcastCredentialStore.shared
            )
        }

        PodcastCredentialStoreProvider.configure(
            currentUserScopeID: "tv-user-provider-scope",
            backing: backing
        )
        try PodcastCredentialStoreProvider.current.save(credential, for: profile)

        XCTAssertEqual(
            try ScopedPodcastCredentialStore(
                scopeID: "tv-user-provider-scope",
                backing: backing
            ).credential(for: profile),
            credential
        )
        XCTAssertNil(
            try ScopedPodcastCredentialStore(
                scopeID: "different-tv-user",
                backing: backing
            ).credential(for: profile)
        )
    }

    func testDefaultResolverFollowsCurrentUserScopeAfterInitialization() throws {
        let feedURL = URL(string: "https://example.com/scope-switch.xml")!
        let profile = PodcastAccessProfile.make(for: feedURL, kind: .privateURL)
        let backing = InMemoryPodcastCredentialStore()
        let userAURL = URL(string: feedURL.absoluteString + "?token=user-a")!
        let userACredential = PodcastCredential.privateURL(userAURL)
        defer {
            PodcastCredentialStoreProvider.configure(
                currentUserScopeID: nil,
                backing: KeychainPodcastCredentialStore.shared
            )
        }

        PodcastCredentialStoreProvider.configure(currentUserScopeID: "scope-a", backing: backing)
        try PodcastCredentialStoreProvider.current.save(userACredential, for: profile)
        let resolver = PodcastAccessResolver()
        XCTAssertEqual(resolver.credentialState(for: profile), .available)

        PodcastCredentialStoreProvider.configure(currentUserScopeID: "scope-b", backing: backing)
        XCTAssertEqual(
            resolver.bootstrapDecision(for: profile, fallbackURL: feedURL),
            .credentialsRequired(profileID: profile.id, feedURL: feedURL)
        )

        PodcastCredentialStoreProvider.configure(currentUserScopeID: "scope-a", backing: backing)
        XCTAssertEqual(
            try resolver.request(for: feedURL, profile: profile).url,
            userAURL
        )
    }

    func testPremiumBootstrapPlannerDistinguishesMissingReadyAndPublicStates() throws {
        let privateURL = URL(string: "https://example.com/tv-private.xml")!
        let privateProfileID = "tv-private-profile"
        let store = InMemoryPodcastCredentialStore()
        let resolver = PodcastAccessResolver(credentialStore: store)

        let missing = PodcastPremiumBootstrapPlanner.plan(
            feedURL: privateURL,
            title: "Private fixture",
            accessProfileID: privateProfileID,
            accessKindRawValue: PodcastAccessKind.privateURL.rawValue,
            accessProviderIDRawValue: PremiumPodcastProviderID.genericPrivateFeed.rawValue,
            resolver: resolver
        )
        XCTAssertEqual(
            missing.decision,
            .credentialsRequired(profileID: privateProfileID, feedURL: privateURL)
        )

        let profile = missing.profile
        let authorizedURL = URL(string: "https://example.com/tv-private.xml?token=fake-tv")!
        try store.save(.privateURL(authorizedURL), for: profile)
        let ready = PodcastPremiumBootstrapPlanner.plan(
            feedURL: privateURL,
            title: "Private fixture",
            accessProfileID: privateProfileID,
            accessKindRawValue: PodcastAccessKind.privateURL.rawValue,
            accessProviderIDRawValue: PremiumPodcastProviderID.genericPrivateFeed.rawValue,
            resolver: resolver
        )
        XCTAssertEqual(ready.decision, .ready(authorizedURL))

        let publicURL = URL(string: "https://example.com/public.xml?format=rss")!
        let publicPlan = PodcastPremiumBootstrapPlanner.plan(
            feedURL: publicURL,
            title: nil,
            accessProfileID: nil,
            accessKindRawValue: PodcastAccessKind.publicFeed.rawValue,
            accessProviderIDRawValue: nil,
            resolver: resolver
        )
        XCTAssertEqual(publicPlan.decision, .publicFeed(publicURL))
    }

    func testCredentialStoreRemovalLeavesProfileMetadataUsable() throws {
        let store = InMemoryPodcastCredentialStore()
        let profile = PodcastAccessProfile.make(
            for: URL(string: "https://example.com/private.xml?token=fake-token")!
        )
        try store.save(.privateURL(URL(string: "https://example.com/private.xml?token=fake-token")!), for: profile)
        XCTAssertEqual(PodcastAccessResolver(credentialStore: store).credentialState(for: profile), .available)

        try store.removeCredential(for: profile)
        XCTAssertEqual(PodcastAccessResolver(credentialStore: store).credentialState(for: profile), .missing)
        XCTAssertEqual(profile.kind, .privateURL)
    }

    func testPodcastModelStoresOnlyCredentialFreeFeedURL() {
        let sourceURL = URL(string: "https://example.com/private.xml?token=fake-token")!
        let podcast = Podcast(feed: sourceURL)

        XCTAssertEqual(podcast.feed?.absoluteString, "https://example.com/private.xml")
        XCTAssertEqual(podcast.metaData?.accessKindRawValue, PodcastAccessKind.privateURL.rawValue)
        XCTAssertFalse(podcast.feed?.absoluteString.contains("fake-token") == true)
    }

    func testLegacyHTTPBasicPodcastRecordMigratesToSafeHTTPIdentity() throws {
        let legacyURL = URL(string: "http://alice%40example.com:p%40ss%3Aword@example.com/feed/plus")!
        let safeURL = legacyURL.podcastNonSecretURL
        let podcast = Podcast(feed: legacyURL)

        XCTAssertEqual(podcast.feed, safeURL)
        XCTAssertEqual(podcast.metaData?.accessKindRawValue, PodcastAccessKind.httpBasic.rawValue)
        XCTAssertEqual(
            podcast.metaData?.accessProfileID,
            PodcastAccessProfileID.make(for: safeURL)
        )

        // The production initializer writes the decoded credential to
        // Keychain. Keep this host test deterministic by asserting the
        // migration boundary only; reading a real macOS Keychain item can
        // block the XCTest host behind an interactive security prompt.
    }

    func testLegacyHTTPBasicMigrationStoresDecodedCredentialInInjectedStore() throws {
        let legacyURL = URL(string: "http://alice%40example.com:p%40ss%3Aword@example.com/feed/plus")!
        let store = InMemoryPodcastCredentialStore()
        defer {
            PodcastCredentialStoreProvider.configure(
                currentUserScopeID: nil,
                backing: KeychainPodcastCredentialStore.shared
            )
        }
        PodcastCredentialStoreProvider.configure(currentUserScopeID: nil, backing: store)

        let podcast = Podcast(feed: legacyURL)
        let profile = PodcastAccessProfile.make(for: legacyURL, kind: .httpBasic)

        XCTAssertEqual(
            try store.credential(for: profile),
            .httpBasic(username: "alice@example.com", password: "p@ss:word")
        )
        XCTAssertEqual(podcast.feed, legacyURL.podcastNonSecretURL)
        XCTAssertFalse(podcast.feed?.absoluteString.contains("alice") == true)
        XCTAssertFalse(podcast.feed?.absoluteString.contains("p%40ss") == true)
    }

    func testLegacyHTTPBasicURLMatchesItsCredentialFreeMigratedIdentity() {
        let legacyURL = URL(string: "http://alice%40example.com:p%40ss%3Aword@www.bitsundso.de/feed/plus")!
        let safeURL = legacyURL.podcastNonSecretURL

        XCTAssertFalse(
            legacyURL.podcastFeedComparisonKeys
                .intersection(safeURL.podcastFeedComparisonKeys)
                .isEmpty
        )
    }

    func testPrivateFeedTokenSurvivesCanonicalSelfURL() async throws {
        let requestedURL = URL(string: "https://example.com/private.xml?freebie=secret")!
        let xml = """
        <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
          <channel>
            <title>Private Show</title>
            <description>Private</description>
            <atom:link rel="self" href="https://example.com/private.xml" />
          </channel>
        </rss>
        """

        let page = try await PodcastParser.parsePage(
            from: PodcastFeedDocument(
                data: Data(xml.utf8),
                sourceURL: requestedURL,
                requestedURL: requestedURL
            )
        )

        XCTAssertEqual(page.feed.url, requestedURL)
    }

    func testPrivateFeedTokenSurvivesPagedFeedLinks() async throws {
        let requestedURL = URL(string: "https://example.com/private.xml?freebie=secret")!
        let xml = """
        <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
          <channel>
            <title>Private Show</title>
            <atom:link rel="next" href="/private.xml?page=2" />
          </channel>
        </rss>
        """

        let page = try await PodcastParser.parsePage(
            from: PodcastFeedDocument(
                data: Data(xml.utf8),
                sourceURL: requestedURL,
                requestedURL: requestedURL
            )
        )

        XCTAssertEqual(
            page.nextPageURL?.absoluteString,
            "https://example.com/private.xml?page=2&freebie=secret"
        )
    }

    func testBasicAuthenticationSurvivesCanonicalSelfURLAndIsSentOnRequests() async throws {
        let requestedURL = URL(string: "https://alice:s3cret@example.com/private.xml")!
        let xml = """
        <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
          <channel>
            <title>Private Show</title>
            <atom:link rel="self" href="https://example.com/private.xml" />
          </channel>
        </rss>
        """

        let page = try await PodcastParser.parsePage(
            from: PodcastFeedDocument(
                data: Data(xml.utf8),
                sourceURL: requestedURL,
                requestedURL: requestedURL
            )
        )
        let request = URLRequest(podcastFeedURL: requestedURL)

        XCTAssertEqual(page.feed.url, requestedURL)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Basic YWxpY2U6czNjcmV0"
        )
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("UpNext/") == true)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Accept")?.contains("application/rss+xml") == true)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
    }

    func testBasicAuthenticationDecodesReservedCharactersFromURLUserInfo() {
        let requestedURL = URL(string: "https://alice%40example.com:p%40ss%3Aword@example.com/private.xml")!
        let request = URLRequest(podcastFeedURL: requestedURL)

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Basic YWxpY2VAZXhhbXBsZS5jb206cEBzczp3b3Jk"
        )
    }

    func testAuthenticationPromptRequiresAnHTTPBasicChallenge() {
        let blocked = PodcastHTTPError.httpStatus(
            code: 403,
            url: URL(string: "https://example.com/private.xml")!,
            wwwAuthenticate: nil
        )
        XCTAssertFalse(blocked.advertisesHTTPBasicAuthentication)

        let basicChallenge = PodcastHTTPError.httpStatus(
            code: 401,
            url: URL(string: "https://example.com/private.xml")!,
            wwwAuthenticate: "Basic realm=\"podcast\""
        )
        XCTAssertTrue(basicChallenge.advertisesHTTPBasicAuthentication)
    }

    func testResolverDoesNotShowAuthenticationPromptFor403WithoutChallenge() async throws {
        let endpoint = URL(string: "https://example.com/no-auth.xml")!
        let client = PodcastHTTPClient(
            transport: StatusFixtureTransport(statusCode: 403, wwwAuthenticate: nil)
        )

        do {
            _ = try await PodcastFeedResolver.resolve(
                url: endpoint,
                allowAuthenticationPrompt: true,
                client: client
            )
            XCTFail("A 403 without an authentication challenge must not open the credential form")
        } catch let error as PodcastFeedResolverError {
            guard case .httpStatus(let failedURL, let statusCode, _) = error else {
                return XCTFail("Unexpected resolver error: \(error)")
            }
            XCTAssertEqual(failedURL, endpoint)
            XCTAssertEqual(statusCode, 403)
        }
    }

    func testPodcastLiveItemRetainsSourcesAndCompanionLinks() async throws {
        let feedURL = URL(string: "https://example.com/shows/live/feed.xml")!
        let xml = """
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Live Show</title>
            <podcast:liveItem status="pending" start="2030-10-28T20:00:00Z">
              <podcast:guid>event-42</podcast:guid>
              <podcast:title>Election night live</podcast:title>
              <podcast:description>Publisher description</podcast:description>
              <podcast:image href="art/live.png" />
              <podcast:alternateEnclosure type="audio/mpeg" default="true">
                <podcast:source uri="streams/audio.mp3" contentType="audio/mpeg" bitrate="128000" />
                <podcast:source uri="https://cdn.example.com/live.m3u8" contentType="application/x-mpegURL" />
              </podcast:alternateEnclosure>
              <podcast:contentLink href="https://example.com/live" type="video/webm">Watch</podcast:contentLink>
              <podcast:chat url="https://chat.example.com/room" protocol="irc">Join chat</podcast:chat>
            </podcast:liveItem>
          </channel>
        </rss>
        """

        let page = try await PodcastParser.parsePage(
            from: PodcastFeedDocument(
                data: Data(xml.utf8),
                sourceURL: feedURL,
                requestedURL: feedURL
            )
        )

        let item = try XCTUnwrap(page.feed.liveItems.first)
        XCTAssertEqual(item.id, "event-42")
        XCTAssertEqual(item.status, .pending)
        XCTAssertEqual(item.title, "Election night live")
        XCTAssertEqual(item.artworkURL?.absoluteString, "https://example.com/shows/live/art/live.png")
        XCTAssertEqual(item.streamSources.count, 2)
        XCTAssertEqual(item.streamSources[0].url.absoluteString, "https://example.com/shows/live/streams/audio.mp3")
        XCTAssertTrue(item.preferredStream?.isHLS == true)
        XCTAssertEqual(item.chat.first?.url.absoluteString, "https://chat.example.com/room")
        XCTAssertEqual(item.contentLinks.first?.label, "Watch")
    }

    func testPodcastLiveItemUsesStableIdentityAndIgnoresUnsafeCompanionURLs() {
        let node = NamespaceNode(
            name: "podcast:liveItem",
            attributes: ["status": "future-status", "start": "not-a-date"],
            children: [
                NamespaceNode(name: "podcast:title", value: "Preview"),
                NamespaceNode(name: "podcast:contentLink", attributes: ["href": "javascript:alert(1)"]),
                NamespaceNode(name: "podcast:chat", attributes: ["url": "file:///tmp/chat"])
            ]
        )

        let first = PodcastLiveItem(node: node, baseURL: URL(string: "https://example.com/feed.xml"))
        let second = PodcastLiveItem(node: node, baseURL: URL(string: "https://example.com/feed.xml"))
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(first?.status, .unknown("future-status"))
        XCTAssertTrue(first?.contentLinks.isEmpty == true)
        XCTAssertTrue(first?.chat.isEmpty == true)
        XCTAssertNil(first?.start)
    }
}
