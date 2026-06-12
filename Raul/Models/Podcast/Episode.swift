//
//  Episode.swift
//  Raul
//
//  Created by Holger Krupp on 04.04.25.
//
import CryptoKit
import SwiftData
import Foundation
import SwiftUI
import mp3ChapterReader

/// Lightweight, sendable summary for use across actors/UI layers (e.g., CarPlay)
struct EpisodeSummary: Sendable, Hashable {
    let url: URL?
    let title: String?
    let desc: String?
    let podcast: String?
    let cover: URL?
    let podcastCover: URL?
    let file: URL?
    let localfile: URL?
    let maxPlayProgress: Double
}

struct ExternalFile: Codable, Hashable {
    
    enum FileType: String, Codable{
        case transcript, chapter, image
    }
    
    let url:String
    let category:FileType?
    let source:String?
    let fileType:String?
}

enum EpisodeType: String, Codable{
    case full, trailer, bonus, unknown
}

enum EpisodeMedia {
    struct AlternateVideo: Hashable {
        let url: URL
        let mimeType: String?
        let title: String?
    }

    static func isUnsupportedOggVorbis(url: URL?, mimeType: String?) -> Bool {
        if let mimeType = mimeType?.lowercased() {
            if mimeType.contains("ogg") || mimeType.contains("vorbis") {
                return true
            }
        }

        switch url?.pathExtension.lowercased() {
        case "ogg", "oga":
            return true
        default:
            return false
        }
    }

    static func isVideo(url: URL?, mimeType: String?) -> Bool {
        if let mimeType = mimeType?.lowercased() {
            if mimeType.hasPrefix("video/") {
                return true
            }

            if mimeType.contains("mpegurl") || mimeType.contains("vnd.apple.mpegurl") {
                return true
            }
        }

        let pathExtension = url?.pathExtension.lowercased()
        return pathExtension == "mp4" || pathExtension == "m3u8"
    }

    static func isPlayable(url: URL?, mimeType: String?) -> Bool {
        if isUnsupportedOggVorbis(url: url, mimeType: mimeType) {
            return false
        }

        if let mimeType = mimeType?.lowercased() {
            if mimeType.hasPrefix("audio/") || mimeType.hasPrefix("video/") {
                return true
            }

            if mimeType.contains("mpegurl") || mimeType.contains("vnd.apple.mpegurl") {
                return true
            }
        }

        guard let pathExtension = url?.pathExtension.lowercased(),
              pathExtension.isEmpty == false else {
            return false
        }

        let playableExtensions: Set<String> = [
            "aac", "aif", "aiff", "flac", "m4a", "m4v", "m3u8", "mov",
            "mp3", "mp4", "opus", "wav"
        ]
        return playableExtensions.contains(pathExtension)
    }

    static func isImage(url: URL?, mimeType: String?) -> Bool {
        if let mimeType = mimeType?.lowercased(), mimeType.hasPrefix("image/") {
            return true
        }

        guard let pathExtension = url?.pathExtension.lowercased(),
              pathExtension.isEmpty == false else {
            return false
        }

        let imageExtensions: Set<String> = ["avif", "gif", "heic", "jpeg", "jpg", "png", "webp"]
        return imageExtensions.contains(pathExtension)
    }

    static func playableEnclosure(from enclosures: [[String: Any]]?) -> [String: Any]? {
        enclosures?.first { enclosure in
            let url = (enclosure["url"] as? String).flatMap(URL.init(string:))
            let mimeType = enclosure["type"] as? String
            return isPlayable(url: url, mimeType: mimeType)
        }
    }

    static func imageEnclosure(from enclosures: [[String: Any]]?) -> [String: Any]? {
        enclosures?.first { enclosure in
            let url = (enclosure["url"] as? String).flatMap(URL.init(string:))
            let mimeType = enclosure["type"] as? String
            return isImage(url: url, mimeType: mimeType)
        }
    }

