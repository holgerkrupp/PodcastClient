//
//  NewFeed.swift
//  PodcastClient
//
//  Created by Holger Krupp on 17.02.24.
//

import Foundation
@Observable
class PodcastFeed: Hashable{
    static func == (lhs: PodcastFeed, rhs: PodcastFeed) -> Bool {
        return lhs.url == rhs.url
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        
    }
    
    var title: String?
    var subtitle: String?
    var description: String?


    var url: URL?
    var existing: Bool = false
    var added: Bool = false
    var subscribing: Bool = false
    var status: URLstatus?
    
    var artist: String?
    var artworkURL: URL?
    var lastRelease: Date?
    
    

    
    func subscribe() async -> Bool?{
        
        subscribing = true
        if let url{
            Task{
                let subscriptionManager = SubscriptionManager.shared
                subscribing = true
                status = try? await url.status()
                print("\(status?.statusCode?.formatted() ?? "STATUSCODE") - \(status?.doctype ?? "DOCTYPE")")
                switch status?.statusCode {
                case 200:
                    added = await subscriptionManager.subscribe(to: url)
                case 404:
                    added = false
                case 410:
                    if let newURL = status?.newURL{
                        added = await subscriptionManager.subscribe(to: newURL)
                    }else{
                        added = false
                    }
                    
                default:
                    added = await subscriptionManager.subscribe(to: url)
                }
                
                
                
                return added
            }
        }else{
            
            subscribing = false
            return nil
        }
        return nil
    }
    
}
