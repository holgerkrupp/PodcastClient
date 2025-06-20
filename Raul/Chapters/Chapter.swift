//  chapter.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData
import SwiftUI

enum ChapterType: String, Codable, Comparable{
    static func < (lhs: ChapterType, rhs: ChapterType) -> Bool {
        lhs.desc < rhs.desc
    }
    
    case podlove
    case mp4
    case extracted
    case unknown
    case mp3
    
    var desc:String{
        
        switch self {
        case .podlove:
            "Podlove"
        case .mp3:
            "mp3"
        case .mp4:
            "mp4"
        case .extracted:
            "Shownotes"
        case .unknown:
            "unknown"
        }
        
    }
    
    
}
@Model
class Chapter: Identifiable, Equatable, Hashable{
    
    
    var id = UUID()
    var title: String = ""
    var link: URL?
    var image: URL?
    var imageData:Data?
    var start: Double?
    var endTime: Double?
    var duration: TimeInterval?
    
    var progress:Double? // 0 -1 
    
    @Transient var remainingTime: TimeInterval? {
        guard let duration = duration, let progress = progress else { return nil }
        return max(0, duration * (1 - progress))
    }
    
    @Transient var end:Double? {
        let end = ((start ?? 0) + (duration ?? 0))
        if end > 0{
            return end
        }else{
            return nil
        }
    }
    
    
    var type : ChapterType = ChapterType.unknown
    
    var episode: Episode?
    var shouldPlay:Bool = true
    
    
    @Transient var didSkip:Bool = false
    
    
 
    
    
    init(){}
    
    init(details: [String: Any]) {
        title = details["title"] as? String ?? ""
        start = (details["start"] as? String)?.durationAsSeconds
        endTime = (details["endTime"] as? Double)
        if let endTime, let start{
            duration = endTime - start
        }
        
        link = URL(string: details["href"] as? String ?? "")
        image = URL(string: details["image"] as? String ?? "")
        if let imagedata = (details["APIC"] as? [String:Any])?["Data"] as? Data{
            print("ImageChapter with Image data")
            imageData = imagedata
        }
        type = .podlove
        
    }
    
    init(start: Double, title: String, type: ChapterType? = .unknown, imageData: Data? = nil, duration: TimeInterval? = nil){
        self.start = start
        self.title = title
        self.type = type ?? .unknown
        self.imageData = imageData
        self.duration = duration
        if let duration{
            self.endTime = start + duration
        }
        
        print("init Chapter \(title)")
    }
    
    static func ==(lhs: Chapter, rhs: Chapter) -> Bool {
        
        if lhs.episode != rhs.episode, lhs.episode != nil{
            return false
        }else if lhs.type != rhs.type{
            return false
        }else if lhs.id == rhs.id{
            return true
        }else{
            return false
        }
        
        
    }
    func hash(into hasher: inout Hasher) {
        
        hasher.combine(id)
    }
}
