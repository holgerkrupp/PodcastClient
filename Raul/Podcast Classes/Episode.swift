//
//  Episode.swift
//  Raul
//
//  Created by Holger Krupp on 04.04.25.
//
import SwiftData
import Foundation
import SwiftUI
import mp3ChapterReader



struct ExternalFile:Codable{
    
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
    var id: UUID = UUID()
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
    
    var transcriptLines: [TranscriptLineAndTime]?
    
    var externalFiles:[ExternalFile] = []
    
    // See also: Podcast.funding
    var funding: [FundingInfo] = []
 
    
    
    
    @Relationship(deleteRule: .cascade) var chapters: [Marker]? = []
    @Relationship(deleteRule: .cascade) var bookmarks: [Marker]? = []
    
    @Relationship(deleteRule: .cascade) var metaData: EpisodeMetaData?
    @Relationship var playlist: [PlaylistEntry]? = []
    
    // temporary values that don't need to survive an app restart
    @Transient @Published var refresh: Bool = false
    @Transient var downloadItem: DownloadItem? = nil {
        didSet {
            print("downloadItem changed")
        }
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
    
    //MARK: calculated properties that will be generated out of existing properties.
    var localFile: URL? {
        let fileName = url?.lastPathComponent
         let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first // podcast?.directoryURL ?? URL(fileURLWithPath: "/", isDirectory: true)
        
        // Create a sanitized filename
        let sanitizedFileName = fileName?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let sanitizedguid = guid?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)

        let uniqueURL = baseURL?.appendingPathComponent("\(id.uuidString)_\(sanitizedFileName)")
        
 
        
        return uniqueURL
    }
    
    var coverFileLocation: URL? {
        let fileName = imageURL?.lastPathComponent ?? "cover.jpg"
        let baseURL = podcast?.directoryURL ?? URL(fileURLWithPath: "/", isDirectory: true)
        
        // Create a sanitized filename
        let sanitizedFileName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        
        let uniqueURL = baseURL.appendingPathComponent("\(guid ?? id.uuidString)_\(sanitizedFileName)")
        
        try? FileManager.default.createDirectory(at: uniqueURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: nil)
        return uniqueURL
    }
    
    



    
    @Transient var preferredChapters: [Marker] {

        let preferredOrder: [MarkerType] = [.mp3, .mp4, .podlove, .extracted, .ai]

        let categoryGroups = Dictionary(grouping: chapters ?? [], by: { $0.title + (Duration.seconds($0.start ?? 0.0).formatted(.units(width: .narrow))) })
        
        return categoryGroups.values.flatMap { group in
            let highestCategory = group.max(by: { preferredOrder.firstIndex(of: $0.type) ?? 0 < preferredOrder.firstIndex(of: $1.type) ?? preferredOrder.count })?.type
            return group.filter { $0.type == highestCategory }
        }
    }


    init(id: UUID, guid:String? = nil, title: String, publishDate: Date? = nil, url: URL, podcast: Podcast, duration:Double? = nil, author: String? = nil) {
        self.id = id
        self.guid = guid
        self.title = title
        self.author = author
        self.publishDate = publishDate
        self.url = url
      //  self.podcasts?.append(podcast)
        self.podcast = podcast
        self.duration = duration
        
        // Create metadata after all properties are initialized
        let metadata = EpisodeMetaData()
        metadata.episode = self
        self.metaData = metadata
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
        
        for transcript in episodeData["transcripts"] as? [ExternalFile] ?? []{
            externalFiles.append(transcript)
        }
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
        
        
        if self.metaData == nil {
            let metadata = EpisodeMetaData()
            metadata.episode = self
            self.metaData = metadata
        }
        
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

        
        let uuid = UUID()
        
        // Initialize with the convenience initializer
        self.init(id: uuid, title: title, url: url, podcast: podcast)

        // additional Optional Values
        updateEpisodeData(from: episodeData)

    }
    
    
    
    
}

enum EpisodeStatus: String, Codable{
    case inbox, history, archived, unknown
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
   
    
    @Relationship(inverse: \Episode.metaData) var episode: Episode?
    
    /// Date the episode was finished
    var completionDate: Date?

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

