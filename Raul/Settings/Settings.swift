//
//  Settings.swift
//  Raul
//
//  Created by Holger Krupp on 29.06.25.
//


import Foundation
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

extension Notification.Name {
    static let podcastSettingsDidChange = Notification.Name("podcastSettingsDidChange")
}


@Model
class PodcastSettings {
    
    var id = UUID()
    var title:String?
    var isEnabled:Bool = true
    
    var autoDownload:Bool = false
    var autoDownloadEpisodeCount: Int = 3
    var autoDownloadSelectionRawValue: String? = AutoDownloadSelection.newestUnplayed.rawValue
    var autoDownloadNetworkModeRawValue: String? = AutoDownloadNetworkMode.wifiAndCellular.rawValue
    var playnextPosition:Playlist.Position = Playlist.Position.none
    var playbackSpeed:Float? = 1.0
    var autoSkipKeywords:[skipKey] = [] // to create a function to skip chapters with specific keywords
    var cutFront:Float? // how much to cut from the front / Intro
    var cutEnd:Float? // how much to cut from the end / Outro
    
    var skipForward:SkipSteps = SkipSteps.thirty
    var skipBack: SkipSteps = SkipSteps.fifteen

    /// Number of days archived episode files should be kept locally before cleanup may delete them.
    var archiveFileRetentionDays: Int = 7
    
    
    // Secret Settings that should only be applied on global way:
    var markAsPlayedAfterSubscribe: Bool = true
    var playSumAdjustedbyPlayspeed: Bool = false
    var enableLockscreenSlider:Bool = true
    var enableInAppSlider:Bool = true
    var getContinuousPlay:Bool = true
    var enableAutomaticOnDeviceTranscriptions: Bool = true
    var limitAutomaticOnDeviceTranscriptionsToCharging: Bool = false
    /// Upper limit for each generated transcript snippet to improve playback alignment.
    var transcriptionMaxSnippetDurationSeconds: Double = 1.2

    var sleepTimerAddMinutes: Double = 10 // 10 minutes
    var sleepTimerDurationToReactivate: Double = 300 // 5 minutes * 60 seconds
    var sleepTimerVoiceFeedbackEnabled: Bool = true
    var sleepTimerText: String = "Sleep Timer extended"
    var sleepTimerVoice: String = "com.apple.speech.voice.Alex"
    
    var voices: [String:[String:String]]?
    
    @Relationship var podcast:Podcast?
    
    
    
    init(){}
    
    init(podcast: Podcast){
        title = podcast.title
        self.podcast = podcast
        // print("INIT SETTINGS WITH: \(podcast.title) - \(podcast.id)")
    }
    
    init(defaultSettings: Bool){
        if defaultSettings{
            self.title = "de.holgerkrupp.podbay.queue"
        }
    }

    var autoDownloadSelection: AutoDownloadSelection {
        get {
            AutoDownloadSelection(rawValue: autoDownloadSelectionRawValue ?? "") ?? .newestUnplayed
        }
        set {
            autoDownloadSelectionRawValue = newValue.rawValue
        }
    }

    var autoDownloadNetworkMode: AutoDownloadNetworkMode {
        get {
            AutoDownloadNetworkMode(rawValue: autoDownloadNetworkModeRawValue ?? "") ?? .wifiAndCellular
        }
        set {
            autoDownloadNetworkModeRawValue = newValue.rawValue
        }
    }
}

enum AutoDownloadSelection: String, Codable, CaseIterable, Hashable, Sendable {
    case newestUnplayed
    case oldestUnplayed
}

enum AutoDownloadNetworkMode: String, Codable, CaseIterable, Hashable, Sendable {
    case wifiAndCellular
    case wifiOnly
}

enum Operator: Codable, CaseIterable, Hashable {
    case Is, Contains, StartsWith, EndsWith
}

struct skipKey:Codable, Sendable{
    
    var keyWord:String?
    var keyOperator:Operator = .Contains
}

enum SkipSteps:Int, Codable, CaseIterable{
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30
    case fortyfive = 45
    case sixty = 60
    case seventyfive = 75
    case ninety = 90
    
    var float:Float {
        return Float(rawValue)
    }
    
    var backString:String{
        return "gobackward.".appending(rawValue.description)
    }
    
    var forwardString:String{
        return "goforward.".appending(rawValue.description)
    }
}

extension Notification.Name {
    static let sideLoadedDidChange = Notification.Name("sideLoadedDidChange")
}

