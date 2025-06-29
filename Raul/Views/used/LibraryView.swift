//
//  LibraryView.swift
//  Raul
//
//  Created by Holger Krupp on 29.05.25.
//

import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var context

    enum Selection {
        case podcasts, episodes
    }
    @State private var listSelection:Selection = .podcasts
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Content of the section (e.g., first few items)
                    
                //    Text("All Episodes")
                    
                } header: {
                    // The clickable header using NavigationLink
                    NavigationLink(destination: AllEpisodesListView()) {
                        HStack {
                            Text("All Episodes")
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    // Important: Make the entire NavigationLink tappable
                    .buttonStyle(PlainButtonStyle()) // Removes default button styling
                    .contentShape(Rectangle()) // Ensures the whole area is tappable
                }
                Section {
                    // Content of the section (e.g., first few items)
                    
                //    Text("All Episodes")
                    
                } header: {
                    // The clickable header using NavigationLink
                    NavigationLink(destination: AllEpisodesListView().onlyPlayed()) {
                        HStack {
                            Text("Recently Played Episodes")
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    // Important: Make the entire NavigationLink tappable
                    .buttonStyle(PlainButtonStyle()) // Removes default button styling
                    .contentShape(Rectangle()) // Ensures the whole area is tappable
                }
                
                Section {
                    PodcastListView(modelContainer: context.container)
                } header: {
                    // The clickable header using NavigationLink
                   
                        HStack {
                            Text("All Podcasts")
                                .font(.headline)
                            
                        
                    }
                    
                }
            }
            .listStyle(.plain)
        }
        /*
        VStack {
            
            
            Picker(selection: $listSelection) {
                Text("Podcasts").tag(Selection.podcasts)
                Text("Episodes").tag(Selection.episodes)
            } label: {
                Text("Show")
            }
            .pickerStyle(.segmented)
            switch listSelection {
            case .podcasts:
                PodcastListView(modelContainer: context.container)
            case .episodes:
                AllEpisodesListView()
            }
        }
        */
    }
}

#Preview {
    LibraryView()
}
