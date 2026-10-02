import CryptoKit
import Foundation
import SQLite3

enum TranscriptSearchScope: Hashable, Sendable {
    case episode(String)
    case podcast(String)
    case library
}

struct TranscriptSearchQuery: Sendable {
    let text: String
    let scope: TranscriptSearchScope
    let limit: Int
    let offset: Int

    init(text: String, scope: TranscriptSearchScope, limit: Int = 80, offset: Int = 0) {
        self.text = text
        self.scope = scope
        self.limit = max(1, min(limit, 250))
        self.offset = max(0, offset)
    }
}

struct TranscriptSearchPassage: Identifiable, Hashable, Sendable {
    let id: String
    let podcastID: String
    let podcastTitle: String
    let podcastImageURL: URL?
    let episodeID: String
    let episodeTitle: String
    let episodeURL: URL?
    let episodeImageURL: URL?
    let publishDate: Date?
    let text: String
    let snippet: String
    let speaker: String?
    let startTime: TimeInterval
    let endTime: TimeInterval?
    let matchedTerms: [String]
}

struct TranscriptSearchEpisodeGroup: Identifiable, Hashable, Sendable {
    let episodeID: String
    let episodeTitle: String
    let episodeURL: URL?
    let episodeImageURL: URL?
    let publishDate: Date?
    let passages: [TranscriptSearchPassage]

    var id: String { episodeID }
}

struct TranscriptSearchPodcastGroup: Identifiable, Hashable, Sendable {
    let podcastID: String
    let podcastTitle: String
    let podcastImageURL: URL?
    let episodes: [TranscriptSearchEpisodeGroup]

    var id: String { podcastID }
    var passageCount: Int { episodes.reduce(0) { $0 + $1.passages.count } }
}

struct TranscriptSearchIndexStatus: Hashable, Sendable {
    let indexedEpisodes: Int
    let eligibleEpisodes: Int
    let isBackfillInProgress: Bool
    let lastError: String?
}

struct TranscriptSearchSnapshot: Sendable {
    let groups: [TranscriptSearchPodcastGroup]
    let totalMatches: Int
    let status: TranscriptSearchIndexStatus
}

struct TranscriptSearchLine: Sendable, Hashable {
    let id: String
    let speaker: String?
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
}

struct TranscriptSearchEpisodeSnapshot: Sendable, Hashable {
    let podcastID: String
    let podcastTitle: String
    let podcastImageURL: URL?
    let episodeID: String
    let episodeTitle: String
    let episodeURL: URL?
    let episodeImageURL: URL?
    let publishDate: Date?
    let revision: String
    let lines: [TranscriptSearchLine]

    init(
        podcastID: String,
        podcastTitle: String,
        podcastImageURL: URL?,
        episodeID: String,
        episodeTitle: String,
        episodeURL: URL?,
        episodeImageURL: URL?,
        publishDate: Date?,
        revision: String,
        lines: [TranscriptSearchLine]
    ) {
        self.podcastID = podcastID
        self.podcastTitle = podcastTitle
        self.podcastImageURL = podcastImageURL
        self.episodeID = episodeID
        self.episodeTitle = episodeTitle
        self.episodeURL = episodeURL
        self.episodeImageURL = episodeImageURL
        self.publishDate = publishDate
        self.revision = revision
        self.lines = lines
    }
}

enum TranscriptSearchText {
    static func matches(_ text: String, query: String) -> Bool {
        let normalizedText = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "ß", with: "ss")
        let normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "ß", with: "ss")
        guard normalizedQuery.isEmpty == false else { return false }
        return normalizedText.range(of: normalizedQuery) != nil
    }
}

enum TranscriptSearchIndexError: LocalizedError {
    case databaseOpenFailed(String)
    case databaseCommandFailed(String)
    case invalidQuery

    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let message):
            return "The transcript search index could not be opened: \(message)"
        case .databaseCommandFailed(let message):
            return "The transcript search index failed: \(message)"
        case .invalidQuery:
            return "Enter a word or phrase to search transcripts."
        }
    }
}

protocol TranscriptSearchService: Sendable {
    func search(_ request: TranscriptSearchQuery) async throws -> TranscriptSearchSnapshot
}