enum SideloadingConfiguration {
    static let enabledKey = "SideloadingEnabled"
    static let refreshDebounceNanoseconds: UInt64 = 250_000_000
    static let missingArchiveGracePeriod: TimeInterval = 15 * 60
    static let missingStateDefaultsKey = "SideloadingMissingEpisodes.v1"
    static let visibilityMarkerFileName = ".upnext-sideloading-marker"

    static let supportedExtensions: Set<String> = [
        "aac",
        "aif",
        "aiff",
        "caf",
        "m4a",
        "m4b",
        "m4p",
        "m4r",
        "mp3",
        "mp4",
        "wav"
    ]
}

enum SideloadingError: LocalizedError {
    case iCloudUnavailable
    case containerUnavailable
    case folderCreationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud Drive is not available on this device."
        case .containerUnavailable:
            return "The app's iCloud Drive container root could not be located. Make sure iCloud Drive is enabled and the app is signed for iCloud Documents."
        case .folderCreationFailed(let url):
            return "The app's iCloud Drive container could not be prepared at \(url.path)."
        }
    }
}

struct SideLoadedAudioMetadata: Sendable {
    let title: String
    let author: String?
    let subtitle: String?
    let description: String?
    let publishDate: Date?
    let duration: Double?
    let fileSize: Int64?
}

private struct CollectedSideLoadedFiles {
    let presentFileURLs: [URL]
    let availableFileURLs: [URL]
    let notDownloadedFileURLs: [URL]
}

private struct SideLoadedMissingEpisodeState: Codable {
    var missingSinceByURL: [String: TimeInterval] = [:]

    mutating func clear(for url: URL) -> Bool {
        missingSinceByURL.removeValue(forKey: Self.normalizedKey(for: url)) != nil
    }

    mutating func markMissing(for url: URL, at date: Date) -> Bool {
        let key = Self.normalizedKey(for: url)
        guard missingSinceByURL[key] == nil else {
            return false
        }

        missingSinceByURL[key] = date.timeIntervalSince1970
        return true
    }

    func missingSince(for url: URL) -> Date? {
        missingSinceByURL[Self.normalizedKey(for: url)].map(Date.init(timeIntervalSince1970:))
    }

    static func load(defaults: UserDefaults = .standard) -> SideLoadedMissingEpisodeState {
        guard let data = defaults.data(forKey: SideloadingConfiguration.missingStateDefaultsKey) else {
            return SideLoadedMissingEpisodeState()
        }

        return (try? JSONDecoder().decode(SideLoadedMissingEpisodeState.self, from: data)) ?? SideLoadedMissingEpisodeState()
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: SideloadingConfiguration.missingStateDefaultsKey)
    }

    private static func normalizedKey(for url: URL) -> String {
        url.standardizedFileURL.absoluteString
    }
}

final class SideloadingFolderPresenter: NSObject, NSFilePresenter {
    private let folderURL: URL
    private let operationQueue: OperationQueue
    private let onChange: @Sendable () -> Void

    init(folderURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.folderURL = folderURL.standardizedFileURL
        self.onChange = onChange
        let queue = OperationQueue()
        queue.name = "SideloadingFolderPresenter"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        self.operationQueue = queue
    }

    var presentedItemURL: URL? {
        folderURL
    }

    var presentedItemOperationQueue: OperationQueue {
        operationQueue
    }

    func presentedItemDidChange() {
        onChange()
    }

    func presentedItemDidMove(to newURL: URL) {
        onChange()
    }

    func presentedSubitemDidAppear(at url: URL) {
        onChange()
    }

    func presentedSubitemDidChange(at url: URL) {
        onChange()
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        onChange()
    }

    func presentedSubitemDidDisappear(at url: URL) {
        onChange()
    }

    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        onChange()
        completionHandler(nil)
    }
}

@MainActor
final class SideloadingCoordinator: NSObject {
    static let shared = SideloadingCoordinator()

    private let fileManager = FileManager.default
    private var refreshTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var refreshQueuedWhileRunning = false
    private var pendingDownloadRequests: Set<URL> = []
    private var folderPresenter: SideloadingFolderPresenter?

    private(set) var folderURL: URL?
    private(set) var isRunning = false
    private(set) var isMonitoring = false

    func syncEnabledState(_ enabled: Bool) async throws {
        if enabled {
            try await enable()
        } else {
            disable()
        }
    }

    func enable() async throws {
        if isRunning {
            return
        }

        let folderURL = try await resolveFolderURL()
        try createFolderIfNeeded(at: folderURL)
        try createVisibilityMarkerIfNeeded(at: folderURL)
        self.folderURL = folderURL
        isRunning = true
        clearMissingState()
    }