    static func alternateVideo(from optionalTags: PodcastNamespaceOptionalTags?) -> AlternateVideo? {
        optionalTags?.alternateEnclosure?
            .compactMap { node -> AlternateVideo? in
                let mimeType = node.attributes["type"] ?? node.attributes["contentType"]
                let sourceURLString = node.children
                    .first { localName(from: $0.name) == "source" }?
                    .attributes["uri"]
                    ?? node.attributes["url"]
                    ?? node.attributes["uri"]

                guard let sourceURLString,
                      let url = URL(string: sourceURLString),
                      isVideo(url: url, mimeType: mimeType) else {
                    return nil
                }

                return AlternateVideo(
                    url: url,
                    mimeType: mimeType,
                    title: node.attributes["title"]
                )
            }
            .first
    }

    private static func localName(from qualifiedName: String) -> String {
        if let separatorIndex = qualifiedName.firstIndex(of: ":") {
            return String(qualifiedName[qualifiedName.index(after: separatorIndex)...])
        }
        return qualifiedName
    }
}

private final class EpisodeLocalFileCache: @unchecked Sendable {
    static let shared = EpisodeLocalFileCache()

    private let cache = NSCache<NSString, NSURL>()
    private let lock = NSLock()

    func url(for key: NSString) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: key) as URL?
    }

    func store(_ url: URL, for key: NSString) {
        lock.lock()
        defer { lock.unlock() }
        cache.setObject(url as NSURL, forKey: key)
    }
}

enum EpisodeSource: String, Codable, CaseIterable, Hashable, Sendable {
    case feedDownload
    case sideLoaded
}

@Observable
class EpisodeDownloadStatus{
     var isDownloading: Bool = false
    private(set) var currentBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    var downloadProgress: Double {
        guard totalBytes > 0 else { return 0.0 }
        
        return Double(currentBytes) / Double(totalBytes)
    }
    
    
    
    func update(currentBytes: Int64, totalBytes: Int64) {
        self.currentBytes = currentBytes
        self.totalBytes = totalBytes
    }
    

}

@Model final class Episode {
    var guid: String?
    var title: String = ""
    var author: String?
    var desc: String?
    var subtitle: String?
    var content: String?
    
    
    var publishDate: Date?
    var url: URL? // episodeURL - the mp3/m4a file
    var deeplinks: [URL]?
    var fileSize: Int64?
    var mediaType: String?
    var link: URL? // Link to the episode webpage
    var imageURL: URL? // Episode Image
    
    var podcast: Podcast?
    var duration:Double?
    var number: String?
    var type: EpisodeType?
    var sourceRawValue: String = EpisodeSource.feedDownload.rawValue
    
    @Relationship(deleteRule: .cascade) var transcriptLines: [TranscriptLineAndTime]?
    @Relationship(deleteRule: .noAction) var playSessions: [PlaySession]?
    
    var externalFiles:[ExternalFile] = []
    
    // See also: Podcast.funding
    var funding: [FundingInfo] = []
    var social: [SocialInfo] = []
    var people: [PersonInfo] = []
    var optionalTags: PodcastNamespaceOptionalTags?
 
    @Relationship(deleteRule: .cascade) var chapters: [Marker]? = []
    @Relationship(deleteRule: .cascade) var bookmarks: [Bookmark]? = []
    
    @Relationship(deleteRule: .cascade) var metaData: EpisodeMetaData?
    @Relationship var playlist: [PlaylistEntry]? = []
    
    // temporary values that don't need to survive an app restart
    @Transient @Published var refresh: Bool = false
    @Transient var downloadItem: DownloadItem? = nil {
        didSet {
            // print("downloadItem changed")
        }
    }
    // NEW: UI state for transcription
    @Transient var transcriptionItem: TranscriptionItem? = nil

    /// A lightweight, cross-actor safe snapshot of this episode
    var summary: EpisodeSummary {
        EpisodeSummary(
            url: url,
            title: title.isEmpty ? nil : title,
            desc: desc,
            podcast: displayPodcastTitle,
            cover: imageURL,
            podcastCover: podcast?.imageURL,
            file: url,
            localfile: localFile,
            maxPlayProgress: maxPlayProgress
        )
    }

