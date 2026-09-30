import Foundation
import XCTest
@testable import UpNext

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

    func testAccessProfileRedactsPrivateURLAndUsesStableNonSecretIdentity() {
        let privateURL = URL(string: "https://alice:s3cret@example.com/private.xml?token=fake-token")!
        let profile = PodcastAccessProfile.make(for: privateURL)

        XCTAssertEqual(profile.kind, .privateURL)
        XCTAssertEqual(profile.resourceURL?.absoluteString, "https://example.com/private.xml")
        XCTAssertFalse(profile.resourceURL?.absoluteString.contains("fake-token") == true)
        XCTAssertFalse(privateURL.redactedPodcastURLString.contains("fake-token"))
        XCTAssertTrue(privateURL.redactedPodcastURLString.localizedCaseInsensitiveContains("redacted"))
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

        let profile = PodcastAccessProfile.make(for: legacyURL, kind: .httpBasic)
        let credential = try KeychainPodcastCredentialStore.shared.credential(for: profile)
        XCTAssertEqual(
            credential,
            .httpBasic(username: "alice@example.com", password: "p@ss:word")
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
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
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