    func disable() {
        pendingDownloadRequests.removeAll()
        clearMissingState()
        folderURL = nil
        isRunning = false
    }

    func refreshNow() async {
        await refreshFromFolder()
    }

    func resumeMonitoringIfEnabled() {
        guard isRunning, let folderURL else { return }

        if folderPresenter == nil {
            let presenter = SideloadingFolderPresenter(folderURL: folderURL) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleRefresh()
                }
            }

            folderPresenter = presenter
            NSFileCoordinator.addFilePresenter(presenter)
            isMonitoring = true
        }

        scheduleRefresh(immediate: true)
    }

    func pauseMonitoring() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshInFlight = false
        refreshQueuedWhileRunning = false

        if let presenter = folderPresenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            folderPresenter = nil
        }

        isMonitoring = false
    }

    private func resolveFolderURL() async throws -> URL {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default

            guard fileManager.ubiquityIdentityToken != nil else {
                throw SideloadingError.iCloudUnavailable
            }

            guard let containerURL = fileManager.url(forUbiquityContainerIdentifier: nil) else {
                throw SideloadingError.containerUnavailable
            }

            return containerURL
        }.value
    }

    private func createFolderIfNeeded(at folderURL: URL) throws {
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            throw SideloadingError.folderCreationFailed(folderURL)
        }
    }

    private func createVisibilityMarkerIfNeeded(at folderURL: URL) throws {
        // iCloud Drive can keep a public container hidden until it contains at least one file.
        let markerURL = folderURL.appendingPathComponent(SideloadingConfiguration.visibilityMarkerFileName)
        guard fileManager.fileExists(atPath: markerURL.path) == false else { return }

        let created = fileManager.createFile(
            atPath: markerURL.path,
            contents: Data("Up Next sideloading enabled.\n".utf8),
            attributes: nil
        )

        if created == false {
            throw SideloadingError.folderCreationFailed(folderURL)
        }
    }

    private func scheduleRefresh(immediate: Bool = false) {
        guard isRunning else { return }
        guard refreshInFlight == false else {
            refreshQueuedWhileRunning = true
            return
        }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if immediate == false {
                try? await Task.sleep(nanoseconds: SideloadingConfiguration.refreshDebounceNanoseconds)
            }
            await self?.refreshFromFolder()
        }
    }

    private func refreshFromFolder() async {
        guard refreshInFlight == false else {
            refreshQueuedWhileRunning = true
            return
        }

        refreshInFlight = true
        refreshTask = nil
        defer {
            refreshInFlight = false
            if refreshQueuedWhileRunning {
                refreshQueuedWhileRunning = false
                scheduleRefresh()
            }
        }

        guard isRunning,
              let folderURL else {
            return
        }

        let collected = await collectedFileURLs(from: folderURL)
        for fileURL in collected.notDownloadedFileURLs {
            requestDownloadIfNeeded(for: fileURL)
        }

        pendingDownloadRequests.formIntersection(Set(collected.notDownloadedFileURLs.map(\.standardizedFileURL)))

        let didChange = await SideLoadedLibraryActor(modelContainer: ModelContainerManager.shared.container)
            .reconcile(
                presentFileURLs: collected.presentFileURLs,
                availableFileURLs: collected.availableFileURLs
            )

        if didChange {
            NotificationCenter.default.post(name: .sideLoadedDidChange, object: nil)
            WatchSyncCoordinator.refreshSoon()
        }
    }

    private func collectedFileURLs(from folderURL: URL) async -> CollectedSideLoadedFiles {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let standardizedFolderURL = folderURL.standardizedFileURL
            let folderPath = standardizedFolderURL.path.hasSuffix("/")
                ? standardizedFolderURL.path
                : standardizedFolderURL.path + "/"

            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .isDirectoryKey,
                .ubiquitousItemDownloadingStatusKey
            ]

            var presentFileURLs: [URL] = []
            var availableFileURLs: [URL] = []
            var notDownloadedFileURLs: [URL] = []

            if let enumerator = fileManager.enumerator(
                at: standardizedFolderURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                while let url = enumerator.nextObject() as? URL {
                    let standardizedURL = url.standardizedFileURL
                    guard standardizedURL.path.hasPrefix(folderPath) else { continue }
                    guard isSupportedAudioFile(standardizedURL) else { continue }
                    presentFileURLs.append(standardizedURL)

                    if let status = try? standardizedURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
                       status == .notDownloaded {
                        notDownloadedFileURLs.append(standardizedURL)
                        continue
                    }

                    availableFileURLs.append(standardizedURL)
                }
            }

            let present = Array(Set(presentFileURLs)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let available = Array(Set(availableFileURLs)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let notDownloaded = Array(Set(notDownloadedFileURLs)).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return CollectedSideLoadedFiles(
                presentFileURLs: present,
                availableFileURLs: available,
                notDownloadedFileURLs: notDownloaded
            )
        }.value
    }

    private func requestDownloadIfNeeded(for fileURL: URL) {
        let standardizedURL = fileURL.standardizedFileURL
        guard pendingDownloadRequests.insert(standardizedURL).inserted else { return }

        do {
            try fileManager.startDownloadingUbiquitousItem(at: standardizedURL)
        } catch {
            pendingDownloadRequests.remove(standardizedURL)
        }
    }

    private func clearMissingState() {
        UserDefaults.standard.removeObject(forKey: SideloadingConfiguration.missingStateDefaultsKey)
    }
}