    var remainingTime: Double? {
        return (duration ?? 0.0) - (metaData?.playPosition ?? 0.0)
    }
    
    var playProgress: Double {
        get{
            guard metaData?.playPosition != nil else { return 0.0 }
            guard duration != 0.0 else { return 0.0 }
            guard duration != nil else { return 0.0 }
            let progress = Double(metaData?.playPosition ?? 0.0) / Double(duration ?? 1)
            
            return  progress > 1 ? 1 : progress
        }
        set{
            guard let duration, duration != 0 else { return }

            let clampedProgress = min(max(newValue, 0.0), 1.0)
            metaData?.playPosition = clampedProgress * duration
        }
    }
    
    var maxPlayProgress: Double {
       
        guard metaData?.maxPlayposition != nil else { return 0.0 }
        guard duration != 0.0 else { return 0.0 }
        guard duration != nil else { return 0.0 }
        let progress = Double(metaData?.maxPlayposition ?? 0.0) / Double(duration ?? 1)
        
        return  progress > 1 ? 1 : progress
    }

    @Transient var isVideo: Bool {
        EpisodeMedia.isVideo(url: url, mimeType: mediaType)
    }

    @Transient var alternateVideo: EpisodeMedia.AlternateVideo? {
        EpisodeMedia.alternateVideo(from: optionalTags)
    }

    @Transient var hasAlternateVideo: Bool {
        alternateVideo != nil
    }

    var hasLoadedTranscript: Bool {
        transcriptLines?.isEmpty == false
    }
    
    //MARK: calculated properties that will be generated out of existing properties.
    private var urlIdentityComponent: String? {
        guard let url else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var source: EpisodeSource {
        get {
            EpisodeSource(rawValue: sourceRawValue) ?? .feedDownload
        }
        set {
            sourceRawValue = newValue.rawValue
        }
    }

    var displayPodcastTitle: String? {
        podcast?.title ?? (source == .sideLoaded ? "Side loaded" : nil)
    }

    var localFile: URL? {
        let cacheKey = "\(source.rawValue)|\(url?.absoluteString ?? "")" as NSString
        if let cachedURL = EpisodeLocalFileCache.shared.url(for: cacheKey) {
            return cachedURL
        }

        let resolvedURL: URL?
        if source == .sideLoaded {
            resolvedURL = url
        } else {
            let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first

            guard let fileName = url?.lastPathComponent,
                  let urlIdentityComponent else { return nil }
            let sanitizedFileName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
            resolvedURL = baseURL?.appendingPathComponent("\(urlIdentityComponent)_\(sanitizedFileName)")
        }

        if let resolvedURL {
            EpisodeLocalFileCache.shared.store(resolvedURL, for: cacheKey)
        }

        return resolvedURL
    }
    
    func chaptersForDisplay(preferredType: MarkerType? = nil) -> [Marker] {
        let chapters = chapters ?? []
        guard chapters.isEmpty == false else { return [] }

        if let preferredType {
            return chapters
                .filter { $0.type == preferredType }
                .sortedByStartTime()
        }

        let preferredOrder: [MarkerType] = [.mp3, .mp4, .podlove, .ai, .extracted]

        // Pick a single type for the whole list based on availability and preference order.
        let availableTypes = Set(chapters.map { $0.type })
        if let chosenType = preferredOrder.first(where: { availableTypes.contains($0) }) {
            return chapters
                .filter { $0.type == chosenType }
                .sortedByStartTime()
        } else {
            // Fallback: no known preferred types found, return all chapters as-is.
            return chapters.sortedByStartTime()
        }
    }

    @Transient var preferredChapters: [Marker] {
        chaptersForDisplay()
    }

    func displayTitle(for chapter: Marker) -> String {
        let ownTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUsableChapterTitle(ownTitle, for: chapter) {
            return ownTitle
        }

        if let matchedTitle = matchingChapterTitle(for: chapter) {
            return matchedTitle
        }

        return ownTitle.isEmpty ? "Untitled chapter" : ownTitle
    }

    private func matchingChapterTitle(for chapter: Marker) -> String? {
        let start = chapter.start ?? 0
        let titleSourcePreference: [MarkerType] = [.podlove, .mp4, .ai, .extracted, .mp3]
        let candidateTypes = titleSourcePreference.filter { $0 != chapter.type }

        return (chapters ?? [])
            .filter { candidate in
                candidate.id != chapter.id
                    && candidateTypes.contains(candidate.type)
                    && abs((candidate.start ?? 0) - start) <= 1.0
                    && isUsableChapterTitle(candidate.title, for: candidate)
            }
            .sorted { lhs, rhs in
                let lhsDelta = abs((lhs.start ?? 0) - start)
                let rhsDelta = abs((rhs.start ?? 0) - start)
                if lhsDelta != rhsDelta {
                    return lhsDelta < rhsDelta
                }
                let lhsTypeIndex = candidateTypes.firstIndex(of: lhs.type) ?? Int.max
                let rhsTypeIndex = candidateTypes.firstIndex(of: rhs.type) ?? Int.max
                return lhsTypeIndex < rhsTypeIndex
            }
            .first?
            .title
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isUsableChapterTitle(_ title: String, for chapter: Marker) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }

        if chapter.type == .mp3, looksLikeMP3ChapterElementID(trimmed) {
            return false
        }

        return true
    }

