//
//  SubscriptionManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 02.12.23.
//

import Foundation
import SwiftData

class SubscriptionManager:NSObject
{
    var podcast: Podcast?
    
    func parse(){
        if let feed = podcast?.feed{
            
        }
    }
    
    
}




class BackgroundDataHander {
    private var context: ModelContext
    
    init(with container: ModelContainer) {
        context = ModelContext(container)
    }
}
