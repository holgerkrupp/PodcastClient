//
//  podcast.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData

@Model
class Podcast{
    
    var feed: URL?
    
    var title: String = "podcast without title"
    var link: URL?
    var desc: String?

    var lastBuildDate:Date?
    var language:String?
    
    
    var settings: PodcastSettings?
    @Relationship(deleteRule: .cascade) var episodes: [Episode] = []
    
    
    var lastModified:Date?
    var lastRefresh:Date?
    
    var isUpdating:Bool = false{
        didSet {
            if isUpdating == false{
                save()
            }
        }
    }
    
    // MARK: computed properties

    var feedData:Data?{
        get async throws{
      
            
                if let feed{
                    let session = URLSession.shared
                    var request = URLRequest(url: feed)
                    if let appName = Bundle.main.applicationName{
                        request.setValue(appName, forHTTPHeaderField: "User-Agent")
                    }
                    do{
                        let (data, response) = try await session.data(for: request)
                        switch (response as? HTTPURLResponse)?.statusCode {
                        case 200:
                            return data
                        case .none:
                            return nil
                            
                        case .some(_):
                            return nil
                            
                        }
                    }catch{
                        print(error)
                        return nil
                    }
                }
                return nil
            }
        
    }
    
    
    var feedUpdated:Bool?{
        get async throws{
            if let lastModified{
                if let feed{
                    let session = URLSession.shared
                    var request = URLRequest(url: feed)
                    request.httpMethod = "HEAD"
                    if let appName = Bundle.main.applicationName{
                        request.setValue(appName, forHTTPHeaderField: "User-Agent")
                    }
                    do{
                        let (_, response) = try await session.data(for: request)
                        
                        if let feedLastModified = Date.dateFromRFC1123(dateString: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Last-Modified") ?? ""), feedLastModified > lastModified{
                            return true
                        }else{
                            return false
                        }
                    }catch{
                        print(error)
                        return nil
                    }
                }
            }else{
                return true // feed has never been fetched before therefore it's always new
            }

            return nil
        }
    }
    

    // MARK: init
    
    init?(with feed:URL) async{
            let session = URLSession.shared       
            var request = URLRequest(url: feed)
            request.httpMethod = "HEAD"
            if let appName = Bundle.main.applicationName{
                request.setValue(appName, forHTTPHeaderField: "User-Agent")
            }
            
        do{
            let (_, response) = try await session.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                self.lastModified = Date.dateFromRFC1123(dateString: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Last-Modified") ?? "")
                self.lastRefresh = Date.dateFromRFC1123(dateString: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date") ?? "") ?? Date()
                self.feed = feed
            case .none:
                return nil
                
            case .some(_):
                return nil
                
            }
        }catch{
            print(error)
            return nil
        }
    }
    
    // MARK: functions
    
    func refresh() async{
        isUpdating = true
        print("refresh \(self.persistentModelID.id)")
        do{
            if let data = try await feedData{
                
                isUpdating = false
                
                //podcast.feedData loads new data
                
                    let parser = XMLParser(data: data)
                    let podcastParser = PodcastParser(with: self.persistentModelID)
                    parser.delegate = podcastParser
                  
                    parser.parse()
                
            }else{
                print("could not load feedData")
            }
        }catch{
            print(error)
        }
    }
    
    func save(){
        if let moc = self.modelContext {
            do{
                try moc.save()
                print("saving \(title)")
            }catch{
                print("could not save")
                print(error)
            }
        }
    }

}


extension Podcast {
    @Observable
    class PodcastModel {
        var modelContext: ModelContext
        var podcasts = [Podcast]()
        
        init(modelContext: ModelContext) {
            self.modelContext = modelContext
            fetchData()
        }
        

        
        func fetchData() {
            do {
                let descriptor = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.title)])
                podcasts = try modelContext.fetch(descriptor)
            } catch {
                print("Fetch failed")
            }
        }
    }
}
