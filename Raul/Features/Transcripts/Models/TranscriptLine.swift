//
//  TranscriptLine.swift
//  Raul
//
//  Created by Holger Krupp on 03.07.25.
//

import Foundation
import SwiftData

 @Model final class TranscriptLineAndTime {
 var id = UUID()
 var speaker: String?
 var text: String = ""
     var startTime: TimeInterval = 0.0
 var endTime: TimeInterval?
 /// Missing provenance is treated as unknown and is never eligible for synchronization.
 var sourceRawValue: String?
 @Relationship(inverse: \Episode.transcriptLines) var episode: Episode?
 init(
    id: UUID = UUID(),
    speaker: String? = nil,
    text: String,
    startTime: TimeInterval,
    endTime: TimeInterval? = nil,
    source: CachedTranscriptSource? = nil
 ) {

 self.id = id
 self.speaker = speaker
 self.text = text
 self.startTime = startTime
 self.endTime = endTime
 self.sourceRawValue = source?.rawValue
 }

 var transcriptSource: CachedTranscriptSource? {
    sourceRawValue.flatMap(CachedTranscriptSource.init(rawValue:))
 }
     
     
 }
 
 
