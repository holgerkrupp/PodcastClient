//
//  InboxEmptyView.swift
//  Raul
//
//  Created by Holger Krupp on 18.05.25.
//

import SwiftUI

struct PodcastsEmptyView: View {
    var body: some View {
        VStack{
            Text("Your Library is empty")
                .font(.headline)
            Divider()
            Text("You have not subscribed to any podcasts yet. Tap the + Button in the bottom right corner to subscribe to some podcasts. You can import a OPML File, search the directory or browse for trending podcasts in different languages.")
        }
        .padding()
    }
}

#Preview {
    PodcastsEmptyView()
}
