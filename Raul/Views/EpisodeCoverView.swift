//
//  EpisodeCoverView.swift
//  Raul
//
//  Created by Holger Krupp on 15.05.25.
//

import SwiftUI

struct EpisodeCoverView: View {
    
    @State var episode: Episode
    var body: some View {
        Group {
            
            if let episodeCover = episode.imageURL {
                ImageWithURL(episodeCover)
                    .scaledToFit()
            }else if let podcastCover = episode.podcast?.imageURL {
                ImageWithURL(podcastCover)
                    .scaledToFit()
            }else {
                Image(systemName: "photo")
            }
    
        }
    }
}
