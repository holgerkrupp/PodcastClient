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
class Episode: Equatable{
    
    //MARK: Values to be storred in the database
    var id = UUID()
    var title: String?
    var desc: String?
    var subtitle: String?
    
    var guid: String?
    
    var link: URL?
    var pubDate: Date?
    
    var image: URL?
    
    var number: String?
    var season: String?
    
    var type: EpisodeType = EpisodeType.unknown
    

    var assetType: String?
    var assetLink: URL? // the original URL of the asset
    var length: Int?
    
    var chapters: [Chapter] = []
    
    var podcast: Podcast?
    
    
    
    var playpostion: Double = 0.0
    var lastPlayed: Date?
    var finishedPlaying: Bool? = false
    var duration:Double?
    
    
    var isAvailableLocally:Bool = false
  
 
    //MARK: values that don't need to be stored
    
    @Transient var downloadStatus = EpisodeDownloadStatus()
    
    
    //MARK: calculated properties that a generated on the fly
    
  
    
    @Transient var localFile: URL?{
        let fileName = assetLink?.lastPathComponent ?? title?.appending(pubDate?.ISO8601Format() ?? Date().ISO8601Format())  ?? Date().ISO8601Format()
        let documentsDirectoryUrl =  FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        
        
        return documentsDirectoryUrl?.appendingPathComponent(fileName)
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
    
  
    @Transient var playPosition:Double{
        get{
            return playpostion
        }
        set{
           
                playpostion = newValue
                updateLastPlayed()
            
            
        }
    }
    
    var progress:Double {
        if let duration{
            return ((playPosition) / duration)
        }
        return 0.0
    }

    func updateLastPlayed(){
        self.lastPlayed = Date()
    }
    
    
    func updateDuration() async{
        print("updating Duration")
        if let localFile = localFile{
            if let duration = try? await AVAsset(url: localFile).load(.duration){
                setDuration(duration)
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
    init(details: [String: Any]) {
        title = details["itunes:title"] as? String ?? details["title"] as? String
        subtitle = details["itunes:subtitle"] as? String

        desc = details["description"] as? String
        guid = details["guid"] as? String
        
        duration = (details["itunes:duration"] as? String)?.durationAsSeconds

        link = URL(string: details["link"] as? String ?? "")
        pubDate = Date.dateFromRFC1123(dateString: details["pubDate"] as? String ?? "")
        image = URL(string: details["itunes:image"] as? String ?? "")
        
    
        number = details["itunes:episode"] as? String
        
        type = EpisodeType(rawValue: details["itunes:episodeType"] as? String ?? "unknown") ?? .unknown
        
        
      
        for assetDetails in details["enclosure"] as? [[String:Any]] ?? []{
            
            assetLink = URL(string: assetDetails["url"] as? String ?? "")// the original URL of the asset
            length = Int(assetDetails["length"] as? String ?? "")
            assetType = assetDetails["type"] as? String
 
        }
        
        var tempC:[Chapter] = []
        for chapterDetails in details["psc:chapters"] as? [[String:Any]] ?? []{
            let chapter = Chapter(details: chapterDetails)
            tempC.append(chapter)
        }
        chapters = tempC
        
    }
    

    
    static func ==(lhs: Episode, rhs: Episode) -> Bool {
        
        if lhs.podcast != rhs.podcast{
            return false
        }else{
            if lhs.link == rhs.link, lhs.link != nil{
                return true
            }else if lhs.number == rhs.number, lhs.number != nil, lhs.season == rhs.season{
                return true
            }else{
                return false
            }
        }
        

    }
    
    func markAsPlayed(){
      finishedPlaying = true
    }
    
    func markAsNotPlayed(){
        finishedPlaying = false
    }
    
  
    
    
}

