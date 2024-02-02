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
    
    
    // MARK: Create Chapters from Asset
    func createChapters(from assetUrl: URL) async -> [Chapter]?{
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
    
    
    
    //MARK: Create Chapters from Episode Description
    func createChapters(from text: String) -> [Chapter]{
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
    
    
}
