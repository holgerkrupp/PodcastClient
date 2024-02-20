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
    var decodedContent: String?
    
    var guid: String?
    
    var link: URL?
    var pubDate: Date?
    
    var image: URL?
    @Attribute(.externalStorage) var cover:Data?

    
    var number: String?
    var season: String?
    
    var type: EpisodeType = EpisodeType.unknown
    

    var assetType: String?
    var assetLink: URL? // the original URL of the asset
    var length: Int?
   
    var transcripts:[Transcript] = []
    var transcriptData:String?
    
    @Relationship(deleteRule: .cascade, inverse: \Chapter.episode)  var chapters: [Chapter]?
    var playlists: [PlaylistEntry]? = []
    
    var podcast: Podcast?
    var events: [Event]?
 
    
   // var playpostion: Double = 0.0
    var playPosition:Double?  = 0.0{
        didSet{
            updateLastPlayed()
        }
    }
    var lastPlayed: Date?
    var finishedPlaying: Bool? = false
    var duration:Double?
    var maxPlayposition:Double? = 0.0
    
    
    var isAvailableLocally:Bool? = false
  
 
    //MARK: values that don't need to be stored
    
    @Transient var downloadStatus = EpisodeDownloadStatus()
    
    
    //MARK: calculated properties that a generated on the fly
    
  
    
    @Transient lazy var localFile: URL? = {
        let fileName = assetLink?.lastPathComponent ?? title ?? pubDate?.ISO8601Format() ?? Date().ISO8601Format()
        let documentsDirectoryUrl = podcast?.directoryURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return documentsDirectoryUrl?.appendingPathComponent(fileName).standardizedFileURL
    }()
    
    func UpdateisAvailableLocally() -> Bool{
        if let localFile = localFile?.path() {
            let manager = FileManager()
            if manager.fileExists(atPath: localFile) {
                downloadStatus.isDownloading = false
                isAvailableLocally = true
                print("UpdateisAvailableLocally \(isAvailableLocally?.description ?? "--")")

                return true
            }else{
                isAvailableLocally = false
                print("UpdateisAvailableLocally \(isAvailableLocally?.description ?? "--")")

                return false
            }
        }else{
            isAvailableLocally = false
            print("UpdateisAvailableLocally 2 \(isAvailableLocally?.description ?? "--")")

            return false
        }
    }
    
 
    
    @Transient lazy var avAsset:AVAsset? = {
        if let url = localFile, isAvailableLocally ?? false{
            return AVAsset(url: url)
        }else{
            if let remoteURL = assetLink{
                return AVAsset(url: remoteURL)
            }
        }
        return nil
    }()
    
    
    @Transient private lazy var downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: .main)
    }()
    
    @Transient lazy var coverImage: some View = {
        
        if let imageURL = image{
            return AnyView(ImageWithURL(imageURL))
        }else if let podcastcover = podcast?.coverURL{
            return AnyView(ImageWithURL(podcastcover))
        }else{
            return AnyView(Image(systemName: "mic.fill"))
        }
         
    }()
    
    
    @Transient lazy var uiimage: UIImage = {
    
        if let cover{
            return ImageWithData(cover).uiImage()
        }else if let cover = podcast?.cover{
            return ImageWithData(cover).uiImage()
        }else{
            return UIImage(systemName: "photo") ?? UIImage()
        }
    }()
    
  

    
    @Transient  var progress:Double {
        if let duration{
            return ((playPosition ?? 0) / duration)
        }
        return 0.0
    }

    func updateLastPlayed(){
        self.lastPlayed = Date()
    }
    
    
    
    
    func postProcessingAfterDownload() async{
        print("postProcessing")
        await updateDuration()
        if image == nil, cover == nil{
            cover = await extractCoverImage()
        }
        await updateChapters()
        
    }
    
    func extractCoverImage() async -> Data? {
       
        
        
        if let audioTracks = try? await avAsset?.loadTracks(withMediaType: .audio){
            
            if let audioTrack = audioTracks.first {
                if let formatDescriptions = try? await audioTrack.load(.formatDescriptions){
                    
                    for formatDescription in formatDescriptions {
                        guard let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription ) else {
                            continue
                        }
                        
                        let audioFormatID = audioStreamBasicDescription.pointee.mFormatID
                        
                        if audioFormatID == kAudioFormatMPEGLayer3 {
                           
                        } else if audioFormatID == kAudioFormatMPEG4AAC {
                            do{
                                if let metadata = try await avAsset?.load(.commonMetadata){
                                    
                                    for item in metadata {
                                        if let key = item.commonKey, key == AVMetadataKey.commonKeyArtwork {
                                            if let data = try await item.load(.value) as? Data {
                                                return data
                                            }
                                        }
                                    }
                                }
                            }catch{
                                print(error)
                            }
                        }
                    }
                }
            }
        }
        
        
        
        
        
        
        

        
        return nil
    }

    
    func updateChapters() async{
        
        
       
        
        let embeddedChapterCount = chapters?.filter({ $0.type == .embedded }).count ?? 0
        if embeddedChapterCount == 0{
            if let localFile{
                let fileChapters = await createChapters(from: localFile) ?? []
                chapters?.append(contentsOf: fileChapters)
            }
        }
        
        let extractedChapterCount = chapters?.filter({ $0.type == .extracted }).count ?? 0
        if extractedChapterCount == 0{
            if let sourceText = content ?? desc{
                let sourceChapters =  await createChapters(from: sourceText)
                chapters?.append(contentsOf: sourceChapters)
            }
        }
        
        if let chapters, chapters.count > 0{

            let chapterGrouped = Dictionary(grouping: chapters, by: { $0.type })
            
            for group in chapterGrouped{
                print("enhancing \(group.key.rawValue) chapters")
                var lastEnd = duration ?? 100
                for chapter in group.value.sorted(by: {$0.start ?? 0.0 > $1.start ?? duration ?? 100}){ 
                    if chapter.duration == nil{
                        chapter.duration = lastEnd - (chapter.start ?? 0.0)
                        lastEnd = chapter.start ?? 0.0
                    }
                    
                }
            }
            
            
        }
        /*
        do{
            try modelContext?.save()
        }catch{
            print(error)
        }
         */
    }
    
    func updateDuration() async{
        print("updateDuration()")
        print("pre-update \(duration?.formatted() ?? "")")
        if duration == nil{
            if let localFile = localFile{
                do{
                    print("updating Duration")
                    let duration = try await AVAsset(url: localFile).load(.duration)
                    print("post-update from file \(duration.seconds)")
                    setDuration(duration)
                    
                }catch{
                    print(error)
                }
            }else{
                print("no local file")
            }
        }
    }
    func setDuration(_ duration: CMTime) {
        
        let seconds = CMTimeGetSeconds(duration)
        print("updating to \(seconds.description)")
        
        if !seconds.isNaN{
            self.duration = seconds
            print("new Duration: \(self.duration?.description ?? "nil")")
        }else{
            print("seconds NaN")
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
            await downloadTranscript()
            await downloadCover()
        }
    }
    
    func downloadCover() async{
        if let image{
            cover = await image.downloadData()
        }
    }
    
    func downloadTranscript() async{
        print("downloading Transcript")
 
        if let vttFileString = transcripts.first(where: {$0.type == "text/vtt"})?.url{
            if let vttURL = URL(string: vttFileString){
                
                if let vttData = try? await URLSession(configuration: .default).data(from: vttURL){
              
                    print("vttfile from \(vttURL.description)")
                    transcriptData = String(decoding: vttData.0, as: UTF8.self)
                }
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
        subtitle = details["itunes:subtitle"] as? String
        
        print("init Episode: \(title)")
        
        desc = details["description"] as? String
        
        content = details["content"] as? String
     
   /*     if let content{
            decodedContent = await content.decodeHTML() // THIS KILLS THE IMPORT of the OPML file
        }
     */
        duration = (details["itunes:duration"] as? String)?.durationAsSeconds

        link = URL(string: details["link"] as? String ?? "")
        pubDate = Date.dateFromRFC1123(dateString: details["pubDate"] as? String ?? "")
        if let url = details["itunes:image"] as? String{
            image = URL(string: url)
        }
        
        number = details["itunes:episode"] as? String
        
        type = EpisodeType(rawValue: details["itunes:episodeType"] as? String ?? "unknown") ?? .unknown
        
        for assetDetails in details["enclosure"] as? [[String:Any]] ?? []{
            
            assetLink = URL(string: assetDetails["url"] as? String ?? "")// the original URL of the asset
            length = Int(assetDetails["length"] as? String ?? "")
            assetType = assetDetails["type"] as? String
 
        }
        
        for transcript in details["transcripts"] as? [Transcript] ?? []{
            
            transcripts.append(transcript)
        }

        if let psc = details["psc:chapters"] as? [[String:Any]]{
            chapters = createChapters(from: psc)
        }
        
        
        if guid == nil || guid == ""{
            guid = assetLink?.absoluteString ?? id.uuidString
        }
        
        
        /*
        if image == nil{
            cover = await extractCoverImage()
        }
         */
        
    }

    func markAsPlayed(){
      finishedPlaying = true
    }
    
    func markAsNotPlayed(){
        finishedPlaying = false
    }
    

    
}

