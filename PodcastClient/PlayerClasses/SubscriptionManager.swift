//
//  SubscriptionManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 27.12.23.
//

import Foundation

class SubscriptionManager:NSObject{
    
    static let shared = SubscriptionManager()
    
    private override init() {
        super.init()
    }
    
    func refresh(podcast: Podcast){
        Task{
            await podcast.refresh()
        }
    }
}
