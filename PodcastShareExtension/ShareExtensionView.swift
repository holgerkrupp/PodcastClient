import SwiftUI

struct ShareExtensionView: View {
    @ObservedObject var viewModel: ShareExtensionViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .loading:
                    ProgressView("Reading shared link…")
                case .checking(_):
                    VStack(spacing: 18) {
                        ProgressView("Checking link…")
                        if viewModel.canSubscribe {
                            if let podcast = viewModel.podcastFeed {
                                podcastCard(podcast)
                                    .padding(.horizontal)
                            }
                        }
                    }
                case .podcastEpisode(let podcast, let episode):
                    ScrollView {
                        VStack(spacing: 16) {
                            episodeCard(episode, podcast: podcast)
                            podcastCard(podcast)
                            addEpisodeActions
                        }
                        .padding()
                    }
                case .podcast(let podcast):
                    ScrollView {
                        VStack(spacing: 16) {
                            podcastCard(podcast)
                            if viewModel.canSearch {
                                podcastSearchSection
                            }
                        }
                        .padding()
                    }
                case .standalone(let media):
                    ScrollView {
                        VStack(spacing: 16) {
                            standaloneEpisodeCard(media)
                            if let podcast = viewModel.podcastFeed {
                                podcastCard(podcast)
                            }
                            addEpisodeActions
                        }
                        .padding()
                    }
                case .unresolved(_, let query):
                    ScrollView {
                        VStack(spacing: 16) {
                            if let podcast = viewModel.podcastFeed {
                                podcastCard(podcast)
                            }
                            if viewModel.hasSearched == false {
                                ContentUnavailableView(
                                    "Couldn’t Find Podcast or Audio",
                                    systemImage: "questionmark.circle",
                                    description: Text("Search podcasts for \(query ?? "the shared page") right here.")
                                )
                            }
                            if viewModel.canSearch {
                                podcastSearchSection
                            }
                        }
                        .padding()
                    }
                case .saving:
                    ProgressView("Saving for Up Next…")
                case .saved(let message):
                    ContentUnavailableView("Saved for Up Next", systemImage: "checkmark.circle.fill", description: Text(message))
                case .failed(let message):
                    ContentUnavailableView("Couldn’t Save Link", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .navigationTitle("Add to Up Next")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { viewModel.done() }
                        .disabled(viewModel.state == .loading || viewModel.isChecking || viewModel.state == .saving)
                }
            }
        }
    }

    private var destinationList: some View {
        Menu {
            Button("Inbox") { viewModel.selectedPlaylistID = nil }
            ForEach(viewModel.playlists) { playlist in
                Button(playlist.title) { viewModel.selectedPlaylistID = playlist.id }
            }
        } label: {
            Label(destinationTitle, systemImage: "tray.fill")
        }
    }

    private var podcastSearchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Podcast or topic", text: $viewModel.searchQuery)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { viewModel.search() }

            Button("Search in Up Next") { viewModel.search() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(viewModel.isSearching || viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if viewModel.isSearching {
                ProgressView("Searching podcasts…")
                    .frame(maxWidth: .infinity)
            } else if let error = viewModel.searchError {
                ContentUnavailableView("Search Failed", systemImage: "wifi.exclamationmark", description: Text(error))
            } else if viewModel.hasSearched && viewModel.searchResults.isEmpty {
                ContentUnavailableView("No Podcasts Found", systemImage: "magnifyingglass", description: Text("Try a different podcast name or topic."))
            } else if viewModel.searchResults.isEmpty == false {
                VStack(spacing: 12) {
                    ForEach(viewModel.searchResults) { podcast in
                        podcastCard(podcast)
                    }
                }
            }
        }
    }

    private func subscribeButton(for podcast: ShareLinkPodcast) -> some View {
        Button { viewModel.subscribe(to: podcast) } label: {
            Label("Subscribe", systemImage: "plus.circle")
                .frame(minWidth: 150)
        }
        .buttonStyle(.borderedProminent)
    }

    private var addEpisodeActions: some View {
        VStack(spacing: 12) {
            destinationList
            Button("Add Episode") { viewModel.addEpisode() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }

    private func episodeCard(_ episode: ShareLinkEpisode, podcast: ShareLinkPodcast) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                artwork(episode.artworkURL ?? podcast.artworkURL)
                VStack(alignment: .leading, spacing: 6) {
                    Text(podcast.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(episode.title)
                        .font(.headline)
                        .lineLimit(4)
                    if let duration = episode.duration {
                        Text(durationText(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let description = episode.description, description.isEmpty == false {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }

    private func standaloneEpisodeCard(_ episode: ShareLinkStandaloneMedia) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                artwork(episode.artworkURL)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Episode Found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(episode.title)
                        .font(.headline)
                        .lineLimit(4)
                    if let duration = episode.duration {
                        Text(durationText(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let description = episode.description, description.isEmpty == false {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }

    private func podcastCard(_ podcast: ShareLinkPodcast) -> some View {
        HStack(alignment: .center, spacing: 14) {
            artwork(podcast.artworkURL)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Podcast Found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(podcast.title)
                        .font(.headline)
                        .lineLimit(2)
                    if let author = podcast.author, author.isEmpty == false {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                subscribeButton(for: podcast)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func artwork(_ url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                artworkPlaceholder
            }
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            artworkPlaceholder
                .frame(width: 104, height: 104)
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.accentColor.opacity(0.12))
            .overlay {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title)
                    .foregroundStyle(.tint)
            }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return hours > 0 ? "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))" : "\(minutes):\(String(format: "%02d", seconds))"
    }

    private var destinationTitle: String {
        guard let id = viewModel.selectedPlaylistID,
              let playlist = viewModel.playlists.first(where: { $0.id == id }) else { return "Inbox" }
        return playlist.title
    }
}
