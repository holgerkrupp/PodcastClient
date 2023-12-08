//
//  episode.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData


enum EpisodeType: Codable{
    case full, trailer, bonus
}

@Model
class Episode{
    
    var title: String?
    var desc: String?
    
    var guid: String?
    
    var link: URL?
    var pubDate: Date?
    
    var episodenumber: Int?
    var season: Int?
    
    var type: EpisodeType?
    
    var assets: [Asset]?
    var chapters: [Chapter] = []
    var skipps: [Skip] = [] // the idea is that if a part of the episode is skipped over accidentally (phone in pocket, kid slides the progress,…) this is recorded and can be undone.
    
    init(){}

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
