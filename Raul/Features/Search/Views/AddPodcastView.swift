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
    enum Selection {
        case search, hot, importexport
    }
    @State private var listSelection: Selection = .search

    private var isSearching: Bool {
        search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var body: some View {
        List {
            // While the user is typing, the results are what matters — the
            // entry points would only push them off screen.
            if isSearching == false {
                Section("Discover") {
                    NavigationLink {
                        PodcastCategoryView()
                            .modelContext(context)
                    } label: {
                        AddPodcastDestinationRow(
                            symbol: "square.grid.2x2.fill",
                            title: "Browse by Category",
                            subtitle: "Powered by the Apple Podcasts catalog"
                        )
                    }

                    NavigationLink {
                        PublicBroadcastersView()
                            .modelContext(context)
                    } label: {
                        AddPodcastDestinationRow(
                            symbol: "antenna.radiowaves.left.and.right",
                            title: "Public Broadcasters",
                            subtitle: "Browse public-service podcasts"
                        )
                    }

                    NavigationLink {
                        HotPodcastView()
                            .modelContext(context)
                    } label: {
                        AddPodcastDestinationRow(
                            symbol: "flame.fill",
                            title: "Hot Podcasts",
                            subtitle: "Top charts in your region"
                        )
                    }
                }

                Section("Your Library") {
                    NavigationLink {
                        ImportExportView()
                            .modelContext(context)
                    } label: {
                        AddPodcastDestinationRow(
                            symbol: "square.and.arrow.down.on.square",
                            title: "Import / Export",
                            subtitle: "Move subscriptions with OPML files"
                        )
                    }
                }
            }

            PodcastSearchView(search: $search)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 0,
                                     leading: 0,
                                     bottom: 0,
                                     trailing: 0))
        }
        .listStyle(.plain)
        .navigationTitle("Add Podcast")
    }
}

/// One entry point on the Add Podcast screen. Every row has the same shape —
/// symbol, title, one line of explanation — so the list reads as one set of
/// choices rather than a pile of unrelated links.
private struct AddPodcastDestinationRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 38

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: iconSize / 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))

                Image(systemName: symbol)
                    .font(.system(size: iconSize * 0.45))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
            }
            .frame(width: iconSize, height: iconSize)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    @Previewable @State var search: String = ""
    NavigationStack {
        AddPodcastView(search: $search)
    }
}
