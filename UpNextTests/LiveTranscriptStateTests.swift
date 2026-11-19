import XCTest
import SwiftData
@testable import UpNext

final class LiveTranscriptStateTests: XCTestCase {
    func testCoverageMergesAndRepeatedFinalsAreIdempotent() {
        var state = LiveTranscriptState(mediaFingerprint: "media")
        let cue = LiveTranscriptState.Cue(id: UUID(), text: "Hello", start: 1, end: 2, spans: [])
        state.append(cues: [cue], coverage: .init(start: 0, end: 7))
        state.append(cues: [cue], coverage: .init(start: 7, end: 14))
        state.append(cues: [], coverage: .init(start: 20, end: 27))
        XCTAssertEqual(state.cues.count, 1)
        XCTAssertEqual(state.coverage, [.init(start: 0, end: 14), .init(start: 20, end: 27)])
        XCTAssertTrue(state.contains(13))
        XCTAssertFalse(state.contains(15))
        let revised = LiveTranscriptState.Cue(id: UUID(), text: "Hello again", start: 1.05, end: 2.05, spans: [])
        state.append(cues: [revised], coverage: .init(start: 0, end: 7))
        XCTAssertEqual(state.cues.count, 1)
        XCTAssertEqual(state.cues[0].id, cue.id)
        XCTAssertEqual(state.cues[0].text, "Hello again")
    }

    @MainActor
    func testFinalizedCoverageSurvivesReopeningLocalStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Library.sqlite")
        let episodeURL = URL(string: "https://example.com/live.mp3")!
        do {
            let container = try ModelContainerManager.makeLegacyContainer(storageURL: storeURL)
            let context = ModelContext(container)
            context.insert(Episode(title: "Example", url: episodeURL))
            try context.save()
            let actor = LiveTranscriptStoreActor(modelContainer: container)
            let cue = LiveTranscriptState.Cue(id: UUID(), text: "Saved speech", start: 1, end: 2, spans: [])
            let saved = try await actor.append(episodeURL: episodeURL, fingerprint: "media", windows: [
                .init(coverage: .init(start: 0, end: 7), cues: [cue])
            ])
            XCTAssertTrue(saved)
        }
        let reopened = try ModelContainerManager.makeLegacyContainer(storageURL: storeURL)
        let state = try await LiveTranscriptStoreActor(modelContainer: reopened).load(episodeURL: episodeURL)
        XCTAssertEqual(state?.cues.first?.text, "Saved speech")
        XCTAssertEqual(state?.coverage, [.init(start: 0, end: 7)])
    }

    @MainActor
    func testFailedWriteDoesNotEraseEarlierCoverage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Library.sqlite")
        let episodeURL = URL(string: "https://example.com/live-read-only.mp3")!
        do {
            let container = try ModelContainerManager.makeLegacyContainer(storageURL: storeURL)
            let context = ModelContext(container)
            context.insert(Episode(title: "Example", url: episodeURL))
            try context.save()
            let actor = LiveTranscriptStoreActor(modelContainer: container)
            _ = try await actor.append(episodeURL: episodeURL, fingerprint: "media", windows: [
                .init(coverage: .init(start: 0, end: 7), cues: [.init(id: UUID(), text: "Saved", start: 1, end: 2, spans: [])])
            ])
        }
        do {
            let readOnly = try ModelContainerManager.makeLegacyContainer(allowsSave: false, storageURL: storeURL)
            let actor = LiveTranscriptStoreActor(modelContainer: readOnly)
            do {
                _ = try await actor.append(episodeURL: episodeURL, fingerprint: "media", windows: [
                    .init(coverage: .init(start: 7, end: 14), cues: [.init(id: UUID(), text: "Pending", start: 8, end: 9, spans: [])])
                ])
                XCTFail("A read-only store must reject the write")
            } catch { }
        }
        let reopened = try ModelContainerManager.makeLegacyContainer(storageURL: storeURL)
        let state = try await LiveTranscriptStoreActor(modelContainer: reopened).load(episodeURL: episodeURL)
        XCTAssertEqual(state?.cues.map(\.text), ["Saved"])
        XCTAssertEqual(state?.coverage, [.init(start: 0, end: 7)])
    }
}
