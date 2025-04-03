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

struct Transcript:Codable{
    let url:String
    let type:String
    let source:String
}

class PodcastParser:NSObject, XMLParserDelegate{


    
    var episodeDict = [String: Any]()
    var chapterArray = [Any]()
    var transcriptArray = [Any]()
    var enclosureArray = [Any]()
    var episodesArray = [Any]()
    
    var attributes = [String:Any]()
    var podcastDictArr = [String: Any]()
    var tempDict = [String:Any]()
    
    var currentElements:[String] = []
    
    
    var currentElement:String {
        set {
            currentElements.append(newValue)
        }
        get{
            if let element = currentElements.last{
                return element
            }else{
                return ""
            }
           
        }
    }
    private var currentDepth:Int{
       return  currentElements.count
    }
    var currentValue = ""
    var isHeader:Bool {
        if currentDepth >= 3, currentElements[2] == "item"{
            return false
        }else{
            return true
        }
    }
    
    
    
    
    
    func parserDidStartDocument(_ parser: XMLParser)  {
        print("parserDidStartDocument")
        episodeDict.removeAll()
        enclosureArray.removeAll()
        episodesArray.removeAll()
        attributes.removeAll()
        podcastDictArr.removeAll()
        tempDict.removeAll()
        currentElements.removeAll()
        currentValue = ""
        transcriptArray.removeAll()
     
    }
    
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:])  {
       // print("\(qName ?? "") - \(namespaceURI) - \(elementName)")
        currentValue = ""
        currentElement = qName ?? elementName
        
        attributes.removeAll()
        

        
        if currentElement == "item" {
            // new PodcastEpisode found
         //   isHeader = false
            episodeDict = [:]
        }
        
        if currentElement == "psc:chapters"{
            chapterArray.removeAll()
        }
        /*
        if currentElement == "podcast:transcript"{
            if let url = attributeDict["url"] , let type = attributeDict["type"]{
                let newTranscript = Transcript(url: url, type: type, source: "feed")
                transcriptArray.append(newTranscript)
            
            }
            
        }
        */
        if currentDepth > 3, currentElements[2] == "image"{
            tempDict.updateValue(currentValue, forKey: currentElement)
        }
        
        if !attributeDict.isEmpty{
            

            
            if isHeader{
             
                if currentElement == "itunes:image"{
                    
                    currentValue = attributeDict["href"] ?? ""
                    
                    podcastDictArr.updateValue(currentValue, forKey: currentElement)
                    podcastDictArr.updateValue(currentValue, forKey: "coverImage")
                    
                }
          
                attributes = [elementName: attributeDict]
                podcastDictArr.updateValue(attributes, forKey: currentElement)
                

                

            }else{
                
                    
                    
                    switch qName ?? elementName{
                    case "psc:chapter": chapterArray.append(attributeDict)
                    case "enclosure": enclosureArray.append(attributeDict)
                    case "itunes:image": currentValue = attributeDict["href"] ?? ""
                    case "podcast:transcript":
                        if let url = attributeDict["url"] , let type = attributeDict["type"]{
                            let newTranscript = Transcript(url: url, type: type, source: "feed")
                            transcriptArray.append(newTranscript)
                        }
                    default:
                        break
                    }
                
            }
        }
    }
    
    
    func parser(_ parser: XMLParser, foundCharacters string: String)  {
        
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentValue += string
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?)  {
        
        
        switch isHeader{
        case true:

            
            if currentDepth > 3, currentElements[2] == "image"{
                
                tempDict.updateValue(currentValue, forKey: elementName)
                
            }else if currentDepth == 3, elementName == "image"{
                podcastDictArr.updateValue(tempDict, forKey: currentElement)
                tempDict.removeAll()
           
            }else{
                podcastDictArr.updateValue(currentValue, forKey: currentElement)
            }
            
        case false:
            // we are not in the header but somewhere deep in the elements belonging to an episode
            

                
                
                switch qName ?? elementName{
              
                    
                case "item":
                    //PodcastEpisode finished
                    //   isHeader = true // go back to header Level
                    episodeDict.updateValue(transcriptArray, forKey: "transcripts")
                    episodesArray.append(episodeDict) // add the episode dictionary to the Podcast Dictionary
                    enclosureArray.removeAll()
                    transcriptArray.removeAll()
                case "psc:chapters":
                    // list of chapters is finished
                    episodeDict.updateValue(chapterArray, forKey: currentElement) // add all chapters to the Episode
                    chapterArray.removeAll() // remove all chapters from the chapter Array
                case "encoded", "content:encoded":
                    // the content of the blogpost is in the item "content:encoded" to make it better readable, I'm using a dedicated case
                    episodeDict.updateValue(currentValue, forKey: "content")
                case "enclosure":
                    episodeDict.updateValue(enclosureArray, forKey: currentElement)

                default:
                    // add the value of the current Element to the Episode
                    episodeDict.updateValue(currentValue, forKey: currentElement)
                    
                }
            
        }
        if currentElements.count > 0{
            currentElements.removeLast()

        }
    }
    
    
    func parserDidEndDocument(_ parser: XMLParser)   {
        podcastDictArr.updateValue(episodesArray, forKey: "episodes")
    }

    
}

