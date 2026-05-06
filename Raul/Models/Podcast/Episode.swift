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
            localfile: localFile
        )
    }

    var remainingTime: Double? {
        return (duration ?? 0.0) - (metaData?.playPosition ?? 0.0)
    }
    
    var playProgress: Double {
       
        guard metaData?.playPosition != nil else { return 0.0 }
        guard duration != 0.0 else { return 0.0 }
        guard duration != nil else { return 0.0 }
        let progress = Double(metaData?.playPosition ?? 0.0) / Double(duration ?? 1)
        
        return  progress > 1 ? 1 : progress
    }
    
    var maxPlayProgress: Double {
       
        guard metaData?.maxPlayposition != nil else { return 0.0 }
        guard duration != 0.0 else { return 0.0 }
        guard duration != nil else { return 0.0 }
        let progress = Double(metaData?.maxPlayposition ?? 0.0) / Double(duration ?? 1)
        
        return  progress > 1 ? 1 : progress
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
            return chapters.filter { $0.type == preferredType }
        }

        let preferredOrder: [MarkerType] = [.podlove, .mp3, .mp4, .ai, .extracted]

        // Pick a single type for the whole list based on availability and preference order.
        let availableTypes = Set(chapters.map { $0.type })
        if let chosenType = preferredOrder.first(where: { availableTypes.contains($0) }) {
            return chapters.filter { $0.type == chosenType }
        } else {
            // Fallback: no known preferred types found, return all chapters as-is.
            return chapters
        }
    }

    @Transient var preferredChapters: [Marker] {
        chaptersForDisplay()
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
        self.duration = (episodeData["itunes:duration"] as? String)?.durationAsSeconds
        self.author = episodeData["itunes:author"] as? String
        self.guid = episodeData["guid"] as? String ?? episodeData["podcast:guid"] as? String ?? (episodeData["enclosure"] as? [[String: Any]])?.first?["url"] as? String
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
        }
        
        for assetDetails in episodeData["enclosure"] as? [[String:Any]] ?? []{
            
            if let url = URL(string: assetDetails["url"] as? String ?? "") {
                self.url = url
            }
            if let length = Int64(assetDetails["length"] as? String ?? ""){
                self.fileSize = length
            }
            let _ = assetDetails["type"] as? String
 
        }
        
        replaceExternalFiles(with: feedExternalFiles(from: episodeData))
        if let chaptersData = episodeData["psc:chapters"] as? [[String: Any]] {
            for chapterData in chaptersData {
                let chapter = Marker(details: chapterData)
                chapter.episode = self
                self.chapters?.append(chapter)
            }
            chapters?.sort { $0.start ?? 0.0 < $1.start ?? 0.0 }
            for i in 0..<(chapters?.count ?? 0){
                if chapters?[i].duration == nil {
                    
                    if i + 1 < (chapters?.count ?? 0), let nextStart = chapters?[i + 1].start {
                        chapters?[i].duration = nextStart - (chapters?[i].start ?? 0.0)
                    } else {
                        chapters?[i].duration = (duration ?? 0.0) - (chapters?[i].start ?? 0.0)
                    }
                }
            }
            
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
        refresh.toggle()
    }
    

    
    convenience init?(from episodeData: [String: Any], podcast: Podcast) {
        guard let title = episodeData["itunes:title"] as? String ?? episodeData["title"] as? String,
              let urlString = episodeData["enclosure"] as? [[String: Any]],
              let firstEnclosure = urlString.first,
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

    /// Accumulated listening time
    var totalListenTime: TimeInterval = 0

    /// Speeds used per session
    var playbackSpeeds: CodableArray<Double>?

    /// When playback first started
    var firstListenDate: Date?

    /// Whether the user skipped the episode
    var wasSkipped: Bool = false

    
    init() {
        self.playbackStartTimes = CodableArray([])
        self.playbackDurations = CodableArray([])
        self.playbackSpeeds = CodableArray([])
               
    }
}
