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

enum Direction:Codable{
    case backward, forward
}

struct Skip:Codable{
    var start:Float?
    var end:Float?
    var direction: Direction? // maybe not needeed as the start and end of the skip should already give the direction
    var eventDate: Date? // the time when the skip happened
    
}

@Model
class PlayStatus{
    var skipps: [Skip]? // the idea is that if a part of the episode is skipped over accidentally (phone in pocket, kid slides the progress,…) this is recorded and can be undone.
    var playpostion: Double = 0.0
    var lastPlayed: Date?
    var episode: Episode?
    init(){}
}




@Model
class Episode: Equatable{
    
    var title: String?
    var desc: String?
    var subtitle: String?
    
    var guid: String?
    
    var link: URL?
    var pubDate: Date?
    
    var image: URL?
    
    var number: String?
    var season: String?
    
    var type: EpisodeType?
    
    var chapters: [Chapter] = []
    
    var podcast: Podcast?

    private var assets: [Asset]?
    var asset:Asset?{
        return assets?.first(where: {$0.type == .audio})
    }
    
    var avAsset:AVAsset?{
        if let url = localFile, isAvailableLocally{
           return AVAsset(url: url)
        }else{
            if let remoteURL = asset?.link{
             return AVAsset(url: remoteURL)
            }
        }
        return nil
    }
    
    
    
    
    @Relationship(deleteRule: .cascade, inverse: \PlayStatus.episode) private var playStatus: PlayStatus?
    var playPosition:Double{
        get{
            if let playpostion = playStatus?.playpostion{
                return playpostion
            }else{
                self.playStatus = PlayStatus()
                return 0.0
            }
        }
        set{
            self.playStatus?.playpostion = newValue
            updateLastPlayed()
        }
    }
    
    var progress:Double {
        if let double = durationAsDouble{
            return ((playPosition) / double)
        }
        return 0.0
    }
    
    
    
    var lastPlayed:Date?{
        get{
            if let lastPlayed = playStatus?.lastPlayed{
                return lastPlayed
            }else{
                return nil
            }
        }
        set{
            self.playStatus?.lastPlayed = newValue
        }
    }
    
    func updateLastPlayed(){
        self.lastPlayed = Date()
    }
    
    
    
    
    

    
    
    
    
    
    
    
    var length:Int?{
        return asset?.length
    }
    
    var duration:String?
    
    var durationAsDouble:Double?{
        
        if let timeArray = duration?.components(separatedBy: ":"){
            var seconds = 0.0
            
            for element in timeArray{
                if let double = Double(element){
                    seconds = (seconds + double) * 60
                }
            }
            seconds = seconds / 60
            return seconds
        }
        return nil
        
    }
    
    func setDuration(_ duration: CMTime) {
        let seconds = CMTimeGetSeconds(duration)
        if !seconds.isNaN{
            self.duration = secondsToHoursMinutesSeconds(seconds)
        }
    }
    
    private func secondsToHoursMinutesSeconds (_ seconds : Double) -> (String) {
        let (hr,  minf) = modf (seconds / 3600)
        let (min, secf) = modf (60 * minf)
        let rh = hr
        let rm = min
        let rs = 60 * secf

        var returnstring = String()
        if rh != 0 {
            returnstring = NSString(format: "%02.0f:%02.0f:%02.0f", rh,rm,rs) as String
        }else {
            returnstring = NSString(format: "%02.0f:%02.0f", rm,rs) as String
        }
        return returnstring
    }
    
 
    var isAvailableLocally:Bool{
        
        if let localFile = localFile?.path() {
            let manager = FileManager()
            print("existing")
            return  manager.fileExists(atPath: localFile)
        }else{
            print("not existing")
            return false
        }
    }
    
    var localFile: URL?{
        let fileName = asset?.link?.lastPathComponent ?? title?.appending(pubDate?.ISO8601Format() ?? Date().ISO8601Format())  ?? Date().ISO8601Format()
        let documentsDirectoryUrl =  FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

       
        return documentsDirectoryUrl?.appendingPathComponent(fileName)
    }
    
    var coverImage: some View{
        if let imageURL = image{
            return AnyView(ImageWithURL(imageURL))
        }else if let podcastcover = podcast?.coverURL{
            return AnyView(ImageWithURL(podcastcover))
        }else{
            return AnyView(Image(systemName: "mic.fill"))
        }
    }
    
    @Transient var isDownloading: Bool = false
    @Transient private(set) var currentBytes: Int64 = 0
    @Transient private(set) var totalBytes: Int64 = 0
    @Transient var downloadProgress: Double {
        guard totalBytes > 0 else { return 0.0 }
        
        return Double(currentBytes) / Double(totalBytes)
    }
    
    
    
    func update(currentBytes: Int64, totalBytes: Int64) {
        print(Double(currentBytes) / Double(totalBytes))
        self.currentBytes = currentBytes
        self.totalBytes = totalBytes
    }
    
    func updateDuration() async{
        if let localFile = localFile{
            if let duration = try? await AVAsset(url: localFile).load(.duration){
                setDuration(duration)
            }
        }
        
    }


    init(details: [String: Any]) {
        title = details["itunes:title"] as? String ?? details["title"] as? String
        subtitle = details["itunes:subtitle"] as? String

        desc = details["description"] as? String
        guid = details["guid"] as? String
        
        duration = details["itunes:duration"] as? String

        link = URL(string: details["link"] as? String ?? "")
        pubDate = Date.dateFromRFC1123(dateString: details["pubDate"] as? String ?? "")
        image = URL(string: details["itunes:image"] as? String ?? "")
        
    
        number = details["itunes:episode"] as? String
        
        type = EpisodeType(rawValue: details["itunes:episodeType"] as? String ?? "unknown")
        
        
        var tempA:[Asset] = []
        for assetDetails in details["enclosure"] as? [[String:Any]] ?? []{
            let asset = Asset(details: assetDetails)
            if asset.title == nil{
                asset.title = self.title
            }
            tempA.append(asset)
        }
        assets = tempA
        
        var tempC:[Chapter] = []
        for chapterDetails in details["psc:chapters"] as? [[String:Any]] ?? []{
            let chapter = Chapter(details: chapterDetails)
            tempC.append(chapter)
        }
        chapters = tempC
        
    }
    
    func download(){
        print("start download \(title) to \(localFile)")
        Task{
            try? await DownloadManager.shared.download(self)
        }

    }
    
    func removeFile(){
        print("removing localFile")
        if let file = localFile{
            try? FileManager.default.removeItem(at: file)
        }
    }
    
    static func ==(lhs: Episode, rhs: Episode) -> Bool {
        
        if lhs.link == rhs.link, lhs.link != nil{
            return true
        }else if lhs.number == rhs.number, lhs.number != nil, lhs.season == rhs.season{
            return true
        }else{
            return false
        }
    }
    
  
    
    
}

