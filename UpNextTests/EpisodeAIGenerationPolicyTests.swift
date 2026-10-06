import XCTest
@testable import UpNext

final class EpisodeAIGenerationPolicyTests: XCTestCase {
    func testActionMatrixRequiresAppleIntelligence() {
        XCTAssertEqual(
            EpisodeAIGenerationPolicy.action(isAvailable: true, hasTranscript: false, hasUsableChapters: false),
            .transcribeAndGenerateChapters
        )
        XCTAssertEqual(
            EpisodeAIGenerationPolicy.action(isAvailable: true, hasTranscript: false, hasUsableChapters: true),
            .transcribe
        )
        XCTAssertEqual(
            EpisodeAIGenerationPolicy.action(isAvailable: true, hasTranscript: true, hasUsableChapters: false),
            .generateChapters
        )
        XCTAssertNil(EpisodeAIGenerationPolicy.action(isAvailable: true, hasTranscript: true, hasUsableChapters: true))
        XCTAssertNil(EpisodeAIGenerationPolicy.action(isAvailable: false, hasTranscript: false, hasUsableChapters: false))
        XCTAssertNil(EpisodeAIGenerationPolicy.action(isAvailable: false, hasTranscript: true, hasUsableChapters: false))
    }
}
