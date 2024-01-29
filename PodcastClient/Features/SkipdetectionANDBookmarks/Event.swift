//
//  Skip.swift
//  PodcastClient
//
//  Created by Holger Krupp on 29.01.24.
//

import Foundation
import SwiftData

enum EventType: Codable {
    case skip, bookmark
}

@Model
class Event {
    

    
    var id = UUID()
    var start: Double?
    var end: Double?
    var episode: Episode?
    var date: Date = Date()
    var type: EventType?
    
    
    init(start: Double? = nil, end: Double? = nil, type: EventType? = EventType.skip){
        self.start = start
        self.end = end
        self.type = type
    }
}
