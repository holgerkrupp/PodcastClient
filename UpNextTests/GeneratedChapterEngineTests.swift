import XCTest

final class GeneratedChapterEngineTests: XCTestCase {
    func testGeneratesEditorialAndAdvertisementChaptersWithoutPublisherChapters() {
        let proposals = GeneratedChapterEngine.makeProposals(
            editorialCandidates: [
                GeneratedEditorialChapterCandidate(title: "Introduction", start: 0),
                GeneratedEditorialChapterCandidate(title: "Main topic", start: 600)
            ],
            adSegments: [confirmedAd(start: 300, end: 360)],
            existingTypes: [],
            episodeDuration: 1_200,
            audioVariantID: "variant-a"
        )

        XCTAssertEqual(proposals.map(\.kind), [.editorial, .advertisement, .editorial])
        XCTAssertEqual(proposals[1].title, "Advertisement")
        XCTAssertEqual(proposals[1].end, 360)
        XCTAssertEqual(proposals[1].audioVariantID, "variant-a")
    }

    func testPublisherChaptersRemainAuthoritative() {
        let proposals = GeneratedChapterEngine.makeProposals(
            editorialCandidates: [GeneratedEditorialChapterCandidate(title: "Generated", start: 0)],
            adSegments: [confirmedAd(start: 120, end: 180)],
            existingTypes: [.podlove],
            episodeDuration: 600,
            audioVariantID: "variant-a"
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testUncertainAndOpenEndedAdsAreNotMaterialized() {
        let uncertain = AdSegment(
            start: 60,
            end: 120,
            confidence: 0.9,
            evidence: [],
            state: .provisional,
            episodeIdentity: "episode"
        )
        let openEnded = AdSegment(
            start: 180,
            end: nil,
            confidence: 0.99,
            evidence: [],
            state: .confirmed,
            episodeIdentity: "episode"
        )

        let proposals = GeneratedChapterEngine.makeProposals(
            editorialCandidates: [],
            adSegments: [uncertain, openEnded],
            existingTypes: [],
            episodeDuration: 900,
            audioVariantID: "variant-a"
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testBackToBackConfirmedAdsRemainDistinct() {
        let proposals = GeneratedChapterEngine.makeProposals(
            editorialCandidates: [],
            adSegments: [
                confirmedAd(start: 60, end: 120),
                confirmedAd(start: 120, end: 180)
            ],
            existingTypes: [],
            episodeDuration: 600,
            audioVariantID: "variant-b"
        )

        XCTAssertEqual(proposals.count, 2)
        XCTAssertEqual(proposals.map(\.start), [60, 120])
    }

    func testLegacyChapterSyncPayloadRemainsDecodable() throws {
        let data = Data(#"[{"duration":5,"startTime":10,"title":"Old chapter"}]"#.utf8)
        let chapters = try JSONDecoder().decode([AIChapterValue].self, from: data)

        XCTAssertEqual(chapters.first?.title, "Old chapter")
        XCTAssertNil(chapters.first?.typeRawValue)
        XCTAssertNil(chapters.first?.analysisVariantID)
    }

    private func confirmedAd(start: TimeInterval, end: TimeInterval) -> AdSegment {
        AdSegment(
            start: start,
            end: end,
            confidence: 0.92,
            evidence: [],
            state: .confirmed,
            episodeIdentity: "episode"
        )
    }
}
