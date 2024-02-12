//
//  SleepTimer.swift
//  PodcastClient
//
//  Created by Holger Krupp on 09.02.24.
//

import Foundation
import AVFoundation

@Observable
class SleepTimer{
        
    var settings:PodcastSettings = SettingsManager.shared.defaultSettings
  
        enum SleeptimerType{
            case time, episode
        }
        var activated:Bool = false{
            didSet{
                if activated == true{
                    start = Date()
                }else{
                    start = nil
                }
            }
        }
        var minutes:Double = 5
        var secondsLeft:Double?{
            end?.timeIntervalSince(Date())
        }
        var type:SleeptimerType = .time
        var start: Date? = nil
        var end:Date? {
            start?.addingTimeInterval(60*minutes)
        }
        var lastFinish:Date?
    

 
        
    var synthesizer = AVSpeechSynthesizer()
    
    func speak(){
        if settings.sleepTimerVoiceFeedbackEnabled{
            let utterance = AVSpeechUtterance(string: settings.sleepTimerText)
            utterance.voice = AVSpeechSynthesisVoice(language: "en")
            utterance.rate = 1.0
            
            
            synthesizer.speak(utterance)
            print("speak")
        }
    }
    
    func reactivate(){
        if let sleetTimerJustFinished = lastFinish?.addingTimeInterval(settings.sleepTimerDurationToReactivate * 60), sleetTimerJustFinished >= Date(){
            // Sleeptime just finished, but if the user presses play again, we reactivate the sleeptimer and add some more time
            print("reactivate SleepTimer")
            minutes = settings.sleepTimerAddMinutes
            speak()
            activated.toggle()
        }
    }
    
    /*
    func listOfVoices() -> [String: [String: String]]{
        let voices = AVSpeechSynthesisVoice.speechVoices()
        
        return voices.reduce(into: [String: [String: String]]()) { result, voice in
            result[voice.identifier] = ["name": voice.name, "language": voice.language]
        }
        
    }
     */
}

