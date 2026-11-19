//
//  TranscriptLine.swift
//  Raul
//
//  Created by Holger Krupp on 03.07.25.
//

import Foundation
import SwiftData

/// UTF-16 offsets refer to the exact stored cue text, not a normalized copy.
struct TranscriptTimedSpan: Codable, Hashable, Sendable {
    let location: Int
    let length: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    var cueLevel: Bool? = nil
}

 @Model final class TranscriptLineAndTime {
 var id = UUID()
 var speaker: String?
 var text: String = ""
     var startTime: TimeInterval = 0.0
 var endTime: TimeInterval?
 /// Missing provenance is treated as unknown and is never eligible for synchronization.
 var sourceRawValue: String?
 var timedSpansData: Data?
 /// Fingerprint of the downloaded media used to generate local speech timing.
 var generatedMediaFingerprint: String?
 @Relationship(inverse: \Episode.transcriptLines) var episode: Episode?
 init(
    id: UUID = UUID(),
    speaker: String? = nil,
    text: String,
    startTime: TimeInterval,
    endTime: TimeInterval? = nil,
    source: CachedTranscriptSource? = nil,
    timedSpans: [TranscriptTimedSpan] = [],
    generatedMediaFingerprint: String? = nil
 ) {

 self.id = id
 self.speaker = speaker
 self.text = text
 self.startTime = startTime
 self.endTime = endTime
 self.sourceRawValue = source?.rawValue
 self.timedSpansData = timedSpans.isEmpty ? nil : try? JSONEncoder().encode(timedSpans)
 self.generatedMediaFingerprint = generatedMediaFingerprint
 }

 var transcriptSource: CachedTranscriptSource? {
    sourceRawValue.flatMap(CachedTranscriptSource.init(rawValue:))
 }

 var timedSpans: [TranscriptTimedSpan] {
    guard let timedSpansData else { return [] }
    return (try? JSONDecoder().decode([TranscriptTimedSpan].self, from: timedSpansData)) ?? []
 }
     
     
 }
 
 
