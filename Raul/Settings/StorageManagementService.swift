import Foundation
import SwiftData

enum StorageFileRoot: String, CaseIterable, Identifiable, Hashable, Sendable {
    case caches
    case documents
    case shared

    var id: String { rawValue }

    var title: String {
        switch self {
        case .caches:
            "Cache Files"
        case .documents:
            "Documents"
        case .shared:
            "Shared Files"
        }
    }

    var systemImage: String {
        switch self {
        case .caches:
            "internaldrive"
        case .documents:
            "doc.text"
        case .shared:
            "rectangle.2.swap"
        }
    }

    var baseURL: URL? {
        switch self {
        case .caches:
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        case .documents:
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        case .shared:
            ModelContainerManager.sharedContainerURL
        }
    }
}

enum StorageDatabaseCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case podcasts
    case episodes
    case transcriptLines
    case chapters
    case bookmarks
    case transcriptionRecords
    case playlists
    case listeningHistory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .podcasts:
            "Podcasts"
        case .episodes:
            "Episodes"
        case .transcriptLines:
            "Transcript Lines"
        case .chapters:
            "Chapters"
        case .bookmarks:
            "Bookmarks"
        case .transcriptionRecords:
            "Transcription Records"
        case .playlists:
            "Playlists"
        case .listeningHistory:
            "Listening History"
        }
    }
}

struct StorageTypeUsage: Identifiable, Hashable, Sendable {
    let category: StorageDatabaseCategory
    let count: Int
    let bytes: Int64

    var id: StorageDatabaseCategory { category }
}

struct StorageDatabaseArtifact: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let size: Int64

    var id: String { url.path }
}

struct StorageFileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let root: StorageFileRoot
    let relativePath: String
    let size: Int64
    let associatedEpisodeURL: URL?
    let episodeTitle: String?
    let podcastID: String?
    let podcastTitle: String?

    var id: String { url.path }
    var displayName: String { url.lastPathComponent }
}

struct PodcastStorageUsage: Identifiable, Hashable, Sendable {
    let id: String
    let podcastTitle: String
    let estimatedDatabaseBytes: Int64
    let fileBytes: Int64
    let fileCount: Int
    let episodeCount: Int
    let transcriptLineCount: Int
    let chapterCount: Int
    let bookmarkCount: Int
    let transcriptionRecordCount: Int
    let typeBreakdown: [StorageTypeUsage]

    var totalBytes: Int64 {
        estimatedDatabaseBytes + fileBytes
    }
}

struct StorageUsageReport: Sendable {
    let generatedAt: Date
    let databaseBytes: Int64
    let fileBytes: Int64
    let databaseArtifacts: [StorageDatabaseArtifact]
    let databaseBreakdown: [StorageTypeUsage]
    let podcasts: [PodcastStorageUsage]
    let files: [StorageFileEntry]
    let upNextEpisodeURLStrings: Set<String>
    let upNextProtectedFileBytes: Int64
    let upNextProtectedFileCount: Int
    let unattributedDatabaseBytes: Int64
    let unattributedFileBytes: Int64
    let unattributedFileCount: Int

    var totalStorageBytes: Int64 {
        databaseBytes + fileBytes
    }
}

struct StorageCleanupResult: Sendable {
    let deletedFileCount: Int
    let deletedBytes: Int64
    let keptUpNextFileCount: Int
}

