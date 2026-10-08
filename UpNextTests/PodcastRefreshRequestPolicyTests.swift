import XCTest
@testable import UpNext

final class PodcastRefreshRequestPolicyTests: XCTestCase {
    func testForegroundRefreshDefaultsToFourWorkersWithSerialRollback() {
        let key = "PodcastRefreshNetworkConcurrency"
        let previousValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(PodcastModelActor.maximumConcurrentRefreshes, 4)
        UserDefaults.standard.set(1, forKey: key)
        XCTAssertEqual(PodcastModelActor.maximumConcurrentRefreshes, 1)
    }

    private actor RetryTransportState {
        var requests = 0
        func next() -> Int { requests += 1; return requests }
    }

    private struct RetryTransport: PodcastHTTPTransport {
        let state: RetryTransportState

        func data(
            for request: URLRequest,
            profile: PodcastAccessProfile?,
            resolver: PodcastAccessResolver
        ) async throws -> (Data, URLResponse) {
            let number = await state.next()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: number == 1 ? 429 : 200,
                httpVersion: nil,
                headerFields: number == 1 ? ["Retry-After": "0.2"] : [:]
            )!
            return (Data("<rss/>".utf8), response)
        }
    }

    private struct ValidatorTransport: PodcastHTTPTransport {
        func data(
            for request: URLRequest,
            profile: PodcastAccessProfile?,
            resolver: PodcastAccessResolver
        ) async throws -> (Data, URLResponse) {
            let conditional = request.value(forHTTPHeaderField: "If-None-Match") == "\"stable\""
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: conditional ? 304 : 200,
                httpVersion: nil,
                headerFields: ["ETag": "\"stable\""]
            )!
            return (conditional ? Data() : Data("<rss/>".utf8), response)
        }
    }

    func testManualBulkKeepsHEADAndSkipsGETOnlyForReliableUnchangedResult() {
        let policy = PodcastRefreshRequestPolicy.manualBulk

        XCTAssertTrue(policy.performHEAD)
        XCTAssertFalse(policy.forceGETRegardlessOfHEAD)
        XCTAssertFalse(policy.shouldGET(afterHEADResult: false))
        XCTAssertTrue(policy.shouldGET(afterHEADResult: true))
        XCTAssertTrue(policy.shouldGET(afterHEADResult: nil))
    }

    func testManualSingleSkipsHEADAndRequiresGET() {
        let policy = PodcastRefreshRequestPolicy.manualSingle

        XCTAssertFalse(policy.performHEAD)
        XCTAssertTrue(policy.forceGETRegardlessOfHEAD)
    }

    func testDueReleasePerformsHEADButStillGetsWhenHEADClaimsUnchanged() {
        let policy = PodcastRefreshRequestPolicy.dueRelease

        XCTAssertTrue(policy.performHEAD)
        XCTAssertTrue(policy.shouldGET(afterHEADResult: false))
        XCTAssertTrue(policy.shouldGET(afterHEADResult: nil))
    }

    func testRegularRefreshPerformsHEADAndTreatsInconclusiveAsReasonToGet() {
        let policy = PodcastRefreshRequestPolicy.regular

        XCTAssertTrue(policy.performHEAD)
        XCTAssertFalse(policy.shouldGET(afterHEADResult: false))
        XCTAssertTrue(policy.shouldGET(afterHEADResult: nil))
        XCTAssertTrue(policy.shouldGET(afterHEADResult: false, hasTimeSensitiveLiveItem: true))
    }

    func testValidatedImportUsesSpecializedDirectGETPolicy() {
        let policy = PodcastRefreshRequestPolicy.validatedImport

        XCTAssertFalse(policy.performHEAD)
        XCTAssertTrue(policy.forceGETRegardlessOfHEAD)
    }

    func testPreparedRefreshRetainsUpdatedDescriptionAndLiveItem() async throws {
        let url = URL(string: "https://example.com/live.xml")!
        let feed = PodcastFeed(url: url, fetchMetadataIfNeeded: false)

        func xml(description: String, status: String) -> Data {
            Data("""
            <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
              <channel>
                <title>Live Show</title>
                <description>\(description)</description>
                <podcast:liveItem status="\(status)" start="2030-10-28T20:00:00Z">
                  <podcast:guid>event-42</podcast:guid>
                  <podcast:title>Election night live</podcast:title>
                </podcast:liveItem>
              </channel>
            </rss>
            """.utf8)
        }

        for (description, status) in [("Original description", "pending"),
                                      ("Updated description", "live")] {
            let page = try await PodcastParser.parsePage(
                from: PodcastFeedDocument(
                    data: xml(description: description, status: status),
                    sourceURL: url,
                    requestedURL: url
                )
            )
            let prepared = try PreparedPodcastFeed(page.parsedFeed)
            feed.apply(parsedFeed: try prepared.importDictionary, fallbackURL: url)
            XCTAssertEqual(feed.description, description)
            XCTAssertEqual(feed.liveItems.first?.status.rawValue, status)
            XCTAssertEqual(feed.liveItems.first?.id, "event-42")
        }
    }

    func testConditionalGETUsesOnlyCommittedValidatorAnd304HasNoBody() async throws {
        let url = URL(string: "https://example.com/\(UUID().uuidString).xml")!
        let store = PodcastHTTPValidatorStore.shared
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["ETag": "\"stable\""]
        )!
        await store.stage(response, for: url, profile: nil)
        let beforeCommit = await store.validated(for: url, profile: nil)
        XCTAssertNil(beforeCommit)

        await store.commit(for: url, profile: nil)
        let committedValidator = await store.validated(for: url, profile: nil)
        let validator = try XCTUnwrap(committedValidator)
        let conditionalClient = PodcastHTTPClient(
            transport: ValidatorTransport(),
            conditionalFeedURL: url,
            conditionalValidator: validator
        )
        do {
            _ = try await conditionalClient.data(for: url)
            XCTFail("A conditional 304 must not be parsed as an empty feed")
        } catch is PodcastHTTPNotModified {
            // The caller can retain the last successful parse timestamp.
        }

        let unconditionalClient = PodcastHTTPClient(transport: ValidatorTransport())
        let (body, _) = try await unconditionalClient.data(for: url)
        XCTAssertEqual(body, Data("<rss/>".utf8))
        await store.invalidate(for: url, profile: nil)
        let afterInvalidation = await store.validated(for: url, profile: nil)
        XCTAssertNil(afterInvalidation)
    }

    func testLargePreparedFeedSpoolsInsteadOfBufferingParsedTree() throws {
        let description = String(repeating: "a", count: 7 * 1024 * 1024)
        var tags = PodcastNamespaceOptionalTags()
        tags.liveItem = [NamespaceNode(
            name: "podcast:liveItem",
            attributes: ["status": "live"],
            children: [NamespaceNode(name: "podcast:guid", value: "event-spool")]
        )]
        let prepared = try PreparedPodcastFeed([
            "description": description,
            "optionalTags": tags,
            "episodes": [[
                "title": "Episode",
                "externalFiles": [ExternalFile(
                    url: "https://example.com/transcript.vtt",
                    category: .transcript,
                    source: "feed",
                    fileType: "text/vtt"
                )]
            ] as [String: Any]]
        ])
        XCTAssertEqual(prepared.bufferedByteCount, 0)
        let imported = try prepared.importDictionary
        XCTAssertEqual((imported["description"] as? String)?.count, description.count)
        XCTAssertEqual(
            (imported["optionalTags"] as? PodcastNamespaceOptionalTags)?.liveItem?.first?.children.first?.value,
            "event-spool"
        )
        let episodes = try XCTUnwrap(imported["episodes"] as? [[String: Any]])
        XCTAssertEqual((episodes[0]["externalFiles"] as? [ExternalFile])?.first?.fileType, "text/vtt")
    }

    func testRateLimitedOriginWaitsForRetryAfter() async throws {
        let url = URL(string: "https://retry-\(UUID().uuidString).example.invalid/feed.xml")!
        let client = PodcastHTTPClient(transport: RetryTransport(state: RetryTransportState()))
        do {
            _ = try await client.data(for: url)
            XCTFail("First request should be rate limited")
        } catch let error as PodcastHTTPError {
            XCTAssertEqual(error.statusCode, 429)
        }
        let start = ContinuousClock.now
        _ = try await client.data(for: url)
        let elapsed = start.duration(to: .now)
        XCTAssertGreaterThanOrEqual(Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18, 0.17)
    }
}
