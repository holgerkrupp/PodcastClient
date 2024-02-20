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
    var error: SubscriptionManager.SubscribeError?
    
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
                    
                    do {
                        let result = try await subscriptionManager.subscribe(to: url)
                        added = true // handle success case
                    } catch {
                        let errorString = "Error: \(error)"
                        self.error = error as? SubscriptionManager.SubscribeError
                        print(errorString)
                    }
                case 404:
                    added = false
                    self.error = SubscriptionManager.SubscribeError.loadfeed
                case 410:
                    if let newURL = self.status?.newURL{
                        
                        do {
                            let result = try await subscriptionManager.subscribe(to: newURL)
                            added = true // handle success case
                        } catch {
                            let errorString = "Error: \(error)"
                            print(errorString)
                            self.error = error as? SubscriptionManager.SubscribeError
                            // Handle failure case or print the error string
                        }
                        
                    }else{
                        added = false
                        self.error = SubscriptionManager.SubscribeError.loadfeed
                    }
                    
                default:
                    do {
                        let result = try await subscriptionManager.subscribe(to: url)
                        added = true // handle success case
                    } catch {
                        let errorString = "Error: \(error)"
                        self.error = error as? SubscriptionManager.SubscribeError
                        print(errorString)
                    }
                }
                
                
                
                return added
            }
        }else{
            self.error = SubscriptionManager.SubscribeError.loadfeed
            subscribing = false
            return nil
        }
        return nil
    }
    
}
