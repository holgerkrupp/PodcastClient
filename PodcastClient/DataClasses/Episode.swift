//
//  episode.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData
import SwiftUI
import AVFoundation


enum EpisodeType: String, Codable{
    case full, trailer, bonus, unknown
}

@Model
class Episode: Equatable, Hashable{
    
    //MARK: Values to be storred in the database
    var id = UUID()
    var title: String?
    var desc: String?
    var subtitle: String?
    var content: String?
    
    var guid: String?
    
    var link: URL?
    var pubDate: Date?
    
    var image: URL?
    var cover:Data?

    
    var number: String?
    var season: String?
    
    var type: EpisodeType = EpisodeType.unknown
    

    var assetType: String?
    var assetLink: URL? // the original URL of the asset
    var length: Int?
    var transcriptURL: [URL]?
    var transcripts:[Transcript]?
    
    @Relationship(deleteRule: .cascade, inverse: \Chapter.episode)  var chapters: [Chapter]?
    
    var podcast: Podcast?
    var skips: [Skip]?
    var playlistentries: [PlaylistEntry]?
    
    var playpostion: Double = 0.0
    var lastPlayed: Date?
    var finishedPlaying: Bool? = false
    var duration:Double?
    
    
    var isAvailableLocally:Bool = false
  
 
    //MARK: values that don't need to be stored
    
    @Transient var downloadStatus = EpisodeDownloadStatus()
    
    
    //MARK: calculated properties that a generated on the fly
    
  
    
    @Transient var localFile: URL?{
        let fileName = assetLink?.lastPathComponent ?? title ?? pubDate?.ISO8601Format() ?? Date().ISO8601Format()
        let documentsDirectoryUrl = podcast?.directoryURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return documentsDirectoryUrl?.appendingPathComponent(fileName).standardizedFileURL
    }
    
    func UpdateisAvailableLocally() -> Bool?{
        
        if let localFile = localFile?.path() {
            let manager = FileManager()
            isAvailableLocally = true
            return  manager.fileExists(atPath: localFile)
        }else{
            isAvailableLocally = false
            return false
        }
    }
    
 
    
    @Transient var avAsset:AVAsset?{
        print("avAsset read - \(localFile?.absoluteString) - \(isAvailableLocally)")
        if let url = localFile, isAvailableLocally{
            return AVAsset(url: url)
        }else{
            print("avAsset remote - \(assetLink?.absoluteString)")

            if let remoteURL = assetLink{
                return AVAsset(url: remoteURL)
            }
        }
        return nil
    }
    
    
    
    
    @Transient var coverImage: some View{
        
        if let imageURL = image{
            return AnyView(ImageWithURL(imageURL))
        }else if let podcastcover = podcast?.coverURL{
            return AnyView(ImageWithURL(podcastcover))
        }else{
            return AnyView(Image(systemName: "mic.fill"))
        }
         
    }
    
    
    @Transient var uiimage: UIImage{
    
        if let cover{
            return ImageWithData(cover).uiImage()
        }else if let cover = podcast?.cover{
            return ImageWithData(cover).uiImage()
        }else{
            return UIImage(systemName: "photo") ?? UIImage()
        }
    }
    
  
    @Transient var playPosition:Double{
        get{
            return playpostion
        }
        set{
           
                playpostion = newValue
                updateLastPlayed()
            
            
        }
    }
    
    var progress:Double {
        if let duration{
            return ((playPosition) / duration)
        }
        return 0.0
    }

    func updateLastPlayed(){
        self.lastPlayed = Date()
    }
    
    func postProcessingAfterDownload() async{
        print("postProcessing")
        await updateDuration()
        if let localFile{
            let fileChapters = await loadChaptersFromAsset(with: localFile) ?? []
            chapters?.append(contentsOf: fileChapters)
        }

    }
    
    func updateDuration() async{
        print("updating Duration")
        if let localFile = localFile{
            do{
                
                let duration = try await AVAsset(url: localFile).load(.duration)
                print (duration.seconds)
               setDuration(duration)
                
            }catch{
                print(error)
            }
        }
    }
    func setDuration(_ duration: CMTime) {
        
        let seconds = CMTimeGetSeconds(duration)
        print("updating to \(seconds.description)")
        
        if !seconds.isNaN{
            self.duration = seconds
        }
         
    }

    
    func playNow(){
        
        Player.shared.setCurrentEpisode(episode: self, playDirectly: true)
    }
    
    
    func download(){
        print("episode download")
        Task{
            do{
                try await DownloadManager.shared.download(self)
            }catch{
                print(error)
            }
        }
        
    }
    
    func removeFile(){
        print("removing localFile")
        downloadStatus.update(currentBytes: 0, totalBytes: 0)
        
        if let file = localFile{
            try? FileManager.default.removeItem(at: file)
            isAvailableLocally = false
        }
    }
    
    

