//
//  episode.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData


enum EpisodeType: String, Codable{
    case full, trailer, bonus, unknown
}

@Model
class Episode{
    
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
    
    var assets: [Asset]?
    var chapters: [Chapter] = []
    
    var asset:Asset?{
        return assets?.first(where: {$0.type == .audio})
    }
    
    
    var skipps: [Skip] = [] // the idea is that if a part of the episode is skipped over accidentally (phone in pocket, kid slides the progress,…) this is recorded and can be undone.
    var playpostion: Int?
    
    
    
    init(){}

    init(details: [String: Any]) {
        title = details["itunes:title"] as? String ?? details["title"] as? String
        subtitle = details["itunes:subtitle"] as? String

        desc = details["description"] as? String
        guid = details["guid"] as? String

        link = URL(string: details["link"] as? String ?? "")
        pubDate = Date.dateFromRFC1123(dateString: details["pubDate"] as? String ?? "")
        image = URL(string: details["itunes:image"] as? String ?? "")
        
    
        number = details["itunes:episode"] as? String
        
        type = EpisodeType(rawValue: details["itunes:episodeType"] as? String ?? "unknown")
        
        
        var tempA:[Asset] = []
        for assetDetails in details["enclosure"] as? [[String:Any]] ?? []{
            let asset = Asset(details: assetDetails)
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
