//
//  episode.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
class Episode{
    
    enum EpisodeType{
        case full, trailer, bonus
    }
    
    
    
    
    var title: String?
    var description: String?
    
    var guid: String?
    
    var link: URL?
    var pubDate: Date?
    
    var episodenumber: Int?
    var season: Int?
    
    var type: EpisodeType?
    
    var assets: [Asset]?
    var chapters: [Chapter]?
    
}
