import XCTest
@testable import UpNext

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

    func testTranscriptSemanticAdCreatesAdAndExplicitEditorialResumeWithoutPlaybackEvidence() {
        let proposals = GeneratedChapterEngine.makeProposals(
            editorialCandidates: [
                GeneratedEditorialChapterCandidate(title: "Opening", start: 0),
                GeneratedEditorialChapterCandidate(title: "Back to the discussion", start: 420)
            ],
            advertisementCandidates: [GeneratedAdvertisementCandidate(start: 300)],
            adSegments: [],
            existingTypes: [],
            episodeDuration: 900,
            audioVariantID: "variant-a"
        )

        XCTAssertEqual(proposals.map(\.kind), [.editorial, .advertisement, .editorial])
        XCTAssertEqual(proposals[1].start, 300)
        XCTAssertEqual(proposals[1].end, 420)
        XCTAssertEqual(proposals[2].start, 420)
    }

    func testMultipleSponsorBoundariesInOneContinuousBreakCollapseToOneAd() {
        let proposals = GeneratedChapterEngine.makeProposals(
            editorialCandidates: [GeneratedEditorialChapterCandidate(title: "Editorial resumes", start: 500)],
            advertisementCandidates: [
                GeneratedAdvertisementCandidate(start: 300),
                GeneratedAdvertisementCandidate(start: 360)
            ],
            adSegments: [],
            existingTypes: [],
            episodeDuration: 900,
            audioVariantID: "variant-a"
        )

        XCTAssertEqual(proposals.filter { $0.kind == .advertisement }.count, 1)
        XCTAssertEqual(proposals.first(where: { $0.kind == .advertisement })?.end, 500)
        XCTAssertEqual(proposals.last?.start, 500)
    }

    func testConfirmedDetectorBoundarySupersedesSemanticAdForSameRange() {
        let proposals = GeneratedChapterEngine.makeProposals(
            editorialCandidates: [GeneratedEditorialChapterCandidate(title: "Return", start: 450)],
            advertisementCandidates: [GeneratedAdvertisementCandidate(start: 300)],
            adSegments: [confirmedAd(start: 290, end: 455)],
            existingTypes: [],
            episodeDuration: 900,
            audioVariantID: "variant-a"
        )

        XCTAssertEqual(proposals.filter { $0.kind == .advertisement }.count, 1)
        XCTAssertEqual(proposals.first(where: { $0.kind == .advertisement })?.start, 290)
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
