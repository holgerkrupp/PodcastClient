import SwiftUI

struct ShareExtensionView: View {
    @ObservedObject var viewModel: ShareExtensionViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .loading:
                    ProgressView("Reading shared episode…")
                case .ready, .saving:
                    destinationList
                case .saved:
                    ContentUnavailableView(
                        "Added",
                        systemImage: "checkmark.circle.fill",
                        description: Text(destinationDescription)
                    )
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn’t Add Episode",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            }
            .navigationTitle("Add Episode")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancel()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        viewModel.add()
                    }
                    .disabled(viewModel.canAdd == false)
                }
            }
        }
    }

    private var destinationList: some View {
        List {
            if let host = viewModel.sharedHost {
                Section("Episode") {
                    Label(host, systemImage: "link")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Add to") {
                destinationRow(
                    title: "Inbox",
                    symbolName: "tray.fill",
                    playlistID: nil
                )

                ForEach(viewModel.playlists) { playlist in
                    destinationRow(
                        title: playlist.title,
                        symbolName: playlist.symbolName,
                        playlistID: playlist.id
                    )
                }
            }

            if viewModel.playlists.isEmpty {
                Section {
                    Text("Open Up Next once to make your playlists available here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(viewModel.state == .saving)
        .overlay {
            if viewModel.state == .saving {
                ProgressView()
            }
        }
    }

    private func destinationRow(
        title: String,
        symbolName: String,
        playlistID: UUID?
    ) -> some View {
        Button {
            viewModel.selectedPlaylistID = playlistID
        } label: {
            HStack {
                Label(title, systemImage: symbolName)
                Spacer()
                if viewModel.selectedPlaylistID == playlistID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(
            viewModel.selectedPlaylistID == playlistID ? .isSelected : []
        )
    }

    private var destinationDescription: String {
        guard let selectedPlaylistID = viewModel.selectedPlaylistID,
              let playlist = viewModel.playlists.first(where: {
                $0.id == selectedPlaylistID
              }) else {
            return "The episode will appear in Inbox."
        }

        return "The episode will appear in \(playlist.title)."
    }
}
