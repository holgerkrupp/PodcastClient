//
//  PlaylistTip.swift
//  Up Next
//
//  Created by Holger Krupp on 08.06.26.
//

import TipKit

struct ReorderPlaylistTip: Tip {
    
    // 1. Define application-state parameters for rules
    @Parameter
    static var playlistItemCount: Int = 0
    
    @Parameter
    static var hasUserReorderedBefore: Bool = false
    
    // 2. Content of the tip
    var title: Text {
        Text("Rearrange Your Queue")
    }
    
    var message: Text? {
        Text("Tap and hold an episode, then drag it up or down to change the playback order.")
    }
    
    var image: Image? {
        Image(systemName: "line.3.horizontal") // The classic drag handle icon
    }
    
    // 3. Rules to prevent annoying the user
    var rules: [Rule] {
        [
            // Only show if the playlist isn't empty
            #Rule(Self.$playlistItemCount) { $0 > 4 },
            // Only show if they've never done it before
            #Rule(Self.$hasUserReorderedBefore) { $0 == false }
        ]
    }
    
    // 4. Set display constraints (optional)
    var options: [TipOption] {
        [
            
            MaxDisplayCount(1) // Don't show it repeatedly if they ignore it
        ]
    }
}
