//
//  TimeLineView.swift
//  Raul
//
//  Created by Holger Krupp on 11.04.25.
//

import SwiftUI
import SwiftData

struct TimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Episode> { $0.metaData?.lastPlayed != nil }, sort: \.metaData?.lastPlayed, order: .forward) var topItems: [Episode]
    @Query(filter: #Predicate<Episode> { $0.metaData?.lastPlayed == nil }, sort: \.publishDate, order: .reverse) var bottomItems: [Episode]
    private var player = Player.shared
    

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack() {
                    ForEach(topItems) { item in
                        if item.id != player.currentEpisode?.id {
                            EpisodeRowView(episode: item)
                                .id(item.id)
                                .padding()
                                            .background(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .fill(Color(.systemGray6))
                                                    .shadow(radius: 2)
                                            )
                        }
                        
                    }
                    Divider()
                    PlayerView()
                            .id("player")
                            
                            .frame(height: UIScreen.main.bounds.height * 0.5)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(.systemBlue).opacity(0.1))
                                    .shadow(radius: 2)
                            )

                    Divider()

                    ForEach(bottomItems) { item in
                        EpisodeRowView(episode: item)
                            .id(item.id)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(.systemGray6))
                                    .shadow(radius: 2)
                            )
                    }
                }
                .padding()
            }
            .onAppear {
                DispatchQueue.main.async {
                    print("Scrolling to player...")

                    proxy.scrollTo("player", anchor: .center)
                }
            }
        }
    }
}


#Preview {
    TimelineView()
}
