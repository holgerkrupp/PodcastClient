//
//  Settings.swift
//  Raul
//
//  Created by Holger Krupp on 29.06.25.
//


import Foundation
import SwiftData


@Model
class PodcastSettings {
    
    var id = UUID()
    var title:String?
    var isEnabled:Bool = true
    
    var autoDownload:Bool = false
    var playnextPosition:Playlist.Position = Playlist.Position.none
    var playbackSpeed:Float? = 1.0
    var autoSkipKeywords:[skipKey] = [] // to create a function to skip chapters with specific keywords
    var cutFront:Float? // how much to cut from the front / Intro
    var cutEnd:Float? // how much to cut from the end / Outro
    
    var skipForward:SkipSteps = SkipSteps.thirty
    var skipBack: SkipSteps = SkipSteps.fifteen
    
    
    // Secret Settings that should only be applied on global way:
    var markAsPlayedAfterSubscribe: Bool = true
    var playSumAdjustedbyPlayspeed: Bool = false
    var enableLockscreenSlider:Bool = true

    var sleepTimerAddMinutes: Double = 10 // 10 minutes
    var sleepTimerDurationToReactivate: Double = 300 // 5 minutes * 60 seconds
    var sleepTimerVoiceFeedbackEnabled: Bool = true
    var sleepTimerText: String = "Sleep Timer extended"
    var sleepTimerVoice: String = "com.apple.speech.voice.Alex"
    
    var voices: [String:[String:String]]?
    
    @Relationship var podcast:Podcast?
    
    
    
    init(){}
    
    init(podcast: Podcast){
        title = podcast.title
        self.podcast = podcast
        print("INIT SETTINGS WITH: \(podcast.title) - \(podcast.id)")
    }
    
    init(defaultSettings: Bool){
        if defaultSettings{
            self.title = "de.holgerkrupp.podbay.queue"
        }
    }
}

enum Operator:Codable {
    case Is, Contains, StartsWith, EndsWith
}

struct skipKey:Codable, Sendable{
    
    var keyWord:String?
    var keyOperator:Operator = .Contains
}

enum SkipSteps:Int, Codable, CaseIterable{
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30
    case fortyfive = 45
    case sixty = 60
    case seventyfive = 75
    case ninety = 90
    
    var float:Float {
        return Float(rawValue)
    }
    
    var backString:String{
        return "gobackward.".appending(rawValue.description)
    }
    
    var forwardString:String{
        return "goforward.".appending(rawValue.description)
    }
}