/// A disposable, local-only FTS5 index. Transcript lines remain canonical in SwiftData;
/// this actor only owns derived search rows and can safely be deleted and rebuilt.
actor TranscriptSearchIndex: TranscriptSearchService {
    static let shared = TranscriptSearchIndex()

    private static let schemaVersion = "2"
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let storeURL: URL
    private var database: OpaquePointer?

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
    }

    isolated deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    static func defaultStoreURL() -> URL {
        let baseURL = ModelContainerManager.sharedContainerURL
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("TranscriptSearch", isDirectory: true)
            .appendingPathComponent("TranscriptSearch.sqlite")
    }

    func search(_ request: TranscriptSearchQuery) throws -> TranscriptSearchSnapshot {
        let startedAt = Date()
        let normalizedText = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedText.isEmpty == false else { throw TranscriptSearchIndexError.invalidQuery }

        try openIfNeeded()
        let ftsQuery = Self.makeFTSQuery(normalizedText)
        guard ftsQuery.isEmpty == false else { throw TranscriptSearchIndexError.invalidQuery }

        let scopeClause: String
        switch request.scope {
        case .library:
            scopeClause = "1 = 1"
        case .podcast:
            scopeClause = "podcast_id = ?"
        case .episode:
            scopeClause = "episode_id = ?"
        }

        let sql = """
        SELECT podcast_id, podcast_title, podcast_image_url, episode_id, episode_title,
               episode_url, episode_image_url, publish_date, passage_id, text, speaker,
               start_time, end_time
        FROM passages
        WHERE passages MATCH ? AND \(scopeClause)
        ORDER BY bm25(passages), publish_date DESC, start_time ASC, passage_id ASC
        LIMIT ? OFFSET ?
        """

        var results: [TranscriptSearchPassage] = []
        try withStatement(sql) { statement in
            var bindIndex: Int32 = 1
            try bind(normalizedText: ftsQuery, to: statement, at: bindIndex)
            bindIndex += 1
            switch request.scope {
            case .library:
                break
            case .podcast(let id), .episode(let id):
                try bind(text: id, to: statement, at: bindIndex)
                bindIndex += 1
            }
            sqlite3_bind_int(statement, bindIndex, Int32(request.limit))
            sqlite3_bind_int(statement, bindIndex + 1, Int32(request.offset))

            while sqlite3_step(statement) == SQLITE_ROW {
                let podcastID = columnText(statement, 0)
                let episodeID = columnText(statement, 3)
                let passageID = columnText(statement, 8)
                guard podcastID.isEmpty == false, episodeID.isEmpty == false, passageID.isEmpty == false else {
                    continue
                }
                results.append(
                    TranscriptSearchPassage(
                        id: passageID,
                        podcastID: podcastID,
                        podcastTitle: columnText(statement, 1),
                        podcastImageURL: URL(string: columnText(statement, 2)),
                        episodeID: episodeID,
                        episodeTitle: columnText(statement, 4),
                        episodeURL: URL(string: columnText(statement, 5)),
                        episodeImageURL: URL(string: columnText(statement, 6)),
                        publishDate: columnDate(statement, 7),
                        text: columnText(statement, 9),
                        snippet: Self.makeSnippet(from: columnText(statement, 9), query: normalizedText),
                        speaker: columnOptionalText(statement, 10),
                        startTime: sqlite3_column_double(statement, 11),
                        endTime: columnOptionalDouble(statement, 12),
                        matchedTerms: Self.queryTerms(from: normalizedText)
                    )
                )
            }
        }

        let totalMatches = try countMatches(ftsQuery: ftsQuery, scope: request.scope)
        let groups = Self.group(results)
        let duration = Date().timeIntervalSince(startedAt)
        AppDiagnostics.log(
            "transcript_search_query_completed duration_ms=\(Int(duration * 1_000)) result_count=\(results.count)"
        )
        return TranscriptSearchSnapshot(groups: groups, totalMatches: totalMatches, status: try status())
    }

    @discardableResult
    func upsert(_ episode: TranscriptSearchEpisodeSnapshot) throws -> Bool {
        try openIfNeeded()
        let startedAt = Date()
        guard episode.lines.isEmpty == false else {
            try removeEpisode(episodeID: episode.episodeID)
            return true
        }

        if try indexedRevision(for: episode.episodeID) == episode.revision {
            return false
        }

        try execute("BEGIN IMMEDIATE")
        do {
            try deletePassages(forEpisodeID: episode.episodeID)
            let sql = """
            INSERT INTO passages(
                passage_id, podcast_id, podcast_title, podcast_image_url, episode_id,
                episode_title, episode_url, episode_image_url, publish_date, speaker,
                search_text, start_time, end_time, revision, text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            for line in episode.lines {
                try withStatement(sql) { statement in
                    let values: [(Int32, String?)] = [
                        (1, line.id), (2, episode.podcastID), (3, episode.podcastTitle),
                        (4, episode.podcastImageURL?.absoluteString), (5, episode.episodeID),
                        (6, episode.episodeTitle), (7, episode.episodeURL?.absoluteString),
                        (8, episode.episodeImageURL?.absoluteString),
                        (9, episode.publishDate.map { String($0.timeIntervalSince1970) }),
                        (10, line.speaker), (11, line.text),
                        (12, String(line.startTime)), (13, line.endTime.map { String($0) }),
                        (14, episode.revision), (15, line.text)
                    ]
                    for (index, value) in values {
                        if let value {
                            let boundValue = index == 11
                                ? Self.searchableText(value)
                                : value
                            try bind(text: boundValue, to: statement, at: index)
                        } else {
                            sqlite3_bind_null(statement, index)
                        }
                    }
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw commandError()
                    }
                }
            }
            try execute(
                "INSERT INTO indexed_episodes(episode_id, podcast_id, revision, updated_at) VALUES (?, ?, ?, ?) "
                    + "ON CONFLICT(episode_id) DO UPDATE SET podcast_id=excluded.podcast_id, revision=excluded.revision, updated_at=excluded.updated_at",
                bindings: [episode.episodeID, episode.podcastID, episode.revision, String(Date().timeIntervalSince1970)]
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }

        let duration = Date().timeIntervalSince(startedAt)
        AppDiagnostics.log(
            "transcript_search_index_episode_completed duration_ms=\(Int(duration * 1_000)) line_count=\(episode.lines.count)"
        )
        return true
    }

    func removeEpisode(episodeID: String) throws {
        try openIfNeeded()
        try deletePassages(forEpisodeID: episodeID)
        try execute("DELETE FROM indexed_episodes WHERE episode_id = ?", bindings: [episodeID])
    }

    func setBackfillState(inProgress: Bool, lastError: String? = nil) throws {
        try openIfNeeded()
        try setMeta("backfill_in_progress", value: inProgress ? "1" : "0")
        try setMeta("last_error", value: lastError ?? "")
    }

    func setEligibleEpisodeCount(_ count: Int) throws {
        try openIfNeeded()
        try setMeta("eligible_episode_count", value: String(max(0, count)))
    }

    /// Keeps the progress indicator stable across resumable batches. The
    /// derived index is the authoritative count of episodes that currently
    /// have searchable transcript passages; unlike adding the current batch,
    /// this remains correct when a run resumes or repeats.
    func refreshEligibleEpisodeCount() throws {
        try setEligibleEpisodeCount(try scalarInt("SELECT COUNT(*) FROM indexed_episodes"))
    }

    func hasSearchableTranscripts(in scope: TranscriptSearchScope) throws -> Bool {
        try openIfNeeded()
        let whereClause: String
        let bindings: [String]
        switch scope {
        case .library:
            whereClause = "1 = 1"
            bindings = []
        case .podcast(let podcastID):
            whereClause = "podcast_id = ?"
            bindings = [podcastID]
        case .episode(let episodeID):
            whereClause = "episode_id = ?"
            bindings = [episodeID]
        }
        return try scalarInt(
            "SELECT 1 FROM passages WHERE \(whereClause) LIMIT 1",
            bindings: bindings
        ) == 1
    }

    func status() throws -> TranscriptSearchIndexStatus {
        try openIfNeeded()
        let indexed = try scalarInt("SELECT COUNT(*) FROM indexed_episodes")
        let eligible = Int(try meta("eligible_episode_count") ?? "0") ?? 0
        let inProgress = (try meta("backfill_in_progress")) == "1"
        let error = try meta("last_error").flatMap { $0.isEmpty ? nil : $0 }
        return TranscriptSearchIndexStatus(
            indexedEpisodes: indexed,
            eligibleEpisodes: eligible,
            isBackfillInProgress: inProgress,
            lastError: error
        )
    }

    func rebuild() throws {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        try openIfNeeded()
    }

    private func openIfNeeded() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        guard sqlite3_open_v2(
            storeURL.path,
            &opened,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let opened { sqlite3_close(opened) }
            throw TranscriptSearchIndexError.databaseOpenFailed(message)
        }
        database = opened
        sqlite3_busy_timeout(opened, 2_000)
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("CREATE TABLE IF NOT EXISTS transcript_search_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            if try meta("schema_version") != Self.schemaVersion {
                try execute("DROP TABLE IF EXISTS passages")
                try execute("DROP TABLE IF EXISTS indexed_episodes")
                try setMeta("schema_version", value: Self.schemaVersion)
            }
            try execute("CREATE TABLE IF NOT EXISTS indexed_episodes(episode_id TEXT PRIMARY KEY, podcast_id TEXT NOT NULL, revision TEXT NOT NULL, updated_at REAL NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS indexed_episodes_podcast_id ON indexed_episodes(podcast_id)")
            try execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(
                    passage_id UNINDEXED, podcast_id UNINDEXED, podcast_title UNINDEXED,
                    podcast_image_url UNINDEXED, episode_id UNINDEXED, episode_title UNINDEXED,
                    episode_url UNINDEXED, episode_image_url UNINDEXED, publish_date UNINDEXED,
                    speaker, search_text, start_time UNINDEXED, end_time UNINDEXED,
                    revision UNINDEXED, text UNINDEXED, tokenize='unicode61 remove_diacritics 2'
                )
                """)
        } catch {
            sqlite3_close(opened)
            database = nil
            throw error
        }
    }

    private func indexedRevision(for episodeID: String) throws -> String? {
        try scalarText("SELECT revision FROM indexed_episodes WHERE episode_id = ?", bindings: [episodeID])
    }

    private func deletePassages(forEpisodeID episodeID: String) throws {
        try execute("DELETE FROM passages WHERE episode_id = ?", bindings: [episodeID])
    }

    private func countMatches(ftsQuery: String, scope: TranscriptSearchScope) throws -> Int {
        let scopeClause: String
        switch scope {
        case .library: scopeClause = "1 = 1"
        case .podcast: scopeClause = "podcast_id = ?"
        case .episode: scopeClause = "episode_id = ?"
        }
        var bindings = [ftsQuery]
        switch scope {
        case .library: break
        case .podcast(let id), .episode(let id): bindings.append(id)
        }
        return try scalarInt(
            "SELECT COUNT(*) FROM passages WHERE passages MATCH ? AND \(scopeClause)",
            bindings: bindings
        )
    }

    private func setMeta(_ key: String, value: String) throws {
        try execute(
            "INSERT INTO transcript_search_meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            bindings: [key, value]
        )
    }

    private func meta(_ key: String) throws -> String? {
        try scalarText("SELECT value FROM transcript_search_meta WHERE key = ?", bindings: [key])
    }

    private func scalarInt(_ sql: String, bindings: [String] = []) throws -> Int {
        var value = 0
        try withStatement(sql) { statement in
            try bind(bindings, to: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                value = Int(sqlite3_column_int64(statement, 0))
            }
        }
        return value
    }

    private func scalarText(_ sql: String, bindings: [String] = []) throws -> String? {
        var value: String?
        try withStatement(sql) { statement in
            try bind(bindings, to: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                value = columnOptionalText(statement, 0)
            }
        }
        return value
    }

    private func execute(_ sql: String, bindings: [String] = []) throws {
        try withStatement(sql) { statement in
            try bind(bindings, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw commandError() }
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let database else { throw TranscriptSearchIndexError.databaseOpenFailed("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw commandError()
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ values: [String], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            try bind(text: value, to: statement, at: Int32(offset + 1))
        }
    }

    private func bind(text: String, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, text, -1, Self.transientDestructor) == SQLITE_OK else {
            throw commandError()
        }
    }

    private func bind(normalizedText text: String, to statement: OpaquePointer, at index: Int32) throws {
        try bind(text: text, to: statement, at: index)
    }

    private func commandError() -> TranscriptSearchIndexError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        return .databaseCommandFailed(message)
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        columnOptionalText(statement, index) ?? ""
    }

    private func columnOptionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }

    private func columnDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func columnOptionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private static func makeFTSQuery(_ query: String) -> String {
        let cleaned = searchableText(query)
            .replacingOccurrences(of: "\"", with: "\"\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.isEmpty == false else { return "" }
        if cleaned.contains(where: { $0.isWhitespace }) {
            return "\"\(cleaned)\""
        }
        return "\"\(cleaned)\"*"
    }

    private static func queryTerms(from query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map { String($0) }
    }

    private static func searchableText(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "ẞ", with: "ss")
    }

    private static func makeSnippet(from text: String, query: String, maxLength: Int = 180) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxLength else {
            return Self.markDirectMatch(in: cleaned, query: query)
        }

        let searchable = searchableText(cleaned)
        let searchableQuery = searchableText(query)
        guard let range = searchable.range(of: searchableQuery) else {
            return String(cleaned.prefix(maxLength))
        }
        let offset = searchable.distance(from: searchable.startIndex, to: range.lowerBound)
        let startOffset = max(0, offset - maxLength / 2)
        let startIndex = cleaned.index(cleaned.startIndex, offsetBy: min(startOffset, cleaned.count))
        let length = min(maxLength, cleaned.distance(from: startIndex, to: cleaned.endIndex))
        let endIndex = cleaned.index(startIndex, offsetBy: length)
        let value = String(cleaned[startIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let markedValue = Self.markDirectMatch(in: value, query: query)
        return (startOffset == 0 ? "" : "…") + markedValue
    }

    private static func markDirectMatch(in text: String, query: String) -> String {
        guard let range = text.range(
            of: query.trimmingCharacters(in: .whitespacesAndNewlines),
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: .current
        ) else {
            return text
        }
        return String(text[..<range.lowerBound])
            + "["
            + String(text[range])
            + "]"
            + String(text[range.upperBound...])
    }

    private static func group(_ results: [TranscriptSearchPassage]) -> [TranscriptSearchPodcastGroup] {
        var episodesByPodcast: [String: [String: [TranscriptSearchPassage]]] = [:]
        var podcastMetadata: [String: (String, URL?)] = [:]
        var episodeMetadata: [String: (String, URL?, URL?, Date?)] = [:]

        for result in results {
            episodesByPodcast[result.podcastID, default: [:]][result.episodeID, default: []].append(result)
            podcastMetadata[result.podcastID] = (result.podcastTitle, result.podcastImageURL)
            episodeMetadata[result.episodeID] = (
                result.episodeTitle,
                result.episodeURL,
                result.episodeImageURL,
                result.publishDate
            )
        }

        return episodesByPodcast.keys.sorted { lhs, rhs in
            let left = podcastMetadata[lhs]?.0 ?? ""
            let right = podcastMetadata[rhs]?.0 ?? ""
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }.compactMap { podcastID in
            guard let metadata = podcastMetadata[podcastID] else { return nil }
            let episodes = episodesByPodcast[podcastID, default: [:]].keys.sorted { lhs, rhs in
                let left = episodeMetadata[lhs]?.3 ?? .distantPast
                let right = episodeMetadata[rhs]?.3 ?? .distantPast
                if left != right { return left > right }
                return (episodeMetadata[lhs]?.0 ?? "").localizedCaseInsensitiveCompare(episodeMetadata[rhs]?.0 ?? "") == .orderedAscending
            }.compactMap { episodeID -> TranscriptSearchEpisodeGroup? in
                guard let episode = episodeMetadata[episodeID] else { return nil }
                return TranscriptSearchEpisodeGroup(
                    episodeID: episodeID,
                    episodeTitle: episode.0,
                    episodeURL: episode.1,
                    episodeImageURL: episode.2,
                    publishDate: episode.3,
                    passages: episodesByPodcast[podcastID]?[episodeID] ?? []
                )
            }
            return TranscriptSearchPodcastGroup(
                podcastID: podcastID,
                podcastTitle: metadata.0,
                podcastImageURL: metadata.1,
                episodes: episodes
            )
        }
    }
}

