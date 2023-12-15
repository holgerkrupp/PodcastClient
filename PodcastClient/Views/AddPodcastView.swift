//
//  AddPodcastView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 08.12.23.
//

import SwiftUI

struct AddPodcastView: View {
    @Environment(\.modelContext) var modelContext

    @State var newFeed:String = "https://hierisauch.net/feed/test/"
    
    var parserDelegate = PodcastParser()
    
    
    var body: some View {
       
            TextField(text: $newFeed) {
                Text("paste URL to feed")
            }
            Button {
                
                if let feed {
                    Task{
                        if let data = try? await feedData{
                            loadPodcast(data: data)
                        }
                        
                    }
                    
                    
                }
                
            } label: {
                Text("Subscribe")
            }
            .disabled(URL(string: newFeed) == nil)
            
            
        
    }
    
    func loadPodcast(data: Data){
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = true
        parser.delegate = parserDelegate
        if parser.parse(){
     
            if let feedDetail = (parser.delegate as? PodcastParser)?.podcastDictArr {
                let podcast = Podcast(details: feedDetail)
                modelContext.insert(podcast)
                
            }
            /*
            for feedDetail in (parser.delegate as? PodcastParser)?.podcastDictArr ?? [] {
                Podcast(details: feedDetail)
                
                
            }
            */
            
            //  Podcast(details: (parser.delegate as? PodcastParser)?.xmlDictArr as [String:Any])
         /*
            if let feedDetail = (parser.delegate as? PodcastParser)?.podcastDictArr.first{
                Podcast(details: feedDetail)
            }
           */
            //   dump((parser.delegate as? PodcastParser)?.xmlDictArr)
        }
    }
    
    
    var feed:URL?{
        URL(string: newFeed.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
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
    
    
}

#Preview {
    AddPodcastView()
}
