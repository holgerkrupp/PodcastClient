//
//  SubscriptionManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 02.12.23.
//

import Foundation
import SwiftData

enum elements:String, CaseIterable{
    case title, link, description, lastBuildDate, language, trash, pubDate
}


class PodcastParser:NSObject, XMLParserDelegate{

    var context:ModelContext?
    
    var podcast: Podcast?
    var episode:Episode?

    var currentElement:elements?
    var currentValue:String?
    var isHeader = true

    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
            Podcast.self,
            Episode.self,
            Chapter.self,
            Asset.self,
            PodcastSettings.self,
            Playlist.self
            
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    
    
    init(with modelID:PersistentIdentifier){
        super.init()
        print(modelID.id)
        if context == nil{
            context = ModelContext(sharedModelContainer)
        }
        if let context{
            podcast = context.model(for: modelID) as? Podcast
            
            print(podcast?.persistentModelID.id)
            
        }
    }
    
    
    func parserDidStartDocument(_ parser: XMLParser) {
        podcast?.isUpdating = true
    }
    
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
       print(elementName)
        
        if elementName == "item" {
            podcast?.save()
            isHeader = false
        }
        if let eCase = elements.init(rawValue: elementName) {
            currentElement = eCase
            currentValue = ""
        }
        
        if elementName == "item"{
            
            episode = Episode()

        }
    }
    
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {

        currentValue?.append(string)
    }
    
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {


        
        if isHeader{
            switch currentElement{
            case .title:
                podcast?.title = currentValue ?? ""
            case .link:
                podcast?.link = URL(string: currentValue ?? "")
            case .description:
                podcast?.desc = currentValue
            case .lastBuildDate:
                podcast?.lastBuildDate = Date.dateFromRFC1123(dateString: currentValue ?? "")
            case .language:
                podcast?.language = currentValue
            case .trash:
                break
            case .none:
                break
            case .some(.pubDate):
                break
            }
        }else{
            if let episode{
                switch currentElement{
                case .title:

                    episode.title = currentValue ?? ""
                case .link:
                    episode.link = URL(string: currentValue ?? "")
                case .description:
                    episode.desc = currentValue
                case .pubDate:
                    episode.pubDate = Date.dateFromRFC1123(dateString: currentValue ?? "")
                case .lastBuildDate:
                    break
                case .language:
                    break
                case .trash:
                    break
                case .none:
                    break
                }
             
            }
       
        }
        
        if elements.allCases.contains(where: { $0.rawValue == elementName }) {
            currentElement = nil
            // print(temp[currentElement ?? .trash] ?? "")
        }
        
        
        /* 
        
         switch back to header if the ended element is an "item"
        
         */
         if elementName == "item" {
             if let episode{
                 
                 podcast?.episodes.append(episode)
                 podcast?.save()
             }
            episode = nil
            isHeader = true
        }
        
        
        
        
        

    }
    func parserDidEndDocument(_ parser: XMLParser) {
        print("parser finished")

        print(podcast?.episodes.count)
        podcast?.isUpdating = false
        podcast?.save()
    }
    
}



class BackgroundDataHander {
    private var context: ModelContext
    
    init(with container: ModelContainer) {
        context = ModelContext(container)
    }
}
