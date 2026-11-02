import Foundation
import Testing
@testable import UpNext

/// Serves a fixed media file and records each request, answering Range
/// requests with 206 unless told to ignore them.
private final class MediaFixtureTransport: PodcastHTTPTransport, @unchecked Sendable {
    let file: Data
    let ignoresRange: Bool
    let status: Int
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var bytesSent = 0

    init(file: Data, ignoresRange: Bool = false, status: Int = 200) {
        self.file = file
        self.ignoresRange = ignoresRange
        self.status = status
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
    var totalBytesSent: Int { lock.withLock { bytesSent } }

    func data(
        for request: URLRequest,
        profile: PodcastAccessProfile?,
        resolver: PodcastAccessResolver
    ) async throws -> (Data, URLResponse) {
        lock.withLock { recorded.append(request) }
        let url = request.url!
        guard status == 200 else {
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if ignoresRange == false,
           let header = request.value(forHTTPHeaderField: "Range"),
           let bounds = Self.bounds(header) {
            let slice = file.subdata(in: bounds.lowerBound..<min(bounds.upperBound, file.count))
            lock.withLock { bytesSent += slice.count }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: nil,
                headerFields: ["Content-Range": "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(file.count)"]
            )!
            return (slice, response)
        }
        lock.withLock { bytesSent += file.count }
        return (file, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private static func bounds(_ header: String) -> Range<Int>? {
        let parts = header.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0]..<(parts[1] + 1)
    }
}

@Suite("Remote embedded chapters")
struct RemoteEmbeddedChapterTests {
    private let mediaURL = URL(string: "https://media.example.com/plus/episode.mp3")!

    /// An ID3v2.3 tag with two CHAP frames, followed by fake audio.
    private func taggedFile(audioBytes: Int = 400_000) -> (file: Data, tagSize: Int) {
        func uint32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        func frame(_ id: String, _ body: Data) -> Data {
            Data(id.utf8) + uint32(UInt32(body.count)) + Data([0, 0]) + body
        }
        func chapter(_ id: String, title: String, startMS: UInt32, endMS: UInt32) -> Data {
            let title = frame("TIT2", Data([0]) + Data(title.utf8))
            let body = Data(id.utf8) + Data([0]) + uint32(startMS) + uint32(endMS)
                + uint32(.max) + uint32(.max) + title
            return frame("CHAP", body)
        }
        let frames = chapter("ch0", title: "Intro", startMS: 0, endMS: 60_000)
            + chapter("ch1", title: "News", startMS: 60_000, endMS: 120_000)
        let size = frames.count
        let synchsafe = Data([
            UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F),
            UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)
        ])
        let tag = Data("ID3".utf8) + Data([3, 0, 0]) + synchsafe + frames
        return (tag + Data(repeating: 0xFF, count: audioBytes), tag.count)
    }

    private func basicClient(_ transport: MediaFixtureTransport) throws -> (PodcastHTTPClient, PodcastAccessProfile) {
        let store = InMemoryPodcastCredentialStore()
        let profile = PodcastAccessProfile(
            id: "plus",
            kind: .httpBasic,
            resourceURL: URL(string: "https://media.example.com/plus/feed.xml")!
        )
        try store.save(.httpBasic(username: "listener", password: "secret"), for: profile)
        let client = PodcastHTTPClient(resolver: PodcastAccessResolver(credentialStore: store), transport: transport)
        return (client, profile)
    }

    @Test func authenticatedMP3ReadsOnlyTheTagWithCredentials() async throws {
        let (file, tagSize) = taggedFile()
        let transport = MediaFixtureTransport(file: file)
        let (client, profile) = try basicClient(transport)

        let probe = try await RemoteEmbeddedChapterLoader.probe(mediaURL, profile: profile, client: client)

        guard case .id3Tag(let tag) = probe else {
            Issue.record("Expected an ID3 tag, got \(probe)")
            return
        }
        #expect(tag.count == tagSize)
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Range") != nil })
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true })
        #expect(transport.totalBytesSent == 10 + tagSize)
    }

    @Test func serverIgnoringRangeIsCutAtTheTag() async throws {
        let (file, tagSize) = taggedFile()
        let transport = MediaFixtureTransport(file: file, ignoresRange: true)
        let (client, profile) = try basicClient(transport)

        let (data, response) = try await client.rangeData(for: mediaURL, range: 0..<tagSize, profile: profile)

        #expect(response.statusCode == 200)
        #expect(data == file.prefix(tagSize))
    }

    @Test func rangeResponseThatStartsElsewhereIsRejected() throws {
        let response = HTTPURLResponse(
            url: mediaURL,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Range": "bytes 500-509/1000"]
        )!
        #expect(throws: PodcastRangeRequestError.rangeNotSatisfied) {
            try PodcastHTTPClient.slice(Data(count: 10), of: 0..<10, from: response)
        }
    }

    @Test func mpeg4IsRecognisedFromItsFirstBytes() async throws {
        let file = Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8) + Data(count: 1_000)
        let transport = MediaFixtureTransport(file: file)
        let client = PodcastHTTPClient(transport: transport)

        let probe = try await RemoteEmbeddedChapterLoader.probe(
            URL(string: "https://media.example.com/episode")!,
            profile: nil,
            client: client
        )

        guard case .mpeg4 = probe else {
            Issue.record("Expected MPEG-4, got \(probe)")
            return
        }
    }

    @Test func rejectedCredentialsAreReportedAsSuch() async throws {
        let transport = MediaFixtureTransport(file: Data(), status: 401)
        let (client, profile) = try basicClient(transport)

        do {
            _ = try await RemoteEmbeddedChapterLoader.probe(
                URL(string: "https://media.example.com/plus/rejected.mp3")!,
                profile: profile,
                client: client
            )
            Issue.record("Expected an error")
        } catch {
            #expect(RemoteChapterOutcome.classify(error) == .authenticationRejected(status: 401))
        }
    }

    @Test func fixtureTagParsesAsTwoChapters() async throws {
        let (file, _) = taggedFile(audioBytes: 1_000)
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try file.write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let local = await ChapterExtractionHooks.loadLocalMP3Chapters(localURL)
        #expect(local.map(\.title) == ["Intro", "News"])
        #expect(local.map(\.start) == [0, 60])
        #expect(local.allSatisfy { $0.type == .mp3 })
    }
}