    //MARK: INIT
    init(details: [String: Any], podcast:Podcast?) async {
        guid = details["guid"] as? String
        title = details["itunes:title"] as? String ?? details["title"] as? String
    
       // print("Episode \(id) - \(guid) - \(title)")
        
        
        subtitle = details["itunes:subtitle"] as? String

        desc = details["description"] as? String
        
        content = details["content"] as? String
        
        duration = (details["itunes:duration"] as? String)?.durationAsSeconds

        link = URL(string: details["link"] as? String ?? "")
        pubDate = Date.dateFromRFC1123(dateString: details["pubDate"] as? String ?? "")
        image = URL(string: details["itunes:image"] as? String ?? "")
    
        /* THIS TAKES TO MUCH TIME WHILE SUBSCRIBING TO FEEDS
        if let image{
            cover = await image.downloadData()
        }
    */
        number = details["itunes:episode"] as? String
        
        type = EpisodeType(rawValue: details["itunes:episodeType"] as? String ?? "unknown") ?? .unknown
        
        //self.podcast = podcast
      
        for assetDetails in details["enclosure"] as? [[String:Any]] ?? []{
            
            assetLink = URL(string: assetDetails["url"] as? String ?? "")// the original URL of the asset
            length = Int(assetDetails["length"] as? String ?? "")
            assetType = assetDetails["type"] as? String
 
        }
        
        for transcript in details["transcripts"] as? [Transcript] ?? []{
            transcripts?.append(transcript)
        }
        
        var tempC:[Chapter] = []
        for chapterDetails in details["psc:chapters"] as? [[String:Any]] ?? []{
            let chapter = Chapter(details: chapterDetails)
            tempC.append(chapter)
        }
        chapters = tempC
        

        
    }
    
    
    static func ==(lhs: Episode, rhs: Episode) -> Bool {

        if lhs.podcast != rhs.podcast{
            return false
        }else if lhs.guid == rhs.guid, lhs.guid != nil, lhs.guid != ""{
            return true
        }else{
            if lhs.assetLink == rhs.assetLink, lhs.assetLink != nil{
                return true
            }else if lhs.number == rhs.number &&  lhs.number != nil && lhs.season == rhs.season{
                return true
            }else if lhs.id == rhs.id{
                return true
            }else{
                
                return false
            }
        }
        

    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(guid)
        hasher.combine(assetLink)
        hasher.combine(podcast)
        hasher.combine(title)
        hasher.combine(id)
    }
    
    func markAsPlayed(){
      finishedPlaying = true
    }
    
    func markAsNotPlayed(){
        finishedPlaying = false
    }
    
    
    func createChapters(from text: String) -> [Chapter]{
        let extractedData = extractTimeCodesAndTitles(from: text)
        var newchapters:[Chapter] = []
        for extractedChapter in extractedData{
            if let startingTime =  extractedChapter.key.durationAsSeconds{
                print("chapter at \(extractedChapter.key) : \(extractedChapter.value) -- \(startingTime.formatted())")
                let newChapter = Chapter(start: startingTime, title: extractedChapter.value, type: .extracted)
                newchapters.append(newChapter)
            }
        }
        return newchapters
    }
    /*
    func extractTimeCodesAndTitles(from text: String) -> [String: String] {
        var result = [String: String]()
        
        let regex = try! NSRegularExpression(pattern: "\\d{2}:\\d{2}:\\d{2} (.+?)(?=\\n\\d{2}:\\d{2}:\\d{2}|\\n\\z)", options: .dotMatchesLineSeparators)
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        
        for match in matches {
            if let titleRange = Range(match.range(at: 1), in: text),
               let timeCodeRange = Range(match.range, in: text) {
                let title = String(text[titleRange])
                let timeCode = String(text[timeCodeRange].split(separator: " ")[0]) // Only take the time code part
                result[timeCode] = title
            }
        }
        
        return result
    }
    */
    func extractTimeCodesAndTitles(from htmlEncodedText: String) -> [String: String] {
        var result = [String: String]()
        
        let regex = try! NSRegularExpression(pattern: "\\d{2}:\\d{2}:\\d{2} (.+?)(?=<br>|</p>|<!--.*?-->|\\n\\d{2}:\\d{2}:\\d{2}|\\n\\z)", options: .dotMatchesLineSeparators)
        let matches = regex.matches(in: htmlEncodedText, options: [], range: NSRange(location: 0, length: htmlEncodedText.utf16.count))
        
        for match in matches {
            if let titleRange = Range(match.range(at: 1), in: htmlEncodedText),
               let timeCodeRange = Range(match.range, in: htmlEncodedText) {
                let title = String(htmlEncodedText[titleRange])
                let timeCode = String(htmlEncodedText[timeCodeRange].split(separator: " ")[0]) // Only take the time code part
                result[timeCode] = title.decodeHTML() ?? title
            }
        }
        
        return result
    }
  
    func loadChaptersFromAsset(with assetUrl: URL) async -> [Chapter]?{
        print("loading Chapters from Asset with \(assetUrl.absoluteString)")
        let asset = AVAsset(url: assetUrl)
        let chapterLocalesKey = "availableChapterLocales"
        var chapters: [Chapter] = []
        let metadata = try? await asset.load(.metadata)
        if (metadata != nil){
            
            
            
            let languages = Locale.preferredLanguages
            if let chapterMetadataGroups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages) {
                for group in chapterMetadataGroups {
                    
                    guard let titleItem = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
                          let title = try? await titleItem.load(.value) as? String else {
                        continue
                    }
                    
                    let artworkData = try? await group.items.first(where: { $0.commonKey == .commonKeyArtwork })?.load(.value) as? Data
                    
                    let timeRange = group.timeRange
                    let start = timeRange.start.seconds
                    let end = timeRange.end.seconds
                    let duration = timeRange.duration.seconds
                    
                    // Validate the time fields for NaN and negative values
                    let correctedStart = (start.isNaN || start < 0) ? 0 : start
                    let correctedEnd = (end.isNaN || end < 0) ? 0 : end
                    let correctedDuration = (duration.isNaN || duration < 0) ? nil : duration
                    
                    let newChaper = Chapter()
                    newChaper.title = title
                    newChaper.start = correctedStart
                    newChaper.duration = correctedDuration
                    newChaper.type = .embedded
                    newChaper.imageData = artworkData
                    chapters.append(newChaper)
                }
            }
            print("returning \(chapters.count.formatted()) Chapters")
            return chapters
        }
        print("returning nil")
        return nil

    }
    
    
}