extension TranscriptSearchEpisodeSnapshot {
    init(episode: Episode, lines: [TranscriptLineSnapshot], source: String) {
        let identity = episode.stableEpisodeIdentity
        // Index readable passages rather than every tiny ASR fragment. The
        // canonical line store remains untouched, so exact playback still uses
        // the passage's start timestamp and the full transcript can show every
        // source line when opened.
        let sources = lines.enumerated().map { index, line in
            TranscriptSegmentSource(
                id: StableIdentityKey.uuid(for: StableIdentityKey.make(identity.key, source, String(index))),
                speaker: line.speaker,
                text: line.text,
                startTime: line.startTime,
                endTime: line.endTime
            )
        }
        let segments = TranscriptSegmentBuilder.makeSegments(from: sources, options: .full)
        let lineValues = segments.map { segment in
            TranscriptSearchLine(
                id: StableIdentityKey.make(identity.key, source, segment.id.uuidString),
                speaker: segment.speaker,
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
        }
        let fingerprintInput = lineValues.map {
            "\($0.id)|\($0.speaker ?? "")|\($0.text)|\($0.startTime)|\($0.endTime ?? -1)"
        }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(fingerprintInput.utf8))
        let revision = source + ":" + digest.map { String(format: "%02x", $0) }.joined()

        self.init(
            podcastID: episode.podcast?.stablePodcastIdentityKey ?? "__missing_podcast__",
            podcastTitle: episode.displayPodcastTitle ?? "Unknown Podcast",
            podcastImageURL: episode.podcast?.imageURL,
            episodeID: identity.key,
            episodeTitle: episode.title,
            episodeURL: episode.url,
            episodeImageURL: episode.imageURL,
            publishDate: episode.publishDate,
            revision: revision,
            lines: lineValues
        )
    }
}
