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
    
    private init() {
        Task{
           
                settingLockScreenScrubbing = await PodcastSettingsModelActor(modelContainer: ModelContainerManager.shared.container).getLockScreenSliderEnable()
            
        }
        let RCC = MPRemoteCommandCenter.shared()
        
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
        
        RCC.skipForwardCommand.isEnabled = true
        RCC.skipForwardCommand.addTarget { event in
            
            let seconds = Double((event as? MPSkipIntervalCommandEvent)?.interval ?? 0)
            self.player.jumpPlaypostion(by: seconds)
            return.success
        }
        RCC.skipForwardCommand.preferredIntervals = [NSNumber(value: 30)]
        
        
        // <<
        RCC.skipBackwardCommand.isEnabled = true
        RCC.skipBackwardCommand.addTarget { event in
            
            let seconds = Double((event as? MPSkipIntervalCommandEvent)?.interval ?? 0)
            self.player.jumpPlaypostion(by: -seconds)
            return.success
        }
        
        RCC.skipBackwardCommand.preferredIntervals = [NSNumber(value: 15)]
        
        
        RCC.bookmarkCommand.isEnabled = true
        RCC.bookmarkCommand.addTarget { event in
         //   self.bookmark()
            return.success
        }
        
        RCC.changePlaybackPositionCommand.isEnabled = settingLockScreenScrubbing
        RCC.changePlaybackPositionCommand.addTarget { event in
            
                if let event = event as? MPChangePlaybackPositionCommandEvent {
                    let time = CMTime(seconds: event.positionTime, preferredTimescale: 1000000).seconds
                    self.player.jumpTo(time: time)
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
}
