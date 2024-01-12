//
//  StatisticsManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 12.01.24.
//

import Foundation

class StatisticEntry{
    enum EventType {
        case play
        case pause
        case crash
    }
    
    var date = Date()
    var type:EventType?
    var episode:Episode?
}

class StatisticsManager{
    
}