actor StorageManagementService {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func makeReport() async throws -> StorageUsageReport {
        let context = ModelContext(modelContainer)

        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        let transcriptionRecords = try context.fetch(FetchDescriptor<TranscriptionRecord>())
        let playlists = try context.fetch(FetchDescriptor<Playlist>())
        let playlistEntries = try context.fetch(FetchDescriptor<PlaylistEntry>())
        let playSessions = try context.fetch(FetchDescriptor<PlaySession>())
        let listeningStats = try context.fetch(FetchDescriptor<ListeningStat>())
        let summaries = try context.fetch(FetchDescriptor<PlaySessionSummary>())

        var databaseCategoryTotals: [StorageDatabaseCategory: RawUsage] = [:]
        var podcastBuckets: [String: PodcastAccumulator] = [:]
        var podcastTitleIndex: [String: String] = [:]
        var episodeAssociationsByFileURL: [URL: FileAssociation] = [:]
        var episodeAssociationsByEpisodeURL: [URL: FileAssociation] = [:]

        func addGlobalUsage(_ category: StorageDatabaseCategory, count: Int = 1, bytes: Int64) {
            guard bytes > 0 || count > 0 else { return }
            var usage = databaseCategoryTotals[category, default: RawUsage()]
            usage.count += count
            usage.bytes += max(bytes, 0)
            databaseCategoryTotals[category] = usage
        }

        func podcastKey(for podcast: Podcast) -> (id: String, title: String) {
            let title = Self.cleanedTitle(podcast.title, fallback: podcast.feed?.host ?? "Untitled Podcast")
            let id = podcast.feed?.absoluteString ?? "podcast:\(title)"
            return (id, title)
        }

        func ensurePodcastBucket(id: String, title: String) {
            if podcastBuckets[id] == nil {
                podcastBuckets[id] = PodcastAccumulator(id: id, title: title)
            }
            podcastTitleIndex[title] = id
        }

        for podcast in podcasts {
            let key = podcastKey(for: podcast)
            ensurePodcastBucket(id: key.id, title: key.title)

            let podcastBytes = Self.estimate(podcast: podcast)
            addGlobalUsage(.podcasts, bytes: podcastBytes)
            podcastBuckets[key.id]?.add(.podcasts, bytes: podcastBytes)

            for episode in podcast.episodes ?? [] {
                let episodeBytes = Self.estimate(episode: episode)
                addGlobalUsage(.episodes, bytes: episodeBytes)
                podcastBuckets[key.id]?.add(.episodes, bytes: episodeBytes)

                let fileAssociation = FileAssociation(
                    associatedEpisodeURL: episode.url,
                    episodeTitle: Self.cleanedTitle(episode.title, fallback: "Untitled Episode"),
                    podcastID: key.id,
                    podcastTitle: key.title
                )

                if let episodeURL = episode.url {
                    episodeAssociationsByEpisodeURL[episodeURL] = fileAssociation
                }
                if let localFile = episode.localFile?.standardizedFileURL {
                    episodeAssociationsByFileURL[localFile] = fileAssociation
                }

                for transcriptLine in episode.transcriptLines ?? [] {
                    let bytes = Self.estimate(transcriptLine: transcriptLine)
                    addGlobalUsage(.transcriptLines, bytes: bytes)
                    podcastBuckets[key.id]?.add(.transcriptLines, bytes: bytes)
                }

                for chapter in episode.chapters ?? [] {
                    let bytes = Self.estimate(marker: chapter)
                    addGlobalUsage(.chapters, bytes: bytes)
                    podcastBuckets[key.id]?.add(.chapters, bytes: bytes)
                }

                for bookmark in episode.bookmarks ?? [] {
                    let bytes = Self.estimate(marker: bookmark)
                    addGlobalUsage(.bookmarks, bytes: bytes)
                    podcastBuckets[key.id]?.add(.bookmarks, bytes: bytes)
                }
            }
        }

        for record in transcriptionRecords {
            let bytes = Self.estimate(transcriptionRecord: record)
            addGlobalUsage(.transcriptionRecords, bytes: bytes)

            if let episodeURL = record.episodeURL,
               let association = episodeAssociationsByEpisodeURL[episodeURL] {
                podcastBuckets[association.podcastID]?.add(.transcriptionRecords, bytes: bytes)
            } else if let title = record.podcastTitle.flatMap(Self.cleanOptionalString),
                      let podcastID = podcastTitleIndex[title] {
                podcastBuckets[podcastID]?.add(.transcriptionRecords, bytes: bytes)
            }
        }

        let playlistBytes = playlists.reduce(into: Int64(0)) { partialResult, playlist in
            partialResult += Self.estimate(playlist: playlist)
        }
        addGlobalUsage(.playlists, count: playlists.count, bytes: playlistBytes)

        for entry in playlistEntries {
            let bytes = Self.estimate(playlistEntry: entry)
            addGlobalUsage(.playlists, bytes: bytes)

            if let podcast = entry.episode?.podcast {
                let key = podcastKey(for: podcast)
                ensurePodcastBucket(id: key.id, title: key.title)
                podcastBuckets[key.id]?.add(.playlists, bytes: bytes)
            }
        }

        for session in playSessions {
            let bytes = Self.estimate(playSession: session)
            let segmentCount = session.segments?.count ?? 0
            addGlobalUsage(.listeningHistory, count: 1 + segmentCount, bytes: bytes)

            if let podcast = session.episode?.podcast {
                let key = podcastKey(for: podcast)
                ensurePodcastBucket(id: key.id, title: key.title)
                podcastBuckets[key.id]?.add(.listeningHistory, count: 1 + segmentCount, bytes: bytes)
            } else if let title = session.podcastName.flatMap(Self.cleanOptionalString),
                      let podcastID = podcastTitleIndex[title] {
                podcastBuckets[podcastID]?.add(.listeningHistory, count: 1 + segmentCount, bytes: bytes)
            }
        }

        for stat in listeningStats {
            let bytes = Self.estimate(listeningStat: stat)
            addGlobalUsage(.listeningHistory, bytes: bytes)

            if let podcastID = stat.podcastFeed?.absoluteString ?? stat.podcastName.flatMap({ podcastTitleIndex[Self.cleanedTitle($0)] }) {
                podcastBuckets[podcastID]?.add(.listeningHistory, bytes: bytes)
            }
        }

        for summary in summaries {
            let bytes = Self.estimate(summary: summary)
            addGlobalUsage(.listeningHistory, bytes: bytes)

            if let podcastID = summary.podcastFeed?.absoluteString ?? summary.podcastName.flatMap({ podcastTitleIndex[Self.cleanedTitle($0)] }) {
                podcastBuckets[podcastID]?.add(.listeningHistory, bytes: bytes)
            }
        }

        let databaseArtifacts = Self.databaseArtifacts()
        let databaseBytes = databaseArtifacts.reduce(into: Int64(0)) { partialResult, artifact in
            partialResult += artifact.size
        }

        let upNextEpisodeURLStrings = await currentUpNextEpisodeURLStrings()
        let databasePaths = Set(databaseArtifacts.map { $0.url.standardizedFileURL.path })
        let files = Self.enumerateFiles(
            excludingPaths: databasePaths,
            associationsByFileURL: episodeAssociationsByFileURL
        )
        let fileBytes = files.reduce(into: Int64(0)) { partialResult, file in
            partialResult += file.size
        }

        for file in files {
            if let podcastID = file.podcastID {
                podcastBuckets[podcastID]?.fileBytes += file.size
                podcastBuckets[podcastID]?.fileCount += 1
            }
        }

        let upNextProtectedFiles = files.filter { file in
            guard let episodeURLString = file.associatedEpisodeURL?.absoluteString else { return false }
            return upNextEpisodeURLStrings.contains(episodeURLString)
        }
        let upNextProtectedFileBytes = upNextProtectedFiles.reduce(into: Int64(0)) { partialResult, file in
            partialResult += file.size
        }

        let rawDatabaseBytes = databaseCategoryTotals.values.reduce(into: Int64(0)) { partialResult, usage in
            partialResult += usage.bytes
        }
        let scaleFactor = rawDatabaseBytes > 0 ? Double(databaseBytes) / Double(rawDatabaseBytes) : 0
        let databaseBreakdown = Self.scale(usages: databaseCategoryTotals, totalBytes: databaseBytes)

        let podcastsOutput = podcastBuckets.values
            .compactMap { accumulator -> PodcastStorageUsage? in
                let rawPodcastBytes = accumulator.rawDatabaseBytes
                let scaledPodcastBytes = rawPodcastBytes > 0
                    ? Int64((Double(rawPodcastBytes) * scaleFactor).rounded())
                    : 0
                let typeBreakdown = Self.scale(usages: accumulator.rawTypeBreakdown, totalBytes: scaledPodcastBytes)

                if scaledPodcastBytes == 0 && accumulator.fileBytes == 0 {
                    return nil
                }

                return PodcastStorageUsage(
                    id: accumulator.id,
                    podcastTitle: accumulator.title,
                    estimatedDatabaseBytes: scaledPodcastBytes,
                    fileBytes: accumulator.fileBytes,
                    fileCount: accumulator.fileCount,
                    episodeCount: accumulator.rawTypeBreakdown[.episodes]?.count ?? 0,
                    transcriptLineCount: accumulator.rawTypeBreakdown[.transcriptLines]?.count ?? 0,
                    chapterCount: accumulator.rawTypeBreakdown[.chapters]?.count ?? 0,
                    bookmarkCount: accumulator.rawTypeBreakdown[.bookmarks]?.count ?? 0,
                    transcriptionRecordCount: accumulator.rawTypeBreakdown[.transcriptionRecords]?.count ?? 0,
                    typeBreakdown: typeBreakdown
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalBytes == rhs.totalBytes {
                    return lhs.podcastTitle.localizedCaseInsensitiveCompare(rhs.podcastTitle) == .orderedAscending
                }
                return lhs.totalBytes > rhs.totalBytes
            }

        let attributedDatabaseBytes = podcastsOutput.reduce(into: Int64(0)) { partialResult, podcast in
            partialResult += podcast.estimatedDatabaseBytes
        }
        let attributedFileBytes = podcastsOutput.reduce(into: Int64(0)) { partialResult, podcast in
            partialResult += podcast.fileBytes
        }
        let attributedFileCount = podcastsOutput.reduce(into: 0) { partialResult, podcast in
            partialResult += podcast.fileCount
        }

        return StorageUsageReport(
            generatedAt: Date(),
            databaseBytes: databaseBytes,
            fileBytes: fileBytes,
            databaseArtifacts: databaseArtifacts,
            databaseBreakdown: databaseBreakdown,
            podcasts: podcastsOutput,
            files: files,
            upNextEpisodeURLStrings: upNextEpisodeURLStrings,
            upNextProtectedFileBytes: upNextProtectedFileBytes,
            upNextProtectedFileCount: upNextProtectedFiles.count,
            unattributedDatabaseBytes: max(databaseBytes - attributedDatabaseBytes, 0),
            unattributedFileBytes: max(fileBytes - attributedFileBytes, 0),
            unattributedFileCount: max(files.count - attributedFileCount, 0)
        )
    }

    func delete(file: StorageFileEntry) async {
        await delete(files: [file], clearURLCache: false)
    }

    func deleteAll(files: [StorageFileEntry], clearURLCache: Bool = true) async {
        await delete(files: files, clearURLCache: clearURLCache)
    }

    func deleteFilesOutsideUpNext() async throws -> StorageCleanupResult {
        let report = try await makeReport()
        let filesToDelete = Self.filesOutsideUpNext(in: report)
        let deletedBytes = filesToDelete.reduce(into: Int64(0)) { partialResult, file in
            partialResult += file.size
        }

        guard filesToDelete.isEmpty == false else {
            return StorageCleanupResult(
                deletedFileCount: 0,
                deletedBytes: 0,
                keptUpNextFileCount: report.upNextProtectedFileCount
            )
        }

        await delete(files: filesToDelete, clearURLCache: false)

        return StorageCleanupResult(
            deletedFileCount: filesToDelete.count,
            deletedBytes: deletedBytes,
            keptUpNextFileCount: report.upNextProtectedFileCount
        )
    }

    private func delete(files: [StorageFileEntry], clearURLCache: Bool) async {
        let episodeActor = EpisodeActor(modelContainer: modelContainer)
        let episodeURLs = Set(files.compactMap(\.associatedEpisodeURL))
        let standaloneFiles = files.filter { $0.associatedEpisodeURL == nil }

        for episodeURL in episodeURLs {
            await episodeActor.deleteFile(episodeURL: episodeURL)
        }

        for file in standaloneFiles {
            try? FileManager.default.removeItem(at: file.url)
        }

        if clearURLCache {
            URLCache.shared.removeAllCachedResponses()
        }
    }

    private func currentUpNextEpisodeURLStrings() async -> Set<String> {
        guard let playlistActor = try? PlaylistModelActor(modelContainer: modelContainer) else {
            return []
        }

        let urls = (try? await playlistActor.orderedEpisodeURLs()) ?? []
        return Set(urls.map(\.absoluteString))
    }
}

extension StorageManagementService {
    static func filesOutsideUpNext(in report: StorageUsageReport) -> [StorageFileEntry] {
        report.files.filter { file in
            guard let episodeURLString = file.associatedEpisodeURL?.absoluteString else {
                return true
            }

            return report.upNextEpisodeURLStrings.contains(episodeURLString) == false
        }
    }

    static func isProtectedByUpNext(_ file: StorageFileEntry, in report: StorageUsageReport) -> Bool {
        guard let episodeURLString = file.associatedEpisodeURL?.absoluteString else {
            return false
        }

        return report.upNextEpisodeURLStrings.contains(episodeURLString)
    }
}

private extension StorageManagementService {
    struct RawUsage {
        var count: Int = 0
        var bytes: Int64 = 0
    }

    struct PodcastAccumulator {
        let id: String
        let title: String
        var rawTypeBreakdown: [StorageDatabaseCategory: RawUsage] = [:]
        var fileBytes: Int64 = 0
        var fileCount: Int = 0

        var rawDatabaseBytes: Int64 {
            rawTypeBreakdown.values.reduce(into: Int64(0)) { partialResult, usage in
                partialResult += usage.bytes
            }
        }

        mutating func add(_ category: StorageDatabaseCategory, count: Int = 1, bytes: Int64) {
            var usage = rawTypeBreakdown[category, default: RawUsage()]
            usage.count += count
            usage.bytes += max(bytes, 0)
            rawTypeBreakdown[category] = usage
        }
    }

    struct FileAssociation {
        let associatedEpisodeURL: URL?
        let episodeTitle: String
        let podcastID: String
        let podcastTitle: String
    }

    static func databaseArtifacts() -> [StorageDatabaseArtifact] {
        guard let sharedContainerURL = ModelContainerManager.sharedContainerURL else {
            return []
        }

        let storeFileName = ModelContainerManager.sharedStoreURL?.lastPathComponent ?? "SharedDatabase.sqlite"
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: sharedContainerURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )) ?? []

        return urls.compactMap { url in
            guard url.lastPathComponent.hasPrefix(storeFileName) else { return nil }
            let values = try? url.resourceValues(forKeys: resourceKeys)
            guard values?.isRegularFile == true else { return nil }

            return StorageDatabaseArtifact(
                url: url.standardizedFileURL,
                name: url.lastPathComponent,
                size: fileSize(for: values)
            )
        }
        .sorted { lhs, rhs in
            if lhs.size == rhs.size {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.size > rhs.size
        }
    }

    static func enumerateFiles(
        excludingPaths: Set<String>,
        associationsByFileURL: [URL: FileAssociation]
    ) -> [StorageFileEntry] {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]

        let files = StorageFileRoot.allCases.flatMap { root -> [StorageFileEntry] in
            guard let baseURL = root.baseURL else { return [] }

            let enumerator = FileManager.default.enumerator(
                at: baseURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsPackageDescendants]
            )

            var entries: [StorageFileEntry] = []
            while let url = enumerator?.nextObject() as? URL {
                let standardizedURL = url.standardizedFileURL
                if excludingPaths.contains(standardizedURL.path) {
                    continue
                }

                let values = try? standardizedURL.resourceValues(forKeys: resourceKeys)
                guard values?.isRegularFile == true else {
                    continue
                }

                let association = associationsByFileURL[standardizedURL]
                entries.append(
                    StorageFileEntry(
                        url: standardizedURL,
                        root: root,
                        relativePath: relativePath(for: standardizedURL, baseURL: baseURL),
                        size: fileSize(for: values),
                        associatedEpisodeURL: association?.associatedEpisodeURL,
                        episodeTitle: association?.episodeTitle,
                        podcastID: association?.podcastID,
                        podcastTitle: association?.podcastTitle
                    )
                )
            }

            return entries
        }

        return files.sorted { lhs, rhs in
            if lhs.root == rhs.root {
                if lhs.size == rhs.size {
                    return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
                }
                return lhs.size > rhs.size
            }
            return lhs.root.rawValue < rhs.root.rawValue
        }
    }

    static func scale(
        usages: [StorageDatabaseCategory: RawUsage],
        totalBytes: Int64
    ) -> [StorageTypeUsage] {
        let relevant = usages.filter { $0.value.bytes > 0 || $0.value.count > 0 }
        guard relevant.isEmpty == false else { return [] }

        let rawTotal = relevant.values.reduce(into: Int64(0)) { partialResult, usage in
            partialResult += usage.bytes
        }

        guard totalBytes > 0, rawTotal > 0 else {
            return relevant.map { category, usage in
                StorageTypeUsage(category: category, count: usage.count, bytes: usage.bytes)
            }
            .sorted(by: compareStorageUsage)
        }

        var scaled = relevant.map { category, usage in
            StorageTypeUsage(
                category: category,
                count: usage.count,
                bytes: Int64((Double(usage.bytes) / Double(rawTotal) * Double(totalBytes)).rounded())
            )
        }

        let currentTotal = scaled.reduce(into: Int64(0)) { partialResult, usage in
            partialResult += usage.bytes
        }
        let delta = totalBytes - currentTotal

        if delta != 0, let index = scaled.indices.max(by: { scaled[$0].bytes < scaled[$1].bytes }) {
            let adjustedBytes = max(scaled[index].bytes + delta, 0)
            scaled[index] = StorageTypeUsage(
                category: scaled[index].category,
                count: scaled[index].count,
                bytes: adjustedBytes
            )
        }

        return scaled.sorted(by: compareStorageUsage)
    }

    static func compareStorageUsage(_ lhs: StorageTypeUsage, _ rhs: StorageTypeUsage) -> Bool {
        if lhs.bytes == rhs.bytes {
            return lhs.category.title.localizedCaseInsensitiveCompare(rhs.category.title) == .orderedAscending
        }
        return lhs.bytes > rhs.bytes
    }

    static func fileSize(for values: URLResourceValues?) -> Int64 {
        Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
    }

    static func relativePath(for url: URL, baseURL: URL) -> String {
        let standardizedBase = baseURL.standardizedFileURL.path
        let standardizedPath = url.standardizedFileURL.path
        let prefix = standardizedBase.hasSuffix("/") ? standardizedBase : standardizedBase + "/"

        if standardizedPath.hasPrefix(prefix) {
            return String(standardizedPath.dropFirst(prefix.count))
        }

        return url.lastPathComponent
    }

    static func cleanedTitle(_ title: String, fallback: String = "Untitled") -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func cleanOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func estimate(podcast: Podcast) -> Int64 {
        var bytes: Int64 = 256
        bytes += estimate(string: podcast.title)
        bytes += estimate(string: podcast.desc)
        bytes += estimate(string: podcast.author)
        bytes += estimate(url: podcast.feed)
        bytes += estimate(url: podcast.link)
        bytes += estimate(string: podcast.language)
        bytes += estimate(string: podcast.copyright)
        bytes += estimate(url: podcast.imageURL)
        bytes += estimate(date: podcast.lastBuildDate)
        bytes += estimate(funding: podcast.funding)
        bytes += estimate(social: podcast.social)
        bytes += estimate(people: podcast.people)

        if let metaData = podcast.metaData {
            bytes += 96
            bytes += estimate(date: metaData.lastRefresh)
            bytes += estimate(bool: metaData.feedUpdated)
            bytes += estimate(date: metaData.feedUpdateCheckDate)
            bytes += estimate(date: metaData.subscriptionDate)
            bytes += estimate(bool: metaData.isSubscribed)
        }

        if let settings = podcast.settings {
            bytes += 192
            bytes += estimate(string: settings.title)
            bytes += estimate(bool: settings.isEnabled)
            bytes += estimate(bool: settings.autoDownload)
            bytes += estimate(string: String(describing: settings.playnextPosition))
            bytes += estimate(float: settings.playbackSpeed)
            bytes += estimate(skipKeys: settings.autoSkipKeywords)
            bytes += estimate(float: settings.cutFront)
            bytes += estimate(float: settings.cutEnd)
            bytes += estimate(int: settings.skipForward.rawValue)
            bytes += estimate(int: settings.skipBack.rawValue)
            bytes += estimate(bool: settings.markAsPlayedAfterSubscribe)
            bytes += estimate(bool: settings.playSumAdjustedbyPlayspeed)
            bytes += estimate(bool: settings.enableLockscreenSlider)
            bytes += estimate(bool: settings.enableInAppSlider)
            bytes += estimate(bool: settings.getContinuousPlay)
            bytes += estimate(double: settings.sleepTimerAddMinutes)
            bytes += estimate(double: settings.sleepTimerDurationToReactivate)
            bytes += estimate(bool: settings.sleepTimerVoiceFeedbackEnabled)
            bytes += estimate(string: settings.sleepTimerText)
            bytes += estimate(string: settings.sleepTimerVoice)
            bytes += estimate(dictionary: settings.voices)
        }

        return bytes
    }

    static func estimate(episode: Episode) -> Int64 {
        var bytes: Int64 = 384
        bytes += estimate(string: episode.guid)
        bytes += estimate(string: episode.title)
        bytes += estimate(string: episode.author)
        bytes += estimate(string: episode.desc)
        bytes += estimate(string: episode.subtitle)
        bytes += estimate(string: episode.content)
        bytes += estimate(date: episode.publishDate)
        bytes += estimate(url: episode.url)
        bytes += estimate(urls: episode.deeplinks)
        bytes += estimate(int64: episode.fileSize)
        bytes += estimate(url: episode.link)
        bytes += estimate(url: episode.imageURL)
        bytes += estimate(double: episode.duration)
        bytes += estimate(string: episode.number)
        bytes += estimate(string: episode.type?.rawValue)
        bytes += estimate(externalFiles: episode.externalFiles)
        bytes += estimate(funding: episode.funding)
        bytes += estimate(social: episode.social)
        bytes += estimate(people: episode.people)

        if let metaData = episode.metaData {
            bytes += estimate(metaData: metaData)
        }

        return bytes
    }

    static func estimate(metaData: EpisodeMetaData) -> Int64 {
        var bytes: Int64 = 160
        bytes += estimate(bool: metaData.isAvailableLocally)
        bytes += estimate(date: metaData.lastPlayed)
        bytes += estimate(double: metaData.maxPlayposition)
        bytes += estimate(double: metaData.playPosition)
        bytes += estimate(bool: metaData.isArchived)
        bytes += estimate(bool: metaData.isHistory)
        bytes += estimate(bool: metaData.isInbox)
        bytes += estimate(string: metaData.status?.rawValue)
        bytes += estimate(date: metaData.completionDate)
        bytes += estimate(dates: metaData.playbackStartTimes?.elements)
        bytes += estimate(doubles: metaData.playbackDurations?.elements)
        bytes += estimate(double: metaData.totalListenTime)
        bytes += estimate(doubles: metaData.playbackSpeeds?.elements)
        bytes += estimate(date: metaData.firstListenDate)
        bytes += estimate(bool: metaData.wasSkipped)
        return bytes
    }

    static func estimate(transcriptLine: TranscriptLineAndTime) -> Int64 {
        var bytes: Int64 = 64
        bytes += estimate(uuid: transcriptLine.id)
        bytes += estimate(string: transcriptLine.speaker)
        bytes += estimate(string: transcriptLine.text)
        bytes += estimate(double: transcriptLine.startTime)
        bytes += estimate(double: transcriptLine.endTime)
        return bytes
    }

    static func estimate(marker: Marker) -> Int64 {
        var bytes: Int64 = 128
        bytes += estimate(uuid: marker.uuid)
        bytes += estimate(string: marker.title)
        bytes += estimate(url: marker.link)
        bytes += estimate(url: marker.image)
        bytes += estimate(data: marker.imageData)
        bytes += estimate(double: marker.start)
        bytes += estimate(double: marker.endTime)
        bytes += estimate(double: marker.duration)
        bytes += estimate(date: marker.creationtime)
        bytes += estimate(double: marker.progress)
        bytes += estimate(string: marker.type.rawValue)
        bytes += estimate(bool: marker.shouldPlay)
        return bytes
    }

    static func estimate(transcriptionRecord: TranscriptionRecord) -> Int64 {
        var bytes: Int64 = 96
        bytes += estimate(uuid: transcriptionRecord.id)
        bytes += estimate(url: transcriptionRecord.episodeURL)
        bytes += estimate(string: transcriptionRecord.episodeTitle)
        bytes += estimate(string: transcriptionRecord.podcastTitle)
        bytes += estimate(string: transcriptionRecord.localeIdentifier)
        bytes += estimate(date: transcriptionRecord.startedAt)
        bytes += estimate(date: transcriptionRecord.finishedAt)
        bytes += estimate(double: transcriptionRecord.audioDuration)
        bytes += estimate(double: transcriptionRecord.transcriptionDuration)
        return bytes
    }

    static func estimate(playSession: PlaySession) -> Int64 {
        var bytes: Int64 = 144
        bytes += estimate(uuid: playSession.id)
        bytes += estimate(string: playSession.podcastName)
        bytes += estimate(string: playSession.deviceModel)
        bytes += estimate(string: playSession.osVersion)
        bytes += estimate(string: playSession.appVersion)
        bytes += estimate(date: playSession.startTime)
        bytes += estimate(date: playSession.endTime)
        bytes += estimate(double: playSession.startPosition)
        bytes += estimate(double: playSession.endPosition)
        bytes += estimate(bool: playSession.endedCleanly)

        for segment in playSession.segments ?? [] {
            bytes += 72
            bytes += estimate(uuid: segment.id)
            bytes += estimate(float: segment.rate)
            bytes += estimate(date: segment.startTime)
            bytes += estimate(double: segment.startPosition)
            bytes += estimate(date: segment.endTime)
            bytes += estimate(double: segment.endPosition)
        }

        return bytes
    }

    static func estimate(listeningStat: ListeningStat) -> Int64 {
        var bytes: Int64 = 72
        bytes += estimate(uuid: listeningStat.id)
        bytes += estimate(date: listeningStat.startOfHour)
        bytes += estimate(url: listeningStat.podcastFeed)
        bytes += estimate(string: listeningStat.podcastName)
        bytes += estimate(double: listeningStat.totalSeconds)
        return bytes
    }

    static func estimate(summary: PlaySessionSummary) -> Int64 {
        var bytes: Int64 = 80
        bytes += estimate(uuid: summary.id)
        bytes += estimate(string: summary.periodKind)
        bytes += estimate(date: summary.periodStart)
        bytes += estimate(url: summary.podcastFeed)
        bytes += estimate(string: summary.podcastName)
        bytes += estimate(double: summary.totalSeconds)
        bytes += estimate(int: summary.activeHourCount)
        return bytes
    }

    static func estimate(playlist: Playlist) -> Int64 {
        var bytes: Int64 = 96
        bytes += estimate(string: playlist.title)
        bytes += estimate(uuid: playlist.id)
        bytes += estimate(bool: playlist.deleteable)
        bytes += estimate(bool: playlist.hidden)
        return bytes
    }

    static func estimate(playlistEntry: PlaylistEntry) -> Int64 {
        var bytes: Int64 = 72
        bytes += estimate(uuid: playlistEntry.id)
        bytes += estimate(date: playlistEntry.dateAdded)
        bytes += estimate(int: playlistEntry.order)
        return bytes
    }

    static func estimate(funding: [FundingInfo]) -> Int64 {
        funding.reduce(into: Int64(0)) { partialResult, funding in
            partialResult += 48
            partialResult += estimate(uuid: funding.id)
            partialResult += estimate(url: funding.url)
            partialResult += estimate(string: funding.label)
        }
    }

    static func estimate(social: [SocialInfo]) -> Int64 {
        social.reduce(into: Int64(0)) { partialResult, social in
            partialResult += 64
            partialResult += estimate(uuid: social.id)
            partialResult += estimate(url: social.url)
            partialResult += estimate(string: social.socialprotocol)
            partialResult += estimate(string: social.accountId)
            partialResult += estimate(url: social.accountURL)
            partialResult += estimate(int: social.priority)
        }
    }

    static func estimate(people: [PersonInfo]) -> Int64 {
        people.reduce(into: Int64(0)) { partialResult, person in
            partialResult += 64
            partialResult += estimate(uuid: person.id)
            partialResult += estimate(string: person.name)
            partialResult += estimate(string: person.role)
            partialResult += estimate(url: person.href)
            partialResult += estimate(url: person.img)
        }
    }

    static func estimate(skipKeys: [skipKey]) -> Int64 {
        skipKeys.reduce(into: Int64(0)) { partialResult, key in
            partialResult += 32
            partialResult += estimate(string: key.keyWord)
            partialResult += estimate(string: String(describing: key.keyOperator))
        }
    }

    static func estimate(externalFiles: [ExternalFile]) -> Int64 {
        externalFiles.reduce(into: Int64(0)) { partialResult, file in
            partialResult += 40
            partialResult += estimate(string: file.url)
            partialResult += estimate(string: file.category?.rawValue)
            partialResult += estimate(string: file.source)
            partialResult += estimate(string: file.fileType)
        }
    }

    static func estimate(dictionary: [String: [String: String]]?) -> Int64 {
        guard let dictionary else { return 0 }

        return dictionary.reduce(into: Int64(0)) { partialResult, pair in
            partialResult += 24
            partialResult += estimate(string: pair.key)
            partialResult += pair.value.reduce(into: Int64(0)) { nestedResult, nestedPair in
                nestedResult += 16
                nestedResult += estimate(string: nestedPair.key)
                nestedResult += estimate(string: nestedPair.value)
            }
        }
    }

    static func estimate(urls: [URL]?) -> Int64 {
        (urls ?? []).reduce(into: Int64(0)) { partialResult, url in
            partialResult += 16
            partialResult += estimate(url: url)
        }
    }

    static func estimate(dates: [Date]?) -> Int64 {
        Int64((dates ?? []).count) * 8
    }

    static func estimate(doubles: [Double]?) -> Int64 {
        Int64((doubles ?? []).count) * 8
    }

    static func estimate(string: String?) -> Int64 {
        Int64(cleanOptionalString(string)?.utf8.count ?? 0)
    }

    static func estimate(url: URL?) -> Int64 {
        Int64(url?.absoluteString.utf8.count ?? 0)
    }

    static func estimate(data: Data?) -> Int64 {
        Int64(data?.count ?? 0)
    }

    static func estimate(date: Date?) -> Int64 {
        date == nil ? 0 : 8
    }

    static func estimate(double: Double?) -> Int64 {
        double == nil ? 0 : 8
    }

    static func estimate(float: Float?) -> Int64 {
        float == nil ? 0 : 4
    }

    static func estimate(int: Int?) -> Int64 {
        int == nil ? 0 : Int64(MemoryLayout<Int>.size)
    }

    static func estimate(int64: Int64?) -> Int64 {
        int64 == nil ? 0 : 8
    }

    static func estimate(bool: Bool?) -> Int64 {
        bool == nil ? 0 : 1
    }

    static func estimate(uuid: UUID?) -> Int64 {
        uuid == nil ? 0 : 16
    }
}
