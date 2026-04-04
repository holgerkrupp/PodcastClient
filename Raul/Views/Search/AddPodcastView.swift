//
//  AddPodcastView.swift
//  Raul
//
//  Created by Holger Krupp on 03.04.25.
//

import SwiftUI
import SwiftData

struct AddPodcastView: View {
    @Environment(\.modelContext) private var context
    
    @Binding var search: String
    @State private var selectedPodcastID: PersistentIdentifier?
    enum Selection {
        case search, hot, importexport
    }
    @State private var listSelection:Selection = .search

    private var selectedPodcast: Podcast? {
        guard let selectedPodcastID else { return nil }
        return context.model(for: selectedPodcastID) as? Podcast
    }

    var body: some View {
        NavigationStack{
            List{
            
                NavigationLink(destination: ImportExportView()
                    .modelContext(context)) {
                    HStack {
                        Text("Import / Export")
                            .font(.headline)

                    }
                }
                NavigationLink(destination:  PodcastCategoryView()
                    .modelContext(context)) {
                    HStack {
                        Text("Browse by Category")
                            .font(.headline)

                    }
                }
                NavigationLink(destination:  HotPodcastView()
                    .modelContext(context)) {
                    HStack {
                        Text("Hot Podcasts")
                            .font(.headline)

                    }
                }
                
             
                    PodcastSearchView(search: $search, onOpenPodcast: { podcastID in
                        selectedPodcastID = podcastID
                    })
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 0,
                                         trailing: 0))

            }
            .listStyle(.plain)
        }
        .navigationDestination(
            isPresented: Binding(
                get: { selectedPodcastID != nil },
                set: { isPresented in
                    if isPresented == false {
                        selectedPodcastID = nil
                    }
                }
            )
        ) {
            if let selectedPodcast {
                PodcastDetailView(podcast: selectedPodcast)
            } else {
                ContentUnavailableView("Podcast Not Found", systemImage: "dot.radiowaves.left.and.right")
            }
        }
       
    }
}

#Preview {
    @Previewable @State var search: String = ""
    AddPodcastView(search: $search)
}
