import Foundation
import XCTest
@testable import UpNext

private actor PrivacyRequestCapture: PodcastHTTPTransport {
    private(set) var request: URLRequest?

    func data(
        for request: URLRequest,
        profile: PodcastAccessProfile?,
        resolver: PodcastAccessResolver
    ) async throws -> (Data, URLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/xml"]
        )!
        return (Data("<rss/>".utf8), response)
    }
}

final class PodcastNetworkPrivacyPolicyTests: XCTestCase {
    func testRemovesOnlyRecognizedTrackingParametersAndPreservesEncodedRetainedPairs() throws {
        let cases: [(String, String)] = [
            ("https://example.com/feed.xml?utm_source=mail&token=A%2Fb&x=1", "token=A%2Fb&x=1"),
            ("https://example.com/e?FBCLID=a&gclid=b&episode_guid=c", "episode_guid=c"),
            ("https://example.com/e?utm_campaign=one&utm_campaign=two&keep=%E2%9C%93", "keep=%E2%9C%93"),
            ("https://example.com/e?unknown=1&unknown=2", "unknown=1&unknown=2")
        ]

        for (source, expectedQuery) in cases {
            let decision = PodcastNetworkPrivacyPolicy.prepare(
                try XCTUnwrap(URL(string: source)),
                purpose: .feed,
                enabled: true
            )
            XCTAssertEqual(URLComponents(url: decision.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, expectedQuery, source)
            XCTAssertNotEqual(decision.outcome, .blocked, source)
        }
    }

    func testSignedURLsRemainByteForByteUnchanged() throws {
        let source = try XCTUnwrap(URL(string: "https://cdn.example/audio.mp3?utm_source=feed&X-Amz-Credential=a%2Fb&X-Amz-Signature=deadbeef&X-Amz-Expires=60"))
        let decision = PodcastNetworkPrivacyPolicy.prepare(source, purpose: .audio, enabled: true)
        XCTAssertEqual(decision.outcome, .unchanged)
        XCTAssertEqual(decision.url.absoluteString, source.absoluteString)
    }

    func testPrivateFeedTokensAndBasicCredentialsArePreserved() throws {
        let source = try XCTUnwrap(URL(string: "https://reader:secret@example.com/feed.xml?token=private&utm_medium=email"))
        let decision = PodcastNetworkPrivacyPolicy.prepare(source, purpose: .feed, enabled: true)
        XCTAssertEqual(decision.url.user, "reader")
        XCTAssertEqual(decision.url.password, "secret")
        XCTAssertEqual(URLComponents(url: decision.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, "token=private")
    }

    func testNestedEncodedOP3PrefixesAreUnwrappedOfflineAndIdempotently() throws {
        let source = try XCTUnwrap(URL(string: "https://op3.dev/e/https%3A%2F%2Fop3.dev%2Fe%2Fhttps%253A%252F%252Fcdn.example%252Fep.mp3%253Futm_source%253Dfeed%2526token%253Dkeep"))
        let decision = PodcastNetworkPrivacyPolicy.prepare(source, purpose: .audio, enabled: true)
        XCTAssertEqual(decision.outcome, .bypassedKnownPrefix)
        XCTAssertEqual(decision.url.host, "cdn.example")
        XCTAssertEqual(URLComponents(url: decision.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, "token=keep")
        XCTAssertEqual(PodcastNetworkPrivacyPolicy.prepare(decision.url, purpose: .audio, enabled: true).url, decision.url)
    }

    func testKnownPodtracRedirectIsUnwrappedWithoutContactingTracker() throws {
        let source = try XCTUnwrap(URL(string: "https://dts.podtrac.com/redirect.mp3/files.lagedernation.org/lagedernation/LdN499.mp3?ptm_source=feed&ptm_context=mp3&ptm_file=LdN499.mp3"))
        let decision = PodcastNetworkPrivacyPolicy.prepare(source, purpose: .audio, enabled: true)
        XCTAssertEqual(decision.outcome, .bypassedKnownPrefix)
        XCTAssertEqual(decision.url.absoluteString, "https://files.lagedernation.org/lagedernation/LdN499.mp3")
        XCTAssertEqual(PodcastNetworkPrivacyPolicy.prepare(decision.url, purpose: .audio, enabled: true).url, decision.url)
    }

    func testMalformedOP3AndUnsafePodtracPrefixesAreBlockedWithoutContactingTracker() throws {
        let malformed = try XCTUnwrap(URL(string: "https://op3.dev/e/not-a-supported-target"))
        XCTAssertEqual(PodcastNetworkPrivacyPolicy.prepare(malformed, purpose: .audio, enabled: true).outcome, .blocked)
        for target in ["localhost", "127.0.0.1", "foo.internal", "evil.com:8080", "user@evil.com", "one-label"] {
            let url = try XCTUnwrap(URL(string: "https://dts.podtrac.com/redirect.mp3/\(target)/audio.mp3"))
            XCTAssertEqual(PodcastNetworkPrivacyPolicy.prepare(url, purpose: .audio, enabled: true).outcome, .blocked, target)
        }
    }

    func testOptOutPreservesTheOriginalPrefixAndTrackingQuery() throws {
        let source = try XCTUnwrap(URL(string: "https://op3.dev/e/https%3A%2F%2Fcdn.example%2Fe.mp3%3Futm_source%3Dfeed"))
        let decision = PodcastNetworkPrivacyPolicy.prepare(source, purpose: .audio, enabled: false)
        XCTAssertEqual(decision.outcome, .unchanged)
        XCTAssertEqual(decision.url.absoluteString, source.absoluteString)
    }

    func testOlderWatchSnapshotsDefaultProtectionToEnabled() throws {
        let data = try JSONEncoder().encode(WatchSyncSnapshot.empty)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "networkTrackingProtectionEnabled")
        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(WatchSyncSnapshot.self, from: legacyData)
        XCTAssertTrue(decoded.networkTrackingProtectionEnabled)
    }

    func testSharedHTTPClientPreparesTheActualFirstRequest() async throws {
        let capture = PrivacyRequestCapture()
        let client = PodcastHTTPClient(transport: capture)
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/feed.xml?utm_source=test&token=keep")))
        request.setValue("https://private.example/page", forHTTPHeaderField: "Referer")
        request.setValue("Bearer fake-test-token", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=0-4", forHTTPHeaderField: "Range")
        request.setValue("fake-etag", forHTTPHeaderField: "If-None-Match")
        _ = try await client.data(for: request, purpose: .transcript)

        let capturedRequest = await capture.request
        let sent = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false)?.percentEncodedQuery, "token=keep")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Referer"))
        XCTAssertEqual(sent.value(forHTTPHeaderField: "User-Agent"), "UpNext/1.0 (+https://github.com/holgerkrupp/PodcastClient)")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer fake-test-token")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Range"), "bytes=0-4")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "If-None-Match"), "fake-etag")
    }
}
