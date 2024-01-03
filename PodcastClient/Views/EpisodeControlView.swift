//
//  EpisodeControlView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 01.01.24.
//

import SwiftUI

struct EpisodeControlView: View {
    @Environment(Episode.self) private var episode

    var body: some View {
        if episode.isAvailableLocally{
            Text("Play")
        }else{
            Text("download")
        }
    }
}

#Preview {
    EpisodeControlView()
}
