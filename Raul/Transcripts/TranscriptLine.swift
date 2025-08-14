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
 var text: String
 var startTime: TimeInterval
 var endTime: TimeInterval?
 
 init( speaker: String? = nil, text: String, startTime: TimeInterval, endTime: TimeInterval? = nil) {

 self.speaker = speaker
 self.text = text
 self.startTime = startTime
 self.endTime = endTime
 }
     
     
 }
 
 

