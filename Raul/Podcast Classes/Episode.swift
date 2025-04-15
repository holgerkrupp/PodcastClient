//
//  Episode.swift
//  Raul
//
//  Created by Holger Krupp on 04.04.25.
//
import SwiftData
import Foundation
import SwiftUI



struct Transcript:Codable{
    let url:String
    let type:String
    let source:String
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
    var id: UUID
    @Attribute(.unique) var guid: String?
    var title: String
    var author: String?
    var desc: String?
    var subtitle: String?
    var content: String?
    
    
    
    var publishDate: Date?
    var url: URL // episodeURL - the mp3/m4a file
    var fileSize: Int64?
    var link: URL? // Link to the episode webpage
    var imageURL: URL? // Episode Image
    
    var podcast: Podcast?
    var duration:Double?
    var number: String?
    var type: EpisodeType?
    
    var transcripts:[Transcript] = []
    var transcriptData:String?

    @Relationship(deleteRule: .cascade) var chapters: [Chapter] = []
    @Relationship(deleteRule: .cascade) var metaData: EpisodeMetaData?

    
    // temporary values that don't need to survive an app restart
    @Transient var downloadStatus = EpisodeDownloadStatus()
    @Transient @Published var refresh: Bool = false
    
    var remainingTime: Double? {
        return (duration ?? 0.0) - (metaData?.playPosition ?? 0.0)
    }
    
    // calculated properties that will be generated out of existing properties.
    var localFile: URL? {
        let fileName = url.lastPathComponent
        let documentsDirectoryUrl = podcast?.directoryURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let baseURL = documentsDirectoryUrl else { return nil }
        
        // Create a sanitized filename
        let sanitizedFileName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        
        let uniqueURL = baseURL.appendingPathComponent("\(guid ?? id.uuidString)_\(sanitizedFileName)")
        
        // Create the full URL
      //  let fullURL = baseURL.appendingPathComponent(sanitizedFileName)
        
        // Ensure the directory exists
        try? FileManager.default.createDirectory(at: uniqueURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: nil)
        
      
        
        return uniqueURL
    }
    @MainActor
    @Transient lazy var coverImage: some View = {
        
        if let imageURL {
            return AnyView(ImageWithURL(imageURL))
        }else if let podcastcover = podcast?.coverImageURL{
            return AnyView(ImageWithURL(podcastcover))
        }else{
            return AnyView(EmptyView())
        }
         
    }()
    
    @Transient var preferredChapters: [Chapter] {

        let preferredOrder: [ChapterType] = [.mp3, .embedded, .podlove, .extracted]

        let categoryGroups = Dictionary(grouping: chapters, by: { $0.title + ($0.start?.secondsToHoursMinutesSeconds ?? "") })
        
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
        self.podcast = podcast
        self.duration = duration
        
        // Create metadata after all properties are initialized
        let metadata = EpisodeMetaData()
        metadata.episode = self
        self.metaData = metadata
    }
    

    
    func updateEpisodeData(from episodeData: [String: Any]) {
        self.duration = (episodeData["itunes:duration"] as? String)?.durationAsSeconds
        self.author = episodeData["itunes:author"] as? String
        self.guid = episodeData["guid"] as? String ?? (episodeData["enclosure"] as? [[String: Any]])?.first?["url"] as? String
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
        
        for transcript in episodeData["transcripts"] as? [Transcript] ?? []{
            transcripts.append(transcript)
        }
        if let chaptersData = episodeData["psc:chapters"] as? [[String: Any]] {
            for chapterData in chaptersData {
                let chapter = Chapter(details: chapterData)
                chapter.episode = self
                self.chapters.append(chapter)
            }
            chapters.sort { $0.start ?? 0.0 < $1.start ?? 0.0 }
           for i in 0..<chapters.count{
               if chapters[i].duration == nil{
                   if i+1 <= chapters.count, let nexStart = chapters[i+1].start{
                       chapters[i].duration = nexStart - (chapters[i].start ?? 0.0)
                   }
               }
            }
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
    
    

    
    func markEpisodeAvailable()  {
        downloadStatus.isDownloading = false
        
        // Capture the values we need before starting the Task
        guard let container = self.modelContext?.container else { return }
        
              let modelID = self.persistentModelID
        
        Task {
            let actor = EpisodeActor(modelContainer: container)
            await actor.downloadTranscript(modelID)
            await actor.extractMP3Chapters(modelID)
        }
        
    }
    
    func deleteFile(){
        if let file = localFile{
            try? FileManager.default.removeItem(at: file)
            refresh.toggle()
        }
    }
    
}


@Model final class EpisodeMetaData{
    var isAvailableLocally: Bool {
        guard let url = episode?.localFile else {
            print("local file not set for \(episode?.title ?? "unknown episode")")
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
    var lastPlayed: Date?
    var finishedPlaying: Bool? = false
    var maxPlayposition:Double? = 0.0
    var playPosition:Double? = 0.0
    
    var isArchived: Bool? = false
   
    
    @Relationship(inverse: \Episode.metaData) var episode: Episode?
    
    init() {
    }
}
