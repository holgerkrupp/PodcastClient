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
                    ProgressView("Checking link…")
                case .podcastEpisode(let podcast, let episode):
                    resultView(title: "Podcast Found", subtitle: "\(podcast.title)\n\n\(episode.title)", symbol: "checkmark.circle.fill")
                case .podcast(let podcast):
                    resultView(title: "Podcast Found", subtitle: podcast.title, symbol: "dot.radiowaves.left.and.right")
                case .standalone(let media):
                    resultView(title: "Episode Found", subtitle: media.title, symbol: "waveform")
                case .unresolved(_, let query):
                    VStack(spacing: 12) {
                        ContentUnavailableView("Couldn’t Find Podcast or Audio", systemImage: "questionmark.circle", description: Text("You can search Up Next using \(query ?? "the shared page") instead."))
                        if viewModel.canSearch { Button("Search in Up Next") { viewModel.search() } .buttonStyle(.borderedProminent) }
                    }
                    .padding()
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

    @ViewBuilder
    private func resultView(title: String, subtitle: String, symbol: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(subtitle).multilineTextAlignment(.center).foregroundStyle(.secondary)

            if case .podcastEpisode(_, _) = viewModel.state {
                Button("Subscribe") { viewModel.subscribe() }.buttonStyle(.bordered)
            }
            if viewModel.canAdd {
                destinationList
                Button("Add Episode") { viewModel.addEpisode() }.buttonStyle(.borderedProminent)
            }
            if viewModel.canSearch {
                Button("Search in Up Next") { viewModel.search() }.buttonStyle(.bordered)
            }
        }
        .padding()
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

    private var destinationTitle: String {
        guard let id = viewModel.selectedPlaylistID,
              let playlist = viewModel.playlists.first(where: { $0.id == id }) else { return "Inbox" }
        return playlist.title
    }
}
