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
    
    
var description:String {
    switch self {
    case .skip:
        return "Skip"
    case .bookmark:
        return "Bookmark"
    }
}
    

    
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
    
    @Transient var duration:Double{
        return abs((start ?? 0) - (end ?? 0))
    }
    
    @Transient var directionImage:String{
        if self.start ?? 0 > self.end ?? 0{
            return "arrow.backward"
        }else{
            return "arrow.forward"
        }
    }
        @Transient var description:String{
            if type == .skip{
                if self.start ?? 0 > self.end ?? 0{
                    return "Skip of \(duration.secondsToHoursMinutesSeconds) back detected"
                }else{
                    return "Skip of \(duration.secondsToHoursMinutesSeconds) forwward detected"
                }
            }else{
                return type?.description ?? ""
            }
        }
    
}
