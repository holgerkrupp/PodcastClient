//
//  PlaylistEmptyView.swift
//  Raul
//
//  Created by Holger Krupp on 18.05.25.
//

import SwiftUI

struct PlaylistEmptyView: View {
    var body: some View {
        VStack{
            Text("Your Playlist is empty")
                .font(.headline)
            Divider()
            Text("Add episodes from your subscribed podcasts to listen to. The episodes will be played in the order they were added to your playlist. You can rearrange them by dragging them in the list.")
        }
        .padding()
    }
}

#Preview {
    PlaylistEmptyView()
}
