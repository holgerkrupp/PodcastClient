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
    @StateObject private var recentSearchStore = PodcastRecentSearchStore.shared
    @State private var showingAllRecentSearches = false

    private var isSearching: Bool {
        search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var body: some View {
        List {
            // While the user is typing, the results are what matters — the
            // entry points would only push them off screen.
            if isSearching == false {
                Section {
                    Text("Search by podcast name, paste a website or RSS/XML link, or browse popular shows.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    NavigationLink {
                        PodcastCategoryView()
                            .modelContext(context)
                    } label: {
                        Label("Browse Categories", systemImage: "square.grid.2x2")
                    }

                    NavigationLink {
                        HotPodcastView()
                            .modelContext(context)
                    } label: {
                        Label("Top Charts", systemImage: "chart.line.uptrend.xyaxis")
                    }

                    NavigationLink {
                        PublicBroadcastersView()
                            .modelContext(context)
                    } label: {
                        Label("Public Broadcasters", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                header: {
                    Text("Discover")
                }

                Section("Add a Private Feed") {
                    NavigationLink {
                        PrivatePodcastEntryView()
                            .modelContext(context)
                    } label: {
                        Label("Private RSS or Authenticated Feed", systemImage: "lock.shield")
                    }
                }

                if recentSearchStore.searches.isEmpty == false {
                    Section {
                        ForEach(Array(recentSearchStore.searches.prefix(5)), id: \.self) { query in
                            recentSearchRow(query)
                        }

                        if recentSearchStore.searches.count > 5 {
                            Button("See All Recent Searches") {
                                showingAllRecentSearches = true
                            }
                        }
                    } header: {
                        HStack {
                            Text("Recent Searches")
                            Spacer()
                            Button("Clear") {
                                recentSearchStore.clear()
                            }
                            .font(.caption)
                            .accessibilityLabel("Clear recent searches")
                        }
                    }
                }

                Section("Library") {
                    NavigationLink {
                        ImportExportView()
                            .modelContext(context)
                    } label: {
                        Label("Import / Export Subscriptions", systemImage: "square.and.arrow.down.on.square")
                    }
                }
            }

            PodcastSearchView(search: $search, recentSearchStore: recentSearchStore)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 0,
                                     leading: 0,
                                     bottom: 0,
                                     trailing: 0))
        }
        .listStyle(.plain)
        .navigationTitle("Add Podcast")
        .sheet(isPresented: $showingAllRecentSearches) {
            NavigationStack {
                List {
                    ForEach(recentSearchStore.searches, id: \.self) { query in
                        recentSearchRow(query)
                    }
                }
                .navigationTitle("Recent Searches")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingAllRecentSearches = false }
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear") { recentSearchStore.clear() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func recentSearchRow(_ query: String) -> some View {
        Button {
            search = query
            showingAllRecentSearches = false
        } label: {
            Label(query, systemImage: "clock.arrow.circlepath")
                .lineLimit(2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recent search: \(query)")
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) {
                recentSearchStore.remove(query)
            }
        }
    }
}

private struct PrivatePodcastEntryView: View {
    @Environment(\.modelContext) private var context
    @State private var search = ""

    var body: some View {
        List {
            Section {
                Text("Paste the private RSS URL supplied by your podcast provider. Up Next keeps the link or credentials in secure storage and never puts them in sync, exports, or logs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            PodcastSearchView(search: $search, treatsDirectURLsAsPrivate: true)
                .modelContext(context)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
        .listStyle(.plain)
        .navigationTitle("Add Private Podcast")
        .searchable(text: $search, prompt: "Private RSS URL")
    }
}

#Preview {
    @Previewable @State var search: String = ""
    NavigationStack {
        AddPodcastView(search: $search)
    }
}
