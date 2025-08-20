//
//  NowPlayingUpdater.swift
//  Raul
//
//  Created by Holger Krupp on 12.07.25.
//

import Foundation
import MediaPlayer
import UIKit


class NowPlayingInfoActor {
    private var info: [String: Any] = [:]
    private var artwork: MPMediaItemArtwork?
    
 //   static let shared = NowPlayingInfoActor()
    
    
    
    func updateInfo(_ info: [String: Any]) {
        var info = info
        
        if let artwork = artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        self.info = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    func setArtwork(_ image: UIImage) {
       
        // print("setArtwork \(image.size.width)x\(image.size.height)")
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
            return image
        }
        setArtwork(artwork)
    }

    func setArtwork(_ artwork: MPMediaItemArtwork?) {
        self.artwork = artwork
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            if let artwork = artwork {
                // print("chanening artwork")
                info[MPMediaItemPropertyArtwork] = artwork
                self.info = info
            } else {
                // print("removing artwork")
                info.removeValue(forKey: MPMediaItemPropertyArtwork)
                self.info = info
            }
            
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    func updateField(key: String, value: Any) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[key] = value
        if let artwork = artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        self.info = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        self.info = [:]
        self.artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

