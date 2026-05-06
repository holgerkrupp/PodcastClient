//
//  RemoteCommandCenter.swift
//  Raul
//
//  Created by Holger Krupp on 18.07.25.
//

import Foundation
import MediaPlayer

@MainActor
class RemoteCommandCenter {
    static let shared = RemoteCommandCenter()
    let player: Player = Player.shared
    var settingLockScreenScrubbing: Bool = false
    let RCC = MPRemoteCommandCenter.shared()
    private let supportedPlaybackRates: [NSNumber] = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0].map(NSNumber.init(value:))
    
    private init() {
        Task{
           
                settingLockScreenScrubbing = await PodcastSettingsModelActor(modelContainer: ModelContainerManager.shared.container).getLockScreenSliderEnable()
            
        }
        
        
        RCC.bookmarkCommand.isEnabled = true
        RCC.bookmarkCommand.addTarget { _ in
           // self.bookmark()
            return .success
        }
        
        RCC.playCommand.isEnabled = true
        RCC.playCommand.addTarget { _ in
            
            if !self.player.isPlaying {
                self.player.play()
                return .success
            }
            return .commandFailed
        }
        
        
        
        // Add handler for Pause Command
        RCC.pauseCommand.isEnabled = true
        RCC.pauseCommand.addTarget { _ in
            
            if self.player.isPlaying{
                self.player.pause()
                return .success
            }
            return .commandFailed
        }

        RCC.changePlaybackRateCommand.isEnabled = true
        RCC.changePlaybackRateCommand.supportedPlaybackRates = supportedPlaybackRates
        RCC.changePlaybackRateCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }

            self.player.setRate(event.playbackRate)
            return .success
        }
        
        RCC.skipForwardCommand.isEnabled = true
        RCC.skipForwardCommand.addTarget { event in
            
            let seconds = Double((event as? MPSkipIntervalCommandEvent)?.interval ?? 0)
            self.player.jumpPlaypostion(by: seconds)
            return.success
        }
        RCC.skipForwardCommand.preferredIntervals = [NSNumber(value: player.skipForwardStep.rawValue)]
        
        
        // <<
        RCC.skipBackwardCommand.isEnabled = true
        RCC.skipBackwardCommand.addTarget { event in
            
            let seconds = Double((event as? MPSkipIntervalCommandEvent)?.interval ?? 0)
            self.player.jumpPlaypostion(by: -seconds)
            return.success
        }
        
        RCC.skipBackwardCommand.preferredIntervals = [NSNumber(value: player.skipBackStep.rawValue)]
        
        
        RCC.bookmarkCommand.isEnabled = true
        RCC.bookmarkCommand.addTarget { event in
         //   self.bookmark()
            return.success
        }
        
        RCC.changePlaybackPositionCommand.isEnabled = settingLockScreenScrubbing
        RCC.changePlaybackPositionCommand.addTarget { event in
            
                if let event = event as? MPChangePlaybackPositionCommandEvent {
                    Task{
                        let time = CMTime(seconds: event.positionTime, preferredTimescale: 1000000).seconds
                        await self.player.jumpTo(time: time)
                        
                    }
                    return .success
                }
            
            return .commandFailed
        }
        
        RCC.nextTrackCommand.isEnabled = true
        RCC.nextTrackCommand.addTarget { _ in
            Task{
                await self.player.skipToNextChapter()
               
            }
            return .success
        }
        
        RCC.previousTrackCommand.isEnabled = true
        RCC.previousTrackCommand.addTarget { _ in
            Task{
                await self.player.skipToChapterStart()
            }
                return .success
        }
        
        
    }
    
    func updateLockScreenScrubbableState(_ isEnabled: Bool) {
        RCC.changePlaybackPositionCommand.isEnabled = isEnabled
    }

    func updateSkipIntervals() {
        RCC.skipForwardCommand.preferredIntervals = [NSNumber(value: player.skipForwardStep.rawValue)]
        RCC.skipBackwardCommand.preferredIntervals = [NSNumber(value: player.skipBackStep.rawValue)]
    }
}
