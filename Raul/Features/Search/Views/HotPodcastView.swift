//
//  PodcastSearchView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import SwiftData

struct HotPodcastView: View {

    @Environment(\.modelContext) private var context
    @Query private var allPodcasts: [Podcast]
    @State private var subscriptionLookup = PodcastDiscoverySubscriptionLookup(podcasts: [])
    @StateObject private var viewModel = PodcastSearchViewModel()

    var body: some View {
        List{
        Group{
            Picker("Region", selection: $viewModel.selectedRegion) {
                ForEach(viewModel.regions) { region in
                    Text(region.displayName).tag(region.code as String?)
                }
            }
            .pickerStyle(.menu)
        }
        .padding()
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(.init(top: 0,
                             leading: 0,
                             bottom: 0,
                             trailing: 0))
        
        
        
        
     
            if viewModel.isLoading {
                ProgressView()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 0,
                                         trailing: 0))
            } else if viewModel.hotPodcasts.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "Hot Podcasts Unavailable",
                        systemImage: "flame",
                        description: Text(viewModel.hotErrorMessage ?? "No podcasts are available for this region.")
                    )
                    Button("Try Again") {
                        Task { await viewModel.loadHotPodcasts() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                    ForEach(viewModel.hotPodcasts , id: \.self) { podcast in
                        SubscribeToPodcastView(newPodcastFeed: podcast, existingPodcast: existingPodcast(for: podcast))
                            .modelContext(context)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0,
                                                 leading: 0,
                                                 bottom: 0,
                                                 trailing: 0))
                        
                        
                    }
                }

                
                
            }
        .listStyle(.plain)
        .navigationTitle("Hot Podcasts")
        .task {
            subscriptionLookup = PodcastDiscoverySubscriptionLookup(podcasts: allPodcasts)
            if viewModel.hotPodcasts.isEmpty {
                await viewModel.loadHotPodcasts()
            }
        }
        .onChange(of: allPodcasts.map(PodcastDiscoverySubscriptionLookup.signature(for:))) {
            subscriptionLookup = PodcastDiscoverySubscriptionLookup(podcasts: allPodcasts)
        }
            
            
        

    }

    private func existingPodcast(for feed: PodcastFeed) -> Podcast? {
        subscriptionLookup.existingPodcast(for: feed, context: context)
    }
}
