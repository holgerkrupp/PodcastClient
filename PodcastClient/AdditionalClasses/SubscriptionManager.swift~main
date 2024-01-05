//
//  SubscriptionManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 27.12.23.
//

import Foundation
import SwiftData

class SubscriptionManager:NSObject{
    
    static let shared = SubscriptionManager()
    var modelContext: ModelContext?
    var podcasts : [Podcast]?
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: false)
    
    

    
    private override init() {
        super.init()
        if let container = try? ModelContainer(
            for: Podcast.self,
            configurations: configuration
        ){
            modelContext = ModelContext(container)
            fetchData()
        }
    }
    
    func refresh(podcast: Podcast){
        Task{
            await podcast.refresh()
        }
    }
    
    func refreshall() async{
        if let podcasts{
            for podcast in podcasts{
                await podcast.refresh()
            }
        }

    }

    func fetchData() {
        do {
            let descriptor = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.title)])
            podcasts = try modelContext?.fetch(descriptor)
        } catch {
            print("Fetch failed")
        }
    }
    
}
