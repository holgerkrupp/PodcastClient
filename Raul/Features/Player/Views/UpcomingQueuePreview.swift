import CoreData
import SwiftData
import SwiftUI

/// A small view of the actual continuation sequence. It is intentionally
/// backed by the active playback playlist actor, not by the playlist currently
/// being browsed elsewhere in the app.
struct UpcomingQueuePreview: View {
    @Bindable private var player = Player.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.userGuideNavigation) private var navigation

    @State private var snapshot: UpcomingQueueSnapshot?
    @State private var isLoading = true
    @State private var loadError = false
    @State private var reloadGeneration = 0

    private let visibleLimit = 5

    private var visibleEntries: [QueueEpisodeValue] {
        Array((snapshot?.upcoming ?? []).prefix(visibleLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isLoading {
                ProgressView("Loading Up Next…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if loadError {
                ContentUnavailableView {
                    Label("Up Next Unavailable", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                } description: {
                    Text("The playback queue could not be read. Try again when your library is available.")
                } actions: {
                    Button("Try Again") {
                        reloadGeneration &+= 1
                    }
                }
            } else if let snapshot, snapshot.isIndependentPlayback {
                ContentUnavailableView {
                    Label("Nothing Queued Next", systemImage: "text.line.last.and.arrowtriangle.forward")
                } description: {
                    Text("This episode is playing independently. Add episodes to Up Next to continue listening.")
                } actions: {
                    openQueueButton
                }
            } else if visibleEntries.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Queued Next", systemImage: "text.line.last.and.arrowtriangle.forward")
                } description: {
                    Text("Add an episode to Up Next to continue listening after this one.")
                } actions: {
                    openQueueButton
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(visibleEntries) { entry in
                        UpcomingQueueRow(
                            entry: entry,
                            canMutate: snapshot?.isSmartPlaylist == false,
                            play: {
                                Task { await player.playEpisode(entry.episodeURL) }
                            },
                            moveNext: {
                                moveNext(entry)
                            },
                            moveEarlier: {
                                move(entry, by: -1)
                            },
                            moveLater: {
                                move(entry, by: 1)
                            },
                            remove: {
                                remove(entry)
                            }
                        )
                        .contextMenu {
                            rowActions(for: entry)
                        }
                    }
                    .onMove(perform: move)

                    if (snapshot?.upcoming.count ?? 0) > visibleEntries.count {
                        Button {
                            openQueue()
                        } label: {
                            Label(
                                "Open Full Queue (\((snapshot?.upcoming.count ?? 0) - visibleEntries.count) more)",
                                systemImage: "arrow.up.forward.app"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 8)
                    }
                }
            }
        }
        .padding()
        .task(id: reloadGeneration) {
            await reload()
        }
        .onChange(of: player.currentEpisodeURL) { _, _ in
            reloadGeneration &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .episodeReferencesDidChange)) { _ in
            reloadGeneration &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .smartPlaylistMembershipCacheDidInvalidate)) { _ in
            reloadGeneration &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPersistentStoreRemoteChange)) { _ in
            reloadGeneration &+= 1
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Upcoming queue")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Up Next")
                    .font(.headline)
                if let snapshot {
                    let count = snapshot.upcomingCount
                    let duration = QueueProjectionFormatting.duration(snapshot.remainingDuration)
                    Text(
                        duration.map { "\(count) episodes · \($0) remaining" }
                            ?? "\(count) episodes"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("The next episodes in the playback sequence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if snapshot?.playlistID != nil {
                openQueueButton
            }
        }
    }

    private var openQueueButton: some View {
        Button("Open Queue", systemImage: "arrow.up.forward.app") {
            openQueue()
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Opens the playlist that supplies playback")
    }

    @ViewBuilder
    private func rowActions(for entry: QueueEpisodeValue) -> some View {
        Button {
            Task { await player.playEpisode(entry.episodeURL) }
        } label: {
            Label("Play Now", systemImage: "play.fill")
        }

        if snapshot?.isSmartPlaylist == false {
            Button {
                moveNext(entry)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button(role: .destructive) {
                remove(entry)
            } label: {
                Label("Remove from Up Next", systemImage: "minus.circle")
            }
        } else {
            Text("Smart playlist order is automatic")
        }
    }

    private func moveNext(_ entry: QueueEpisodeValue) {
        guard let playlistID = snapshot?.playlistID,
              snapshot?.isSmartPlaylist == false else { return }
        Task {
            guard let actor = try? PlaylistModelActor(
                modelContainer: modelContext.container,
                playlistID: playlistID
            ) else { return }
            try? await actor.add(
                episodeURL: entry.episodeURL,
                to: .front,
                startDownload: false
            )
            reloadGeneration &+= 1
        }
    }

    private func remove(_ entry: QueueEpisodeValue) {
        guard let playlistID = snapshot?.playlistID,
              snapshot?.isSmartPlaylist == false else { return }
        Task {
            guard let actor = try? PlaylistModelActor(
                modelContainer: modelContext.container,
                playlistID: playlistID
            ) else { return }
            try? await actor.remove(episodeURL: entry.episodeURL)
            reloadGeneration &+= 1
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first,
              let snapshot,
              snapshot.isSmartPlaylist == false,
              let playlistID = snapshot.playlistID,
              visibleEntries.indices.contains(sourceIndex) else { return }

        let sourceOrder = visibleEntries[sourceIndex].orderIndex
        let destinationOrder: Int
        if destination >= visibleEntries.count {
            destinationOrder = (visibleEntries.last?.orderIndex ?? sourceOrder) + 1
        } else {
            destinationOrder = visibleEntries[destination].orderIndex
        }

        Task {
            guard let actor = try? PlaylistModelActor(
                modelContainer: modelContext.container,
                playlistID: playlistID
            ) else { return }
            try? await actor.moveEntry(from: sourceOrder, to: destinationOrder)
            reloadGeneration &+= 1
        }
    }

    private func move(_ entry: QueueEpisodeValue, by offset: Int) {
        guard let snapshot,
              snapshot.isSmartPlaylist == false,
              let playlistID = snapshot.playlistID,
              let currentIndex = snapshot.upcoming.firstIndex(where: { $0.id == entry.id }) else { return }
        let destination = currentIndex + offset
        guard snapshot.upcoming.indices.contains(destination) else { return }

        Task {
            guard let actor = try? PlaylistModelActor(
                modelContainer: modelContext.container,
                playlistID: playlistID
            ) else { return }
            let targetOrder = snapshot.upcoming[destination].orderIndex
            try? await actor.moveEntry(
                from: entry.orderIndex,
                to: targetOrder + (offset > 0 ? 1 : 0)
            )
            reloadGeneration &+= 1
        }
    }

    private func openQueue() {
        guard let playlistID = snapshot?.playlistID else { return }
        UserDefaults.standard.set(
            playlistID.uuidString,
            forKey: PlaylistPreferenceKeys.selectedPlaylistID
        )
        navigation?.select(.queue)
    }

    @MainActor
    private func reload() async {
        guard let currentEpisodeURL = player.currentEpisodeURL,
              let container = ModelContainerManager.shared.preparedContainer
                ?? Optional(modelContext.container) else {
            snapshot = nil
            isLoading = false
            return
        }

        isLoading = true
        loadError = false
        do {
            guard let playlistID = player.playbackQueuePlaylistID else {
                snapshot = UpcomingQueueSnapshot(
                    playlistID: nil,
                    playlistTitle: Playlist.defaultQueueDisplayName,
                    isSmartPlaylist: false,
                    currentEpisodeURL: currentEpisodeURL,
                    upcoming: [],
                    isIndependentPlayback: true
                )
                isLoading = false
                return
            }
            let actor = try PlaylistModelActor(
                modelContainer: container,
                playlistID: playlistID
            )
            let projection = try await actor.orderedQueueProjection()
            guard Task.isCancelled == false,
                  player.currentEpisodeURL == currentEpisodeURL else { return }
            snapshot = projection.upcoming(after: currentEpisodeURL)
        } catch {
            guard Task.isCancelled == false else { return }
            snapshot = nil
            loadError = true
        }
        isLoading = false
    }
}

private struct UpcomingQueueRow: View {
    let entry: QueueEpisodeValue
    let canMutate: Bool
    let play: () -> Void
    let moveNext: () -> Void
    let moveEarlier: () -> Void
    let moveLater: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                HStack(spacing: 10) {
                    CoverImageView(imageURL: entry.artworkURL, cornerRadius: 8)
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title)
                            .font(.body)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.podcastTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let duration = QueueProjectionFormatting.duration(entry.remainingDuration) {
                            Text(entry.hasPlaybackHistory ? "\(duration) remaining" : duration)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.title), \(entry.podcastTitle)")
            .accessibilityHint("Plays this episode now")

            Menu {
                Button(action: play) {
                    Label("Play Now", systemImage: "play.fill")
                }
                if canMutate {
                    Button(action: moveNext) {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button(action: moveEarlier) {
                        Label("Move Earlier", systemImage: "arrow.up")
                    }
                    Button(action: moveLater) {
                        Label("Move Later", systemImage: "arrow.down")
                    }
                    Button(role: .destructive, action: remove) {
                        Label("Remove from Up Next", systemImage: "minus.circle")
                    }
                }
            } label: {
                Label("Episode actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Actions for \(entry.title)")
        }
        .padding(.vertical, 6)
    }
}
