//
//  episode.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData
import SwiftUI
import AVFoundation



enum EpisodeType: String, Codable{
    case full, trailer, bonus, unknown
}

@Model
class Episode: Equatable, Hashable{
    
    //MARK: Values to be storred in the database
    var id = UUID()
    var title: String?
    
    var desc: String?
    var subtitle: String?
    var content: String?
    var decodedContent: String?
    
    var guid: String?
    
    var link: URL?
    var pubDate: Date?
    
    var image: URL?
    var cover:Data?

    
    var number: String?
    var season: String?
    
    var type: EpisodeType = EpisodeType.unknown
    

    var assetType: String?
    var assetLink: URL? // the original URL of the asset
    var length: Int?
    var transcriptURL: [URL]?
    var transcripts:[Transcript]?
    
    @Relationship(deleteRule: .cascade, inverse: \Chapter.episode)  var chapters: [Chapter]?
    var playlists: [PlaylistEntry]? = []
    
    var podcast: Podcast?
    var events: [Event]?
 
    
   // var playpostion: Double = 0.0
    var playPosition:Double  = 0.0{
        didSet{
            updateLastPlayed()
        }
    }
    var lastPlayed: Date?
    var finishedPlaying: Bool? = false
    var duration:Double?
    
    
    var isAvailableLocally:Bool = false
  
 
    //MARK: values that don't need to be stored
    
    @Transient var downloadStatus = EpisodeDownloadStatus()
    
    
    //MARK: calculated properties that a generated on the fly
    
  
    
    @Transient var localFile: URL?{
        let fileName = assetLink?.lastPathComponent ?? title ?? pubDate?.ISO8601Format() ?? Date().ISO8601Format()
        let documentsDirectoryUrl = podcast?.directoryURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return documentsDirectoryUrl?.appendingPathComponent(fileName).standardizedFileURL
    }
    
    func UpdateisAvailableLocally() -> Bool?{
        
        if let localFile = localFile?.path() {
            let manager = FileManager()
            isAvailableLocally = true
            return  manager.fileExists(atPath: localFile)
        }else{
            isAvailableLocally = false
            return false
        }
    }
    
 
    
    @Transient var avAsset:AVAsset?{
        print("avAsset read - \(localFile?.absoluteString) - \(isAvailableLocally)")
        if let url = localFile, isAvailableLocally{
            return AVAsset(url: url)
        }else{
            print("avAsset remote - \(assetLink?.absoluteString)")
            if let remoteURL = assetLink{
                return AVAsset(url: remoteURL)
            }
        }
        return nil
    }
    
    
    
    
    @Transient var coverImage: some View{
        
        if let imageURL = image{
            return AnyView(ImageWithURL(imageURL))
        }else if let podcastcover = podcast?.coverURL{
            return AnyView(ImageWithURL(podcastcover))
        }else{
            return AnyView(Image(systemName: "mic.fill"))
        }
         
    }
    
    
    @Transient var uiimage: UIImage{
    
        if let cover{
            return ImageWithData(cover).uiImage()
        }else if let cover = podcast?.cover{
            return ImageWithData(cover).uiImage()
        }else{
            return UIImage(systemName: "photo") ?? UIImage()
        }
    }
    
  

    
    @Transient var progress:Double {
        if let duration{
            return ((playPosition) / duration)
        }
        return 0.0
    }

    func updateLastPlayed(){
        self.lastPlayed = Date()
    }
    
    func postProcessingAfterDownload() async{
        print("postProcessing")
        await updateDuration()
        await updateChapters()
        
        

    }
    
    func updateChapters() async{
        let embeddedChapterCount = chapters?.filter({ $0.type == .embedded }).count ?? 0
        if embeddedChapterCount == 0{
            if let localFile{
                let fileChapters = await createChapters(from: localFile) ?? []
                chapters?.append(contentsOf: fileChapters)
            }
        }
        
        let extractedChapterCount = chapters?.filter({ $0.type == .extracted }).count ?? 0
        if extractedChapterCount == 0{
            if let sourceText = content ?? desc{
                chapters =  createChapters(from: sourceText)
            }
        }
        
        if let chapters, chapters.count > 0{

            
            
            var chapterGrouped = Dictionary(grouping: chapters, by: { $0.type })
            
            for group in chapterGrouped{
                print("enhancing \(group.key.rawValue) chapters")
                var lastEnd = duration ?? 100
                for chapter in chapters.sorted(by: {$0.start ?? 0.0 > $1.start ?? duration ?? 100}){
                    chapter.duration = lastEnd - (chapter.start ?? 0.0)
                    lastEnd = chapter.start ?? 0.0
                }
            }
            
            
        }
        
    }
    
    func updateDuration() async{
        print("updating Duration")
        if let localFile = localFile{
            do{
                
                let duration = try await AVAsset(url: localFile).load(.duration)
                print (duration.seconds)
               setDuration(duration)
                
            }catch{
                print(error)
            }
        }
    }
    func setDuration(_ duration: CMTime) {
        
        let seconds = CMTimeGetSeconds(duration)
        print("updating to \(seconds.description)")
        
        if !seconds.isNaN{
            self.duration = seconds
        }
         
    }

    
    func playNow(){
        Player.shared.setCurrentEpisode(episode: self, playDirectly: true)
    }
    
    
    func download(){
        print("episode download")
        Task{
            do{
                try await DownloadManager.shared.download(self)
            }catch{
                print(error)
            }
        }
        
    }
    
    func removeFile(){
        print("removing localFile")
        downloadStatus.update(currentBytes: 0, totalBytes: 0)
        
        if let file = localFile{
            try? FileManager.default.removeItem(at: file)
            isAvailableLocally = false
        }
    }
    
    

    //MARK: INIT
    init(details: [String: Any], podcast:Podcast?) async {
        guid = details["guid"] as? String
        title = details["itunes:title"] as? String ?? details["title"] as? String
        subtitle = details["itunes:subtitle"] as? String

        desc = details["description"] as? String
        
        content = details["content"] as? String
     /*
        if let content{
            decodedContent = content.decodeHTML()
        }
       */
        duration = (details["itunes:duration"] as? String)?.durationAsSeconds

        link = URL(string: details["link"] as? String ?? "")
        pubDate = Date.dateFromRFC1123(dateString: details["pubDate"] as? String ?? "")
        image = URL(string: details["itunes:image"] as? String ?? "")
    
 /* THIS TAKES TO MUCH TIME WHILE SUBSCRIBING TO FEEDS
        if let image{
            cover = await image.downloadData()
        }
*/
        number = details["itunes:episode"] as? String
        
        type = EpisodeType(rawValue: details["itunes:episodeType"] as? String ?? "unknown") ?? .unknown
        

      
        for assetDetails in details["enclosure"] as? [[String:Any]] ?? []{
            
            assetLink = URL(string: assetDetails["url"] as? String ?? "")// the original URL of the asset
            length = Int(assetDetails["length"] as? String ?? "")
            assetType = assetDetails["type"] as? String
 
        }
        
        for transcript in details["transcripts"] as? [Transcript] ?? []{
            transcripts?.append(transcript)
        }

        if let psc = details["psc:chapters"] as? [[String:Any]]{
            chapters = createChapters(from: psc)
        }
        
        
        if guid == nil || guid == ""{
            guid = assetLink?.absoluteString ?? id.uuidString
        }
        
    }

    func markAsPlayed(){
      finishedPlaying = true
    }
    
    func markAsNotPlayed(){
        finishedPlaying = false
    }
    

    
}

