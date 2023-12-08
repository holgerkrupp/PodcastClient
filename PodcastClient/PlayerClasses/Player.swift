//
//  File.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.12.23.
//

import Foundation

class Player: NSObject{
    
    static let shared = Player()
    
    
    var currentlyPlaying:Episode?
    var activePlaylist:Playlist?
    
    
    
    private override init() {
        super.init()
    }
    
    func playPause(){
        
        print("playpause")
        
    }
    
    func skipback(){
        
        print("skipback")
        
    }
    
    func skipforward(){
        
        print("skipforward")
        
    }
    
}
