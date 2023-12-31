//  chapter.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData


@Model
class Chapter{
    
    var title: String = ""
    var link: URL?
    var image: URL?
    var start: String?
    var duration: TimeInterval?
    var episode: Episode?
    var shouldPlay:Bool = true
    
    init(){}
    
    init(details: [String: Any]) {
        title = details["title"] as? String ?? ""
        start = details["start"] as? String

        
        link = URL(string: details["href"] as? String ?? "")
        image = URL(string: details["image"] as? String ?? "")

       
        
        
        
        
    }

}