    private func looksLikeMP3ChapterElementID(_ title: String) -> Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.range(
            of: #"^(ch|chap|chapter)[-_]?\d+$"#,
            options: .regularExpression
        ) != nil
    }

    @Transient var soundbitesForDisplay: [Marker] {
        let storedSoundbites = (chapters ?? [])
            .filter { $0.type == .soundbite }
            .sorted { ($0.start ?? 0) < ($1.start ?? 0) }

        if storedSoundbites.isEmpty == false {
            return storedSoundbites
        }

        return (optionalTags?.soundbite ?? [])
            .compactMap { node -> Marker? in
                guard let marker = soundbiteMarker(from: node) else { return nil }
                marker.episode = self
                return marker
            }
            .sorted { ($0.start ?? 0) < ($1.start ?? 0) }
    }

    @Transient var hasDisplayableChaptersOrSoundbites: Bool {
        preferredChapters.count > 1 || soundbitesForDisplay.isEmpty == false
    }

    init(
        guid:String? = nil,
        title: String,
        publishDate: Date? = nil,
        url: URL,
        podcast: Podcast? = nil,
        duration:Double? = nil,
        author: String? = nil,
        source: EpisodeSource = .feedDownload
    ) {
        self.guid = guid
        self.title = title
        self.author = author
        self.publishDate = publishDate
        self.url = url
        self.podcast = podcast
        self.duration = duration
        self.source = source
        
        // Create metadata after all properties are initialized
        let metadata = EpisodeMetaData()
        metadata.episode = self
        self.metaData = metadata
    }
    


    convenience init(
        sideLoadedURL: URL,
        title: String,
        publishDate: Date? = nil,
        duration: Double? = nil,
        author: String? = nil
    ) {
        self.init(
            guid: sideLoadedURL.absoluteString,
            title: title,
            publishDate: publishDate,
            url: sideLoadedURL,
            podcast: nil,
            duration: duration,
            author: author,
            source: .sideLoaded
        )
    }
  
    private func updateEpisodeData(from episodeData: [String: Any]) {
        let feedDuration = (episodeData["itunes:duration"] as? String)?.durationAsSeconds
        let hasLocalFile = localFile.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false

        if hasLocalFile == false {
            if let feedDuration, feedDuration > 0 {
                duration = feedDuration
            } else if duration == nil || duration == 0 {
                duration = feedDuration
            }
        }
        self.author = episodeData["itunes:author"] as? String
        let enclosures = episodeData["enclosure"] as? [[String: Any]]
        let playableEnclosure = EpisodeMedia.playableEnclosure(from: enclosures)
        let imageEnclosure = EpisodeMedia.imageEnclosure(from: enclosures)

        self.guid = episodeData["guid"] as? String
            ?? episodeData["podcast:guid"] as? String
            ?? playableEnclosure?["url"] as? String
            ?? episodeData["link"] as? String
        self.desc = episodeData["description"] as? String
        self.subtitle = episodeData["itunes:subtitle"] as? String
        self.content = episodeData["content"] as? String
        self.link = URL(string: episodeData["link"] as? String ?? "")
        self.type = EpisodeType(rawValue: episodeData["itunes:episodeType"] as? String ?? "unknown") ?? .unknown
        
        if let pubDateString = episodeData["pubDate"] as? String{
            self.publishDate = Date.dateFromRFC1123(dateString: pubDateString)
        }
        
        number = episodeData["itunes:episode"] as? String
        
        if let url = episodeData["itunes:image"] as? String{
            self.imageURL = URL(string: url)
        } else if let imageURLString = imageEnclosure?["url"] as? String {
            self.imageURL = URL(string: imageURLString)
        }
        
        if let assetDetails = playableEnclosure {
            if let url = URL(string: assetDetails["url"] as? String ?? "") {
                self.url = url
                self.mediaType = assetDetails["type"] as? String
            }
            if let length = Int64(assetDetails["length"] as? String ?? ""){
                self.fileSize = length
            }
        } else if EpisodeMedia.isImage(url: url, mimeType: mediaType) {
            self.url = nil
            self.mediaType = nil
            self.fileSize = nil
        }
        
        replaceExternalFiles(with: feedExternalFiles(from: episodeData))
        if let chaptersData = episodeData["psc:chapters"] as? [[String: Any]] {
            let feedChapters = chaptersData.map { Marker(details: $0) }
            replaceChapters(ofType: .podlove, with: feedChapters)
            fillMissingChapterDurations(for: .podlove)
        }
        
        if let deepLinks = episodeData["deepLinks"] as? [String] {
            self.deeplinks = deepLinks.compactMap { URL(string: $0) }
        } else {
            self.deeplinks = nil
        }
        
        if let fundingArr = episodeData["funding"] as? [[String: String]] {
            self.funding = fundingArr.compactMap { dict in
                guard let string = dict["url"], let url = URL(string: string), let label = dict["label"] else { return nil }
                return FundingInfo(url: url, label: label)
            }
        } else if let fundingArr = episodeData["funding"] as? [FundingInfo] {
            self.funding = fundingArr
        }
        
        // Map episode-level social interactions
        if let socialArr = episodeData["socialInteract"] as? [[String: Any]] {
            self.social = socialArr.compactMap { dict in
                guard
                    let proto = dict["protocol"] as? String,
                    let uriStr = dict["uri"] as? String,
                    let uri = URL(string: uriStr)
                else { return nil }
                let accountId = dict["accountId"] as? String
                let accountUrlString = dict["accountUrl"] as? String
                let accountURL = accountUrlString.flatMap(URL.init(string:))
                let priority = dict["priority"] as? Int
                return SocialInfo(url: uri, socialprotocol: proto, accountId: accountId, accountURL: accountURL, priority: priority)
            }
        } else if let socialArr = episodeData["socialInteract"] as? [SocialInfo] {
            self.social = socialArr
        }
        
        // Map episode-level people
        if let peopleArr = episodeData["people"] as? [[String: Any]] {
            self.people = peopleArr.compactMap { dict in
                guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
                let role = dict["role"] as? String
                let href = (dict["href"] as? String).flatMap(URL.init(string:))
                let img = (dict["img"] as? String).flatMap(URL.init(string:))
                return PersonInfo(name: name, role: role, href: href, img: img)
            }
        } else if let peopleArr = episodeData["people"] as? [PersonInfo] {
            self.people = peopleArr
        }

        if let optionalTags = episodeData["optionalTags"] as? PodcastNamespaceOptionalTags,
           optionalTags.isEmpty == false {
            self.optionalTags = optionalTags
        } else {
            self.optionalTags = nil
        }

        refreshSoundbitesFromOptionalTags()
        
        if self.metaData == nil {
            let metadata = EpisodeMetaData()
            metadata.episode = self
            self.metaData = metadata
        }
        
    }

    func update(from episodeData: [String: Any]) {
        updateEpisodeData(from: episodeData)
    }

    private func feedExternalFiles(from episodeData: [String: Any]) -> [ExternalFile] {
        (episodeData["externalFiles"] as? [ExternalFile])
        ?? (episodeData["transcripts"] as? [ExternalFile])
        ?? []
    }

    private func chapterIdentity(for chapter: Marker) -> String {
        let normalizedTitle = chapter.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedStart = Int(((chapter.start ?? 0) * 100).rounded())
        return "\(chapter.type.rawValue)|\(normalizedStart)|\(normalizedTitle)"
    }

    private func uniqueChapters(_ chapters: [Marker]) -> [Marker] {
        var seen = Set<String>()
        return chapters.filter { chapter in
            seen.insert(chapterIdentity(for: chapter)).inserted
        }
    }

    private func replaceChapters(ofType type: MarkerType, with newChapters: [Marker]) {
        if chapters == nil {
            chapters = []
        }

        var existingByIdentity: [String: Marker] = [:]
        for chapter in (chapters ?? []) where chapter.type == type {
            let identity = chapterIdentity(for: chapter)
            if existingByIdentity[identity] == nil {
                existingByIdentity[identity] = chapter
            }
        }

        let replacementChapters = uniqueChapters(newChapters)
        for chapter in replacementChapters {
            chapter.episode = self
            if let existing = existingByIdentity[chapterIdentity(for: chapter)] {
                chapter.shouldPlay = existing.shouldPlay
                chapter.progress = existing.progress
                chapter.imageData = chapter.imageData ?? existing.imageData
            }
        }

        chapters?.removeAll { $0.type == type }
        chapters?.append(contentsOf: replacementChapters)
        chapters?.sort { ($0.start ?? 0) < ($1.start ?? 0) }
    }

    private func fillMissingChapterDurations(for type: MarkerType) {
        let typedChapters = (chapters ?? [])
            .filter { $0.type == type }
            .sorted { ($0.start ?? 0) < ($1.start ?? 0) }

        for index in typedChapters.indices where typedChapters[index].duration == nil {
            if index + 1 < typedChapters.count, let nextStart = typedChapters[index + 1].start {
                typedChapters[index].duration = nextStart - (typedChapters[index].start ?? 0)
            } else {
                typedChapters[index].duration = (duration ?? 0) - (typedChapters[index].start ?? 0)
            }
        }
    }

    private func replaceExternalFiles(with files: [ExternalFile]) {
        var seen = Set<ExternalFile>()
        externalFiles = files.filter { seen.insert($0).inserted }
    }

    func refreshFeedExternalFiles(from episodeData: [String: Any]) {
        let updatedFiles = feedExternalFiles(from: episodeData)
        guard updatedFiles != externalFiles else { return }
        replaceExternalFiles(with: updatedFiles)
        refresh.toggle()
    }

    func refreshOptionalTags(from episodeData: [String: Any]) {
        let parsedOptionalTags = episodeData["optionalTags"] as? PodcastNamespaceOptionalTags
        let updatedOptionalTags = (parsedOptionalTags?.isEmpty == false) ? parsedOptionalTags : nil
        guard updatedOptionalTags != optionalTags else { return }
        optionalTags = updatedOptionalTags
        refreshSoundbitesFromOptionalTags()
        refresh.toggle()
    }

    private func refreshSoundbitesFromOptionalTags() {
        if chapters == nil {
            chapters = []
        }

        chapters?.removeAll { $0.type == .soundbite }

        let soundbiteMarkers = optionalTags?.soundbite?.compactMap { soundbiteMarker(from: $0) } ?? []
        guard soundbiteMarkers.isEmpty == false else { return }

        for marker in soundbiteMarkers {
            marker.episode = self
            chapters?.append(marker)
        }

        chapters?.sort { ($0.start ?? 0) < ($1.start ?? 0) }
    }

    private func soundbiteMarker(from node: NamespaceNode) -> Marker? {
        guard let start = soundbiteTimeValue(from: node, keys: ["startTime", "start"]) else {
            return nil
        }

        let title = soundbiteTitle(from: node)
        guard title.isEmpty == false else { return nil }

        let duration = soundbiteTimeValue(from: node, keys: ["duration"])
        let marker = Marker(start: start, title: title, type: .soundbite, duration: duration)
        return marker
    }

    private func soundbiteTitle(from node: NamespaceNode) -> String {
        if let title = node.attributes["title"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           title.isEmpty == false {
            return title
        }

        return node.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func soundbiteTimeValue(from node: NamespaceNode, keys: [String]) -> Double? {
        for key in keys {
            guard let rawValue = node.attributes[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  rawValue.isEmpty == false else {
                continue
            }

            if let seconds = Double(rawValue) {
                return seconds
            }

            if let seconds = rawValue.durationAsSeconds {
                return seconds
            }
        }

        return nil
    }
    

    
    convenience init?(from episodeData: [String: Any], podcast: Podcast) {
        guard let title = episodeData["itunes:title"] as? String ?? episodeData["title"] as? String,
              let firstEnclosure = EpisodeMedia.playableEnclosure(from: episodeData["enclosure"] as? [[String: Any]]),
              let urlString = firstEnclosure["url"] as? String,
              let url = URL(string: urlString)
              else {
            return nil
        }
        // Initialize with the convenience initializer
        self.init(title: title, url: url, podcast: podcast)

        // additional Optional Values
        updateEpisodeData(from: episodeData)

    }
}

private extension Array where Element == Marker {
    func sortedByStartTime() -> [Marker] {
        sorted { ($0.start ?? 0) < ($1.start ?? 0) }
    }
}

enum EpisodeStatus: String, Codable{
    case inbox, history, archived, unknown
}

enum EpisodeSystemSuppressionReason: String, Codable, Sendable {
    case backCatalogImport
    case missingSideload
}

@Model final class EpisodeMetaData{
    var calculatedIsAvailableLocally: Bool {
        guard let url = episode?.localFile else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
    var isAvailableLocally: Bool = false
    
    var lastPlayed: Date?
    var maxPlayposition:Double? = 0.0 // in seconds
    var playPosition:Double? = 0.0  // in seconds
    
    var isArchived: Bool? = false
    var isHistory: Bool? = false
    var isInbox: Bool? = true
    
    var status: EpisodeStatus? = EpisodeStatus.inbox
    var systemSuppressionReasonRawValue: String?

    var systemSuppressionReason: EpisodeSystemSuppressionReason? {
        get {
            guard let systemSuppressionReasonRawValue else { return nil }
            return EpisodeSystemSuppressionReason(rawValue: systemSuppressionReasonRawValue)
        }
        set {
            systemSuppressionReasonRawValue = newValue?.rawValue
        }
    }
   
    
    @Relationship(inverse: \Episode.metaData) var episode: Episode?
    
    /// Date the episode was finished
    var completionDate: Date?

    /// Date the episode was moved to archive
    var archivedAt: Date?

    /// Playback start times per session
    var playbackStartTimes: CodableArray<Date>?

    /// Playback durations per session
    var playbackDurations: CodableArray<TimeInterval>?

    /// Time saved per playback session by reducing silence gaps.
    var silenceGapTimeSavedDurations: CodableArray<TimeInterval>?

    /// Accumulated listening time
    var totalListenTime: TimeInterval = 0

    /// Accumulated time saved by reducing silence gaps.
    var totalSilenceGapTimeSaved: TimeInterval = 0

    /// Speeds used per session
    var playbackSpeeds: CodableArray<Double>?

    /// When playback first started
    var firstListenDate: Date?

    /// Whether the user skipped the episode
    var wasSkipped: Bool = false

    
    init() {
        self.playbackStartTimes = CodableArray([])
        self.playbackDurations = CodableArray([])
        self.silenceGapTimeSavedDurations = CodableArray([])
        self.playbackSpeeds = CodableArray([])
               
    }
}
