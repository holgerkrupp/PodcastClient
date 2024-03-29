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
    case embedded
    case extracted
    case unknown
    
    var desc:String{
        
        switch self {
        case .podlove:
            "Podlove"
       
        case .embedded:
            "File"
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
    var duration: TimeInterval?
    
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
    @Transient var coverImage: some View{
        
        if let imageURL = image{
            return AnyView(ImageWithURL(imageURL))
        }else {
            return AnyView(episode?.coverImage)
        }
        
    }
    
    
    init(){}
    
    init(details: [String: Any]) {
        title = details["title"] as? String ?? ""
        start = (details["start"] as? String)?.durationAsSeconds
        
        link = URL(string: details["href"] as? String ?? "")
        image = URL(string: details["image"] as? String ?? "")
        type = .podlove
        
    }
    
    init(start: Double, title: String, type: ChapterType, imageData: Data? = nil){
        self.start = start
        self.title = title
        self.type = type
        self.imageData = imageData
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
