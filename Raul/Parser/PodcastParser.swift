import Foundation
import SwiftData

enum elements:String, CaseIterable{
    case title, link, description, lastBuildDate, language, trash, pubDate
}



class PodcastParser:NSObject, XMLParserDelegate{
    
    var episodeDeepLinks: [String] = []

    var episodeDict = [String: Any]()
    var chapterArray = [Any]()
    var externalFilesArray = [Any]()
    
    
    var enclosureArray = [Any]()
    var episodesArray = [Any]()
    
    var attributes = [String:Any]()
    var podcastDictArr = [String: Any]()
    var tempDict = [String:Any]()
    
    var currentElements:[String] = []
    
    // RFC 5005 paged feed support URLs
    var nextPageURL: String?
    var prevPageURL: String?
    var firstPageURL: String?
    var lastPageURL: String?
    
    var podcastFundingArray = [[String: String]]()
    var episodeFundingArray = [[String: String]]()
    var podcastSocialArray = [[String: Any]]()
    var episodeSocialArray = [[String: Any]]()
    private var currentFundingURL: String = ""

    
    var podcastPeopleArray = [[String: Any]]()
    var episodePeopleArray = [[String: Any]]()
    private var currentPerson = [String: Any]()
    private var currentPersonName = ""
    
    private var currentSocial: [String: Any] = [:]
    
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
        // print("parserDidStartDocument")
        episodeDict.removeAll()
        episodeDeepLinks.removeAll()
        enclosureArray.removeAll()
        episodesArray.removeAll()
        attributes.removeAll()
        podcastDictArr.removeAll()
        tempDict.removeAll()
        currentElements.removeAll()
        currentValue = ""
        externalFilesArray.removeAll()
        
        nextPageURL = nil
        prevPageURL = nil
        firstPageURL = nil
        lastPageURL = nil
        
        podcastFundingArray.removeAll()
        episodeFundingArray.removeAll()
        podcastSocialArray.removeAll()
        episodeSocialArray.removeAll()
        currentSocial.removeAll()
        
