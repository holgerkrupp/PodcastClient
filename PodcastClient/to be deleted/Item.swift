//
//  Item.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
