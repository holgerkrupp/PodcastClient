//
//  InboxEmptyView.swift
//  Raul
//
//  Created by Holger Krupp on 18.05.25.
//

import SwiftUI

struct BookmarkEmptyView: View {
    var body: some View {
        VStack{
            Text("No Bookmarks saved for this podcast.")
                .font(.headline)
            Divider()
            Text("You have not saved a bookmark yet. Tap the bookmark icon during playback to add a bookmark. Bookmarking allows you to listen to a segment of an episode later on. It also works in CarPlay or by saying 'Bookmark this in Up Next'.")
        }
        .padding()
    }
}

#Preview {
    PodcastsEmptyView()
}
