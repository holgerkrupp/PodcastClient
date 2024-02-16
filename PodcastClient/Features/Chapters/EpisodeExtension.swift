//
//  EpisodeExtension.swift
//  PodcastClient
//
//  Created by Holger Krupp on 02.02.24.
//

import Foundation
import AVFoundation

extension Episode{
    
    //MARK: Create Chapters from FeedDetails
    
    func createChapters(from psc: [[String:Any]]) -> [Chapter]{
        var tempC:[Chapter] = []
        for chapterDetails in psc{
            let chapter = Chapter(details: chapterDetails)
            tempC.append(chapter)
        }
        return tempC
    }
    
    
    // MARK: Create Chapters from m4a Asset
    func createChapters(from assetUrl: URL) async -> [Chapter]?{
        print("loading Chapters from Asset with \(assetUrl.absoluteString)")
        let asset = AVAsset(url: assetUrl)
        
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio){
            
            if let audioTrack = audioTracks.first {
                if let formatDescriptions = try? await audioTrack.load(.formatDescriptions){
                    
                    for formatDescription in formatDescriptions {
                        guard let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription ) else {
                        continue
                    }
                    
                    let audioFormatID = audioStreamBasicDescription.pointee.mFormatID
                    
                    if audioFormatID == kAudioFormatMPEGLayer3 {
                      //  return await extractMP3Chapters(from: assetUrl)
                    } else if audioFormatID == kAudioFormatMPEG4AAC {
                        return await extractM4AChapters(from: asset)
                    }
                }
            }
            }
        }
        print("returning nil")
        return nil
        
    }
    
    
    
    func extractM4AChapters(from asset: AVAsset) async -> [Chapter]?{
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
            print("returning \(chapters.count.formatted()) M4A Chapters")
            return chapters
        }else{
            return nil
        }
    }
    
     
     
    func extractMP3Chapters(from url: URL) async -> [Chapter]? {
        print("extractMP3Chapters")
        
        do {
         
            let data = try Data(contentsOf: url)
            
            // Check if the file starts with the "ID3" identifier indicating an ID3v2 tag
            guard data.count >= 3, let id3Identifier = String(data: data[0..<3], encoding: .utf8), id3Identifier == "ID3" else {
                return []
            }
            
            // Extract chapter information based on your specific ID3v2 structure
           // let chapters = parseChapterFrames(data: data)
            
            return nil //chapters
        } catch {
            print("Error extracting chapter marks: \(error.localizedDescription)")
            return nil
        }

        
    }
    /*
    func parseChapterFrames(data: Data) -> [Chapter] {
        var chapters: [Chapter] = []
        
        var index = 0
        while index + 8 < data.count {
            var startTimeBytes: UInt32 = 0
            data[index..<index+4].withUnsafeBytes { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else { return }
                memcpy(&startTimeBytes, baseAddress, MemoryLayout<UInt32>.size)
            }
            
            let startTime = TimeInterval(bitPattern: UInt64(bigEndian: UInt64(startTimeBytes))) / 1000.0 // Assuming time is stored in milliseconds

            index += 4
            
            guard let titleData = data[index..<data.count].split(separator: 0).first else {
                break // No null terminator found, indicating malformed data
            }
            
            if let title = String(bytes: titleData, encoding: .utf8) {
                chapters.append(Chapter(start: startTime, title: title, type: .embedded))           
            } else {
                print("Unable to decode title from bytes: \(titleData)")
            }
            
    
            
            index += titleData.count + 1 // Move to the next frame
        }
        
        return chapters
    }
    
    */
    
    
    //MARK: Create Chapters from Episode Description
    @MainActor func createChapters(from text: String) -> [Chapter]{
        print("extracting Chapters from Shownotes")
        let extractedData = extractTimeCodesAndTitles(from: text)
        var newchapters:[Chapter] = []
        for extractedChapter in extractedData{
            if let startingTime =  extractedChapter.key.durationAsSeconds{
                print("chapter at \(extractedChapter.key) : \(extractedChapter.value) -- \(startingTime.formatted())")
                let newChapter = Chapter(start: startingTime, title: extractedChapter.value, type: .extracted)
                newchapters.append(newChapter)
            }
        }
        print("returning \(newchapters.count.formatted()) Chapters")
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
    @MainActor func extractTimeCodesAndTitles(from htmlEncodedText: String) -> [String: String] {
        var result = [String: String]()
        
     //   let regex = try! NSRegularExpression(pattern: "\\d{2}:\\d{2}:\\d{2} (.+?)(?=<br>|</p>|<!--.*?-->|\\n\\d{2}:\\d{2}:\\d{2}|\\n\\z)", options: .dotMatchesLineSeparators)
    //    let regex = try! NSRegularExpression(pattern: "\\d{2}:\\d{2}:\\d{2} (.+?)(?=<br>|\\n\\d{2}:\\d{2}:\\d{2}|\\n\\z)", options: .dotMatchesLineSeparators)
        let regex = try! NSRegularExpression(pattern: "\\d{2}:\\d{2}:\\d{2} (.+?)(?=<br>|<br />|</p>|\\n\\d{2}:\\d{2}:\\d{2}|\\n\\z)", options: .dotMatchesLineSeparators)

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
    
    
}
