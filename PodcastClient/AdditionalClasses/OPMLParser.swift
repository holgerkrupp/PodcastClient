//
//  OPMLParser.swift
//  PodcastClient
//
//  Created by Holger Krupp on 05.01.24.
//

import Foundation



class OPMLParser: NSObject, XMLParserDelegate{
    var podcastFeeds: [PodcastFeed] = []
    
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        
        print("OPML Parser started: \(elementName)")
        
        let currentElement = elementName.lowercased()

        switch currentElement {
        case "opml":
            return
        case "outline":
            print("outline attributes: \(attributeDict)")
            if attributeDict["type"] == "rss"{
                var newPodcast = PodcastFeed()
                
                newPodcast.title = attributeDict["text"]
                
                if let feedURL = URL(string: attributeDict["xmlUrl"] ?? ""){
                    newPodcast.url = feedURL
                }
                
                podcastFeeds.append(newPodcast)
            }

            
        default:
            return
        }
    }
    
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        
        print("OPML Parser ended: \(elementName)")
        switch elementName.lowercased() {
        case "outline":
            return
        default:
            return
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        
    }
    
    
}