private func isSupportedAudioFile(_ url: URL) -> Bool {
    let extensionName = url.pathExtension.lowercased()
    guard extensionName.isEmpty == false else { return false }
    if SideloadingConfiguration.supportedExtensions.contains(extensionName) {
        return true
    }

    return UTType(filenameExtension: extensionName)?.conforms(to: .audio) == true
}

@ModelActor
actor SideLoadedLibraryActor {
    lazy var episodeActor: EpisodeActor = EpisodeActor(modelContainer: self.modelContainer)

    func reconcile(presentFileURLs: [URL], availableFileURLs: [URL]) async -> Bool {
        let presentURLs = Set(presentFileURLs.map { $0.standardizedFileURL })
        let activeURLs = Set(availableFileURLs.map { $0.standardizedFileURL })
        let now = Date()
        let gracePeriod = SideloadingConfiguration.missingArchiveGracePeriod
        var missingState = SideLoadedMissingEpisodeState.load()

        let allEpisodes = (try? modelContext.fetch(FetchDescriptor<Episode>())) ?? []
        let sideLoadedEpisodes = allEpisodes.filter { $0.source == EpisodeSource.sideLoaded }
        let episodesByURL: [URL: Episode] = Dictionary(
            sideLoadedEpisodes.compactMap { episode in
                guard let url = episode.url?.standardizedFileURL else { return nil }
                return (url, episode)
            },
            uniquingKeysWith: { existing, _ in existing }
        )

        var didChange = false
        var missingStateDidChange = false

        for episode in sideLoadedEpisodes {
            guard let episodeURL = episode.url?.standardizedFileURL else { continue }
            if presentURLs.contains(episodeURL) {
                missingStateDidChange = missingState.clear(for: episodeURL) || missingStateDidChange
                continue
            }

            if FileManager.default.fileExists(atPath: episodeURL.path) {
                missingStateDidChange = missingState.clear(for: episodeURL) || missingStateDidChange
                continue
            }

            missingStateDidChange = missingState.markMissing(for: episodeURL, at: now) || missingStateDidChange
            guard let missingSince = missingState.missingSince(for: episodeURL) else { continue }
            guard now.timeIntervalSince(missingSince) >= gracePeriod else { continue }
            guard episode.metaData?.isArchived != true else { continue }

            await episodeActor.archiveEpisode(episode.url)
            didChange = true
            missingStateDidChange = missingState.clear(for: episodeURL) || missingStateDidChange
        }

        for fileURL in presentURLs {
            guard let existingEpisode = episodesByURL[fileURL] else {
                let metadata = await loadMetadata(for: fileURL, canLoadMediaMetadata: activeURLs.contains(fileURL))
                let isAvailableLocally = activeURLs.contains(fileURL)
                let episode = Episode(
                    sideLoadedURL: fileURL,
                    title: metadata.title,
                    publishDate: metadata.publishDate,
                    duration: metadata.duration,
                    author: metadata.author
                )
                episode.subtitle = metadata.subtitle
                episode.desc = metadata.description
                episode.fileSize = metadata.fileSize
                episode.metaData?.isInbox = true
                episode.metaData?.isArchived = false
                episode.metaData?.status = .inbox
                episode.metaData?.isAvailableLocally = isAvailableLocally
                modelContext.insert(episode)
                modelContext.saveIfNeeded()
                if isAvailableLocally {
                    await episodeActor.markEpisodeAvailable(fileURL: fileURL)
                }
                didChange = true
                continue
            }

            let isAvailableLocally = activeURLs.contains(fileURL)
            guard existingEpisode.metaData?.isArchived != true else {
                if existingEpisode.metaData?.isAvailableLocally != isAvailableLocally {
                    existingEpisode.metaData?.isAvailableLocally = isAvailableLocally
                    modelContext.saveIfNeeded()
                    didChange = true
                }

                if isAvailableLocally {
                    await episodeActor.markEpisodeAvailable(fileURL: fileURL)
                    didChange = true
                }
                continue
            }

            let metadata = await loadMetadata(for: fileURL, canLoadMediaMetadata: isAvailableLocally)
            var episodeDidChange = false

            if existingEpisode.title != metadata.title {
                existingEpisode.title = metadata.title
                episodeDidChange = true
            }

            if existingEpisode.author != metadata.author {
                existingEpisode.author = metadata.author
                episodeDidChange = true
            }

            if existingEpisode.subtitle != metadata.subtitle {
                existingEpisode.subtitle = metadata.subtitle
                episodeDidChange = true
            }

            if existingEpisode.desc != metadata.description {
                existingEpisode.desc = metadata.description
                episodeDidChange = true
            }

            if existingEpisode.publishDate != metadata.publishDate {
                existingEpisode.publishDate = metadata.publishDate
                episodeDidChange = true
            }

            if existingEpisode.fileSize != metadata.fileSize {
                existingEpisode.fileSize = metadata.fileSize
                episodeDidChange = true
            }

            if existingEpisode.guid != fileURL.absoluteString {
                existingEpisode.guid = fileURL.absoluteString
                episodeDidChange = true
            }

            if existingEpisode.source != EpisodeSource.sideLoaded {
                existingEpisode.source = EpisodeSource.sideLoaded
                episodeDidChange = true
            }

            if existingEpisode.podcast != nil {
                existingEpisode.podcast = nil
                episodeDidChange = true
            }

            if existingEpisode.url?.standardizedFileURL != fileURL {
                existingEpisode.url = fileURL
                episodeDidChange = true
            }

            if episodeDidChange {
                modelContext.saveIfNeeded()
                didChange = true
            }

            if existingEpisode.metaData?.isAvailableLocally != isAvailableLocally {
                existingEpisode.metaData?.isAvailableLocally = isAvailableLocally
                episodeDidChange = true
            }

            if isAvailableLocally {
                await episodeActor.markEpisodeAvailable(fileURL: fileURL)
                didChange = true
            } else if episodeDidChange {
                modelContext.saveIfNeeded()
            }
        }

        if didChange {
            await MainActor.run {
                NotificationCenter.default.post(name: .inboxDidChange, object: nil)
            }
        }

        if missingStateDidChange {
            missingState.save()
        }

        return didChange
    }

    private func loadMetadata(for fileURL: URL, canLoadMediaMetadata: Bool) async -> SideLoadedAudioMetadata {
        let fallbackTitle = Self.fallbackTitle(for: fileURL)
        let resourceValues = try? fileURL.resourceValues(forKeys: [
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey
        ])

        let metadataItems: [AVMetadataItem]
        let duration: Double?
        if canLoadMediaMetadata {
            let asset = AVURLAsset(url: fileURL)
            metadataItems = (try? await asset.load(.metadata)) ?? []
            duration = (try? await asset.load(.duration)).flatMap { time -> Double? in
                let seconds = CMTimeGetSeconds(time)
                guard seconds.isFinite, seconds > 0 else { return nil }
                return seconds
            }
        } else {
            metadataItems = []
            duration = nil
        }

        func firstString(for keys: [AVMetadataKey]) async -> String? {
            guard metadataItems.isEmpty == false else { return nil }

            for key in keys {
                guard let item = metadataItems.first(where: { $0.commonKey == key }) else { continue }
                guard let value = try? await item.load(.value) as? String else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false {
                    return trimmed
                }
            }

            return nil
        }

        let title = await firstString(for: [.commonKeyTitle, .commonKeyAlbumName, .commonKeyCreator]) ?? fallbackTitle

        let author = await firstString(for: [.commonKeyArtist, .commonKeyCreator])

        let subtitle = await firstString(for: [.commonKeyAlbumName, .commonKeyArtist, .commonKeyCreator])

        return SideLoadedAudioMetadata(
            title: title,
            author: author,
            subtitle: subtitle,
            description: nil,
            publishDate: resourceValues?.creationDate
                ?? resourceValues?.contentModificationDate,
            duration: duration,
            fileSize: resourceValues?.fileSize.map(Int64.init)
        )
    }

    private static func fallbackTitle(for fileURL: URL) -> String {
        let rawName = fileURL.deletingPathExtension().lastPathComponent
        let cleaned = rawName.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? fileURL.lastPathComponent : cleaned
    }
}
