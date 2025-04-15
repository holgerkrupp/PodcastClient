//
//  EpisodeListView.swift
//  Raul
//
//  Created by Holger Krupp on 12.04.25.
//
import SwiftUI
import SwiftData

struct EpisodeListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allEpisodes: [Episode]
    private var player = Player.shared

    var episodes: [Episode] {
        allEpisodes.filter { $0.id != player.currentEpisode?.id }
    }
    
    init(
        predicate: Predicate<Episode>? = nil,
        sort: KeyPath<Episode, Date?> = \.metaData?.lastPlayed,
        order: SortOrder = .forward
    ) {
        if let predicate = predicate {
            _allEpisodes = Query(filter: predicate, sort: sort, order: order)
        }
    }
    
    var body: some View {
        ForEach(allEpisodes) { episode in
            if episode.id != player.currentEpisode?.id {
                EpisodeRowView(episode: episode)
                    .id(episode.id)
                    .padding(.horizontal)
                    .background(.ultraThinMaterial)
            }
        }
    }
}
