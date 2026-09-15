//
//  PublicBroadcastersView.swift
//  Raul
//
//  Landing screen for public-broadcaster discovery: a search entry point and the
//  browsable broadcasters grouped by region.
//
//  Everything here is driven by the registry. There is no per-broadcaster code
//  path, so a new provider appears without touching this file.
//

import SwiftUI
import SwiftData

struct PublicBroadcastersView: View {
    @Environment(\.modelContext) private var context

    private let registry: PodcastDiscoveryRegistry

    init(registry: PodcastDiscoveryRegistry = .shared) {
        self.registry = registry
    }

    var body: some View {
        List {
            Section {
                Text("Discover podcasts from public-service media around the world.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }

            if registry.searchableProviders.isEmpty == false {
                Section {
                    NavigationLink {
                        PublicBroadcasterSearchView(registry: registry)
                            .modelContext(context)
                    } label: {
                        Label("Search Public Broadcasters", systemImage: "magnifyingglass")
                    }
                }
            }

            ForEach(registry.browsableBroadcastersByRegion, id: \.region) { group in
                Section(String(localized: group.region.title)) {
                    ForEach(group.broadcasters) { broadcaster in
                        NavigationLink {
                            destination(for: broadcaster)
                        } label: {
                            PublicBroadcasterRow(broadcaster: broadcaster)
                        }
                    }
                }
            }
        }
        .navigationTitle("Public Broadcasters")
    }

    @ViewBuilder
    private func destination(for broadcaster: PublicBroadcaster) -> some View {
        if let provider = registry.provider(for: broadcaster.id) {
            BroadcasterDiscoveryView(provider: provider)
                .modelContext(context)
        } else {
            BroadcasterUnavailableView(broadcaster: broadcaster)
        }
    }
}

/// A broadcaster row: flag, name, country and a short description.
/// The country is always spelled out — the flag is decoration, never the only
/// carrier of that information.
struct PublicBroadcasterRow: View {
    let broadcaster: PublicBroadcaster

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BroadcasterEmblem(broadcaster: broadcaster)

            VStack(alignment: .leading, spacing: 4) {
                Text(broadcaster.name)
                    .font(.headline)

                Text(broadcaster.countryName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(broadcaster.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(broadcaster.name), \(broadcaster.countryName)")
    }
}

/// The broadcaster's logo when one is known, otherwise the country flag over a
/// tinted tile. Decorative for VoiceOver: the surrounding row states the name.
struct BroadcasterEmblem: View {
    let broadcaster: PublicBroadcaster
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))

            if let logoURL = broadcaster.logoURL {
                CoverImageView(imageURL: logoURL)
                    .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            } else if let flag = broadcaster.flag {
                Text(flag)
                    .font(.system(size: size * 0.5))
            } else {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Shown when a broadcaster is in the catalog but has no provider — reached only
/// through a direct link, since the list itself hides unbrowsable broadcasters.
struct BroadcasterUnavailableView: View {
    let broadcaster: PublicBroadcaster

    var body: some View {
        ContentUnavailableView {
            Label(broadcaster.name, systemImage: "dot.radiowaves.left.and.right")
        } description: {
            VStack(spacing: 8) {
                Text(broadcaster.summary)
                Text("Currently unavailable. Try again later.")
            }
        } actions: {
            if let website = broadcaster.website {
                Link(destination: website) {
                    Label("Open Broadcaster Website", systemImage: "safari")
                }
            }
        }
        .navigationTitle(broadcaster.name)
    }
}

#Preview {
    NavigationStack {
        PublicBroadcastersView()
    }
}
