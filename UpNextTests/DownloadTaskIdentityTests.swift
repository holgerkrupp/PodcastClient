import Foundation
import XCTest
@testable import UpNext

final class DownloadTaskIdentityTests: XCTestCase {
    func testFirewallProgressAndCompletionResolveOriginalEpisodeDespiteTrackingCleanup() throws {
        let original = try XCTUnwrap(URL(string:
            "https://traffic.omny.fm/d/clips/5ac1e950-45c7-4eb7-87c0-aa0f018441b8/2a316725-d935-437a-849a-afcd01080c0d/ab8a9cb8-1299-4b46-835e-b4e90099a33b/audio.mp3?utm_source=Podcast&in_playlist=8e752661-e41c-4d9f-ba6f-afcd011068e3"
        ))
        let wireURL = PodcastNetworkPrivacyPolicy.prepare(original, purpose: .audio, enabled: true).url
        XCTAssertNotEqual(original, wireURL)
        XCTAssertEqual(wireURL.query, "in_playlist=8e752661-e41c-4d9f-ba6f-afcd011068e3")

        var identity = DownloadTaskIdentity()
        identity.register(episodeURL: original, taskIdentifier: 42)

        // Both URLSession delegate callbacks carry task identifier 42 and
        // a rewritten originalRequest URL. They still target the same episode.
        XCTAssertEqual(identity.episodeURL(for: 42), original)
        XCTAssertNotEqual(identity.episodeURL(for: 42), wireURL)
        identity.remove(taskIdentifier: 42)
        XCTAssertNil(identity.episodeURL(for: 42))
    }

    func testOldCallbackCannotOverwriteReplacementTaskIdentity() throws {
        let episode = try XCTUnwrap(URL(string: "https://example.org/episode.mp3?utm_source=feed"))
        var identity = DownloadTaskIdentity()
        identity.register(episodeURL: episode, taskIdentifier: 7)
        identity.register(episodeURL: episode, taskIdentifier: 8)
        identity.remove(taskIdentifier: 7)
        XCTAssertEqual(identity.episodeURL(for: 8), episode)
        XCTAssertNil(identity.episodeURL(for: 7))
    }
}
