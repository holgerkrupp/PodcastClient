//
//  settings.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation
import SwiftData


@Model
class PodcastSettings {
    

    
    var autoDownload:Bool = false
    var playbackSpeed:Float = 1.0
    var autoSkipKeywords:[skipKey] = [] // to create a function to skip chapters with specific keywords
    var cutFront:Float? // how much to cut from the front / Intro
    var cutEnd:Float? // how much to cut from the end / Outro
    
    init(){}
}

enum Operator:Codable {
    case Is, Contains, StartsWith, EndsWith
}

struct skipKey:Codable{
    
    var keyWord:String?
    var keyOperator:Operator = .Contains
}
