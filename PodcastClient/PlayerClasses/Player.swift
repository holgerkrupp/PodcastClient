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
    
    
    
    private override init() {
        super.init()
    }
}
