//  chapter.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData
import SwiftUI

enum ChapterType: String, Codable{
    case podlove
    case embedded
    case extracted
    case unknown
}
@Model
class Chapter{
    

    var uuid = UUID()
    var title: String = ""
    var link: URL?
    var image: URL?
    var start: Double?
    var duration: TimeInterval?
    var type : ChapterType = ChapterType.unknown
    
    var episode: Episode?
    var shouldPlay:Bool = true
    
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

       
        
        
        
        
    }

}
