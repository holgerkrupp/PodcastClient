//
//  PlaylistEmptyView.swift
//  Raul
//
//  Created by Holger Krupp on 18.05.25.
//

import SwiftUI
import SwiftData

struct PlaylistEmptyView: View {
    var title: String? = nil
    var isSmartPlaylist: Bool = false
    
    @Query private var allPodcasts: [Podcast]

    
    
    var body: some View {
        
        if allPodcasts.isEmpty {
            PodcastsEmptyView()
        }else{
            
            VStack{
                Text(emptyTitle)
                    .font(.headline)
                Divider()
                Text(emptyBody)
            }
            .padding()
        }
    }

    private var emptyTitle: String {
        if let title, title.isEmpty == false {
            return "\(title) is empty"
        }
        return "Your Playlist is empty"
    }

    private var emptyBody: String {
        if isSmartPlaylist {
            return "Adjust your smart playlist filters or keep listening. Matching episodes will appear automatically."
        }

        return "Add episodes from your subscribed podcasts to listen to. The episodes will be played in the order they were added to your playlist. You can rearrange them by dragging them in the list."
    }
}

#Preview {
    PlaylistEmptyView()
}
