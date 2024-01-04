//
//  extendedEpisode.swift
//  PodcastClient
//
//  Created by Holger Krupp on 04.01.24.
//

import Foundation
import AVFoundation
import SwiftUI

@Observable
class EpisodeModel{
    // This class is an extention to the Episode class. I did it this way to keep the SwiftData Class separated from the extended and computed variables that don't need to be stored in the database. There might be better solutions to do it, but this is my current approach. Feel free to suggest different ways
    
    
    var episode: Episode
    init(episode: Episode) {
        self.episode = episode
    }
    
    var downloadStatus = EpisodeDownloadStatus()
    
    // MARK: to access the relevant data from the original episode class, I reference them here
    
    var title: String? {
        episode.title
    }
    
    var desc: String?{
        episode.desc
    }
    var subtitle: String?{
        episode.subtitle
    }
    
    var guid: String?{
        episode.guid
    }
    
    var link: URL?{
        episode.link
    }
    var pubDate: Date?{
        episode.pubDate
    }
    
    var image: URL?{
        episode.image
    }
    
    var number: String?{
        episode.number
    }
    var season: String?{
        episode.season
    }
    
    var type: EpisodeType?{
        episode.type
    }
    
    var chapters: [Chapter] {
        episode.chapters
    }
    
    var podcast: Podcast?{
        episode.podcast
    }

    var asset:Asset?{
        return episode.assets?.first(where: {$0.type == .audio})
    }
    
    var playStatus: PlayStatus?{
        episode.playStatus
    }

    var duration: String?{
        episode.duration
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
    
    var playPosition:Double{
        get{
            if let playpostion = playStatus?.playpostion{
                return playpostion
            }else{
                episode.playStatus = PlayStatus()
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
        print("updating to \(seconds.description)")
        if !seconds.isNaN{
            episode.duration = secondsToHoursMinutesSeconds(seconds)
        }
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
    
    func updateDuration() async{
        print("updating Duration")
        if let localFile = localFile{
            if let duration = try? await AVAsset(url: localFile).load(.duration){
                setDuration(duration)
            }
        }
        
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
    
    
}
