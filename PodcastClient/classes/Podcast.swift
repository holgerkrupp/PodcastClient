//
//  podcast.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation


class Podcast{
    
    var feed: URL?
    
    var title: String?
    
    var description: String?
    
    var link: URL?
    
    var settings: PodcastSettings?
    
    
    var episodes: [Episode]?
    
}
