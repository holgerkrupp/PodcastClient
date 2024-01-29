//
//  Skip.swift
//  PodcastClient
//
//  Created by Holger Krupp on 29.01.24.
//

import Foundation
import SwiftData

@Model
class Skip {
    var id = UUID()
    var start: Double?
    var end: Double?
    var episode: Episode?
    var date: Date = Date()
    
    init(start: Double, end: Double){
        self.start = start
        self.end = end
    }
}