        podcastPeopleArray.removeAll()
        episodePeopleArray.removeAll()
        currentPerson.removeAll()
        currentPersonName = ""
    }
    
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:])  {
       // // print("\(qName ?? "") - \(namespaceURI) - \(elementName)")
        currentValue = ""
        currentElement = qName ?? elementName
        
        // RFC 5005 paged feed support handling of atom:link rels
        if currentElement == "atom:link" {
            if let rel = attributeDict["rel"], let href = attributeDict["href"] {
                switch rel {
                case "next":
                    nextPageURL = href
                case "prev":
                    prevPageURL = href
                case "first":
                    firstPageURL = href
                case "last":
                    lastPageURL = href
                default:
                    break
                }
                
                if rel == "http://podlove.org/deep-link", !isHeader {
                    episodeDeepLinks.append(href)
                }
            }
        }
        
        if currentElement == "podcast:funding" {
            currentFundingURL = attributeDict["url"] ?? ""
            currentValue = ""
        } else {
            currentFundingURL = ""
        }
        
        if currentElement == "podcast:socialInteract" {
            // initialize with required attributes if present; we'll validate on end
            currentSocial = [:]
            if let proto = attributeDict["protocol"] { currentSocial["protocol"] = proto }
            if let uri = attributeDict["uri"] { currentSocial["uri"] = uri }
            if let accountId = attributeDict["accountId"] { currentSocial["accountId"] = accountId }
            if let accountUrl = attributeDict["accountUrl"] { currentSocial["accountUrl"] = accountUrl }
            if let priorityStr = attributeDict["priority"], let priorityInt = Int(priorityStr) {
                currentSocial["priority"] = priorityInt
            }
        } else if currentElement == "podcast:person" {
            currentPerson = [:]
            currentPersonName = ""
            if let role = attributeDict["role"] { currentPerson["role"] = role }
            if let href = attributeDict["href"] { currentPerson["href"] = href }
            if let img = attributeDict["img"] { currentPerson["img"] = img }
        } else if currentElement.hasPrefix("podcast:") == false {
            // do nothing
        }
        
        attributes.removeAll()
        

        
        if currentElement == "item" {
            // new PodcastEpisode found
         //   isHeader = false
            episodeDict = [:]
            episodeDeepLinks.removeAll()
            episodeFundingArray.removeAll()
            episodeSocialArray.removeAll()
            episodePeopleArray.removeAll()
        }
        
        if currentElement == "psc:chapters"{
            chapterArray.removeAll()
        }

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
                        if let url = attributeDict["url"] , let filetype = attributeDict["type"]{
                            let newTranscript = ExternalFile(url: url, category: .transcript, source: "feed", fileType: filetype)
                            externalFilesArray.append(newTranscript)
                        }
                    case "podcast:chapters":
                        if let url = attributeDict["url"] , let filetype = attributeDict["type"]{
                            let newFile = ExternalFile(url: url, category: .chapter, source: "feed", fileType: filetype)
                            externalFilesArray.append(newFile)
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
            if currentElement == "podcast:person" {
                currentPersonName += string
            }
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
                    episodeDict.updateValue(externalFilesArray, forKey: "transcripts") // to be removed in the future
                    episodeDict.updateValue(externalFilesArray, forKey: "externalFiles")
                    episodeDict.updateValue(episodeDeepLinks, forKey: "deepLinks")
                    if !episodeFundingArray.isEmpty {
                        episodeDict.updateValue(episodeFundingArray, forKey: "funding")
                        episodeFundingArray.removeAll()
                    }
                    if !episodeSocialArray.isEmpty {
                        episodeDict.updateValue(episodeSocialArray, forKey: "socialInteract")
                        episodeSocialArray.removeAll()
                    }
                    if !episodePeopleArray.isEmpty {
                        episodeDict.updateValue(episodePeopleArray, forKey: "people")
                        episodePeopleArray.removeAll()
                    }
                    episodeDeepLinks.removeAll()
                    episodesArray.append(episodeDict) // add the episode dictionary to the Podcast Dictionary
                    enclosureArray.removeAll()
                    externalFilesArray.removeAll()
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

        if elementName == "podcast:funding" {
            let fundingDict = ["url": currentFundingURL, "label": currentValue.trimmingCharacters(in: .whitespacesAndNewlines)]
            if isHeader {
                podcastFundingArray.append(fundingDict)
            } else {
                episodeFundingArray.append(fundingDict)
            }
            currentFundingURL = ""
        }
        if elementName == "podcast:socialInteract" {
            // Only append if required fields exist
            if let _ = currentSocial["protocol"], let _ = currentSocial["uri"] {
                if isHeader {
                    podcastSocialArray.append(currentSocial)
                } else {
                    episodeSocialArray.append(currentSocial)
                }
            }
            currentSocial.removeAll()
        }
        if elementName == "podcast:person" {
            let name = currentPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                var dict = currentPerson
                dict["name"] = name
                if isHeader {
                    podcastPeopleArray.append(dict)
                } else {
                    episodePeopleArray.append(dict)
                }
            }
            currentPerson.removeAll()
            currentPersonName = ""
        }

        if currentElements.count > 0{
            currentElements.removeLast()

        }
    }
    
    
    func parserDidEndDocument(_ parser: XMLParser)   {
        podcastDictArr.updateValue(episodesArray, forKey: "episodes")
        if !podcastFundingArray.isEmpty {
            podcastDictArr.updateValue(podcastFundingArray, forKey: "funding")
        }
        if !podcastSocialArray.isEmpty {
            podcastDictArr.updateValue(podcastSocialArray, forKey: "socialInteract")
        }
        if !podcastPeopleArray.isEmpty {
            podcastDictArr.updateValue(podcastPeopleArray, forKey: "people")
        }
    }

    
}


// MARK: - RFC 5005 Paged Feed Aggregation

extension PodcastParser {
    /// Fetches and aggregates all podcast data and episodes from all paged feed documents, following RFC 5005.
    /// - Parameter url: The URL of the first (or any) feed page.
    /// - Returns: The merged podcast dictionary with all episodes.
    static func fetchAllPages(from url: URL) async throws -> [String: Any] {
        print("fetching all pages from: \(url)")
        var nextURL: URL? = url
        var allEpisodes: [Any] = []
        var podcastHeader: [String: Any] = [:]
        var seenFirstHeader = false
        while let currentURL = nextURL {
            let (data, _) = try await URLSession.shared.data(from: currentURL)
            let parser = PodcastParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()
            // On the first page, get header
            if !seenFirstHeader {
                podcastHeader = parser.podcastDictArr
                seenFirstHeader = true
            }
            // Always append episodes
            if let episodes = parser.podcastDictArr["episodes"] as? [Any] {
                
                allEpisodes.append(contentsOf: episodes)
            }
            // Advance to next page if present
            if let nextString = parser.nextPageURL, let next = URL(string: nextString, relativeTo: currentURL) {
                nextURL = next.absoluteURL
            } else {
                nextURL = nil
            }
        }
        // Merge all episodes
        podcastHeader["episodes"] = allEpisodes
        return podcastHeader
    }
}

