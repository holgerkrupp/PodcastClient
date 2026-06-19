import SwiftData
import SwiftUI

enum AppWindowID {
    static let main = "main"
    static let player = "player"
}

#if os(macOS)
struct MacPlayerWindowContent: View {
    var body: some View {
        NavigationStack {
            PlayerView(fullSize: true)
                .navigationTitle("Now Playing")
        }
        .frame(minWidth: 520, minHeight: 560)
    }
}

struct MacMenuBarLabel: View {
    let isPlayerReady: Bool

    var body: some View {
        if isPlayerReady {
            MacReadyMenuBarLabel()
        } else {
            Image(systemName: "waveform")
                .accessibilityLabel("Up Next is starting")
        }
    }
}

private struct MacReadyMenuBarLabel: View {
    @Bindable private var player = Player.shared

    var body: some View {
        Group {
            if let episode = player.currentEpisode {
                MacMenuBarArtworkView(episode: episode)
            } else {
                Image(systemName: "waveform")
            }
        }
        .frame(width: 14, height: 14)
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let episode = player.currentEpisode else {
            return "Up Next, nothing playing"
        }
        return "Up Next, \(player.isPlaying ? "playing" : "paused"), \(episode.title)"
    }
}

private struct MacMenuBarArtworkView: View {
    let episode: Episode

    @State private var artwork: Image?

    var body: some View {
        Group {
            if let artwork {
                artwork
            } else {
                Image(systemName: "waveform")
            }
        }
        .frame(width: 14, height: 14)
        .clipShape(.rect(cornerRadius: 2))
        .task(id: artworkURL) {
            guard let artworkURL,
                  let image = await ImageLoaderAndCache.loadUIImage(from: artworkURL),
                  let cgImage = image.cgImage,
                  let thumbnail = cgImage.squareThumbnail(side: 14) else {
                artwork = nil
                return
            }

            artwork = Image(decorative: thumbnail, scale: 1)
        }
    }

    private var artworkURL: URL? {
        episode.imageURL ?? episode.podcast?.imageURL
    }
}

private extension CGImage {
    func squareThumbnail(side: Int) -> CGImage? {
        let cropSide = min(width, height)
        let cropRect = CGRect(
            x: (width - cropSide) / 2,
            y: (height - cropSide) / 2,
            width: cropSide,
            height: cropSide
        )

        guard let cropped = cropping(to: cropRect),
              let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
}

struct MacMenuBarPlayerView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            MacCompactPlayerView()
                .padding(16)

            Divider()

            HStack {
                Button {
                    openWindow(id: AppWindowID.player)
                } label: {
                    Label("Open Player", systemImage: "rectangle.on.rectangle")
                }

                Spacer()

                Button {
                    openWindow(id: AppWindowID.main)
                } label: {
                    Label("Open Up Next", systemImage: "macwindow")
                }
            }
            .labelStyle(.titleOnly)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            MacSelectedPlaylistView()
                .frame(maxHeight: .infinity)
        }
        .frame(width: 420, height: 620)
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct MacCompactPlayerView: View {
    @Bindable private var player = Player.shared

    var body: some View {
        Group {
            if let episode = player.currentEpisode {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        MacEpisodeArtworkView(
                            episode: episode,
                            size: 64,
                            cornerRadius: 8
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(episode.title)
                                .font(.headline)
                                .lineLimit(2)

                            Text(episode.displayPodcastTitle ?? episode.author ?? "Podcast")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }

                    VStack(spacing: 4) {
                        Slider(value: $player.progress, in: 0...1)

                        HStack {
                            Text(formattedTime(player.playPosition))
                            Spacer()
                            Text("-\(formattedTime(max(player.remaining ?? 0, 0)))")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 28) {
                        Button {
                            player.remoteSkipBack()
                        } label: {
                            Image(
                                systemName: player.remoteSkipBackUsesChapter
                                    ? "backward.end.fill"
                                    : player.skipBackStep.triangleBackString
                            )
                        }
                        .help(player.remoteSkipBackUsesChapter ? "Previous Chapter" : "Skip Back")

                        Button {
                            togglePlayback()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .keyboardShortcut(.space, modifiers: [])
                        .help(player.isPlaying ? "Pause" : "Play")

                        Button {
                            player.remoteSkipForward()
                        } label: {
                            Image(
                                systemName: player.remoteSkipForwardUsesChapter
                                    ? "forward.end.fill"
                                    : player.skipForwardStep.triangleForwardString
                            )
                        }
                        .help(player.remoteSkipForwardUsesChapter ? "Next Chapter" : "Skip Forward")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                }
            } else {
                ContentUnavailableView(
                    "Nothing Playing",
                    systemImage: "waveform",
                    description: Text("Choose an episode from the playlist below.")
                )
                .frame(maxWidth: .infinity, minHeight: 140)
            }
        }
    }

    private func togglePlayback() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(Int(seconds.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

private struct MacSelectedPlaylistView: View {
    @Query(sort: [
        SortDescriptor(\Playlist.sortIndex, order: .forward),
        SortDescriptor(\Playlist.title, order: .forward)
    ])
    private var playlists: [Playlist]
    @Query(sort: \PlaylistEntry.order, order: .forward)
    private var playlistEntries: [PlaylistEntry]

    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID)
    private var storedPlaylistID = ""
    @Bindable private var player = Player.shared

    private var visiblePlaylists: [Playlist] {
        Playlist.manualVisibleSorted(playlists)
    }

    private var selectedPlaylist: Playlist? {
        if let selectedID = Playlist.resolvePlaylistID(from: storedPlaylistID),
           let selected = visiblePlaylists.first(where: { $0.id == selectedID }) {
            return selected
        }
        return visiblePlaylists.first(where: { $0.title == Playlist.defaultQueueTitle })
            ?? visiblePlaylists.first
    }

    private var upcomingEntries: [PlaylistEntry] {
        guard let selectedPlaylist else { return [] }
        let entries = playlistEntries.filter { $0.playlist?.id == selectedPlaylist.id }
        guard let currentURL = player.currentEpisodeURL,
              let currentIndex = entries.firstIndex(where: { $0.episode?.url == currentURL }) else {
            return entries
        }
        return Array(entries.dropFirst(currentIndex + 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(visiblePlaylists) { playlist in
                        Button {
                            storedPlaylistID = playlist.id.uuidString
                        } label: {
                            Label(playlist.displayTitle, systemImage: playlist.displaySymbolName)
                        }
                    }
                } label: {
                    Label(
                        selectedPlaylist?.displayTitle ?? Playlist.defaultQueueDisplayName,
                        systemImage: selectedPlaylist?.displaySymbolName
                            ?? Playlist.defaultQueueSymbolName
                    )
                    .font(.headline)
                }

                Spacer()

                Text("\(upcomingEntries.count) next")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if upcomingEntries.isEmpty {
                ContentUnavailableView(
                    "Nothing Up Next",
                    systemImage: "text.line.last.and.arrowtriangle.forward",
                    description: Text("This playlist has no later episodes.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(upcomingEntries) { entry in
                    if let episode = entry.episode {
                        Button {
                            Task {
                                await player.playEpisode(episode.url)
                            }
                        } label: {
                            MacPlaylistEpisodeRow(episode: episode)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.visible)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct MacPlaylistEpisodeRow: View {
    let episode: Episode

    var body: some View {
        HStack(spacing: 10) {
            MacEpisodeArtworkView(
                episode: episode,
                size: 38,
                cornerRadius: 5
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .lineLimit(1)

                Text(episode.displayPodcastTitle ?? episode.author ?? "Podcast")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "play.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .padding(.vertical, 3)
    }
}

struct MacEpisodeArtworkView: View {
    let episode: Episode
    let size: CGFloat
    let cornerRadius: CGFloat
    var fallbackSystemImage = "photo"

    @State private var artwork: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)

            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Image(systemName: fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.22)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .fixedSize()
        .task(id: artworkURL) {
            guard let artworkURL else {
                artwork = nil
                return
            }
            artwork = await ImageLoaderAndCache.loadUIImage(from: artworkURL)
        }
    }

    private var artworkURL: URL? {
        episode.imageURL ?? episode.podcast?.imageURL
    }
}

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.appNavigationModel) private var navigation
    @Binding var settingsRequest: SettingsWindowRequest
    let isPlayerReady: Bool

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                settingsRequest = .global
                openWindow(id: SettingsWindowRequest.sceneID)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Navigate") {
            sectionButton(.queue, key: "1")
            sectionButton(.inbox, key: "2")
            sectionButton(.library, key: "3")
            sectionButton(.search, key: "4")
            Divider()
            sectionButton(.downloads, key: "5")
            sectionButton(.bookmarks, key: "6")
            sectionButton(.history, key: "7")
        }

        CommandMenu("Playback") {
            Button("Open Player") {
                openWindow(id: AppWindowID.player)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(isPlayerReady == false)

            Divider()

            Button("Play/Pause") {
                guard isPlayerReady else { return }
                if Player.shared.isPlaying {
                    Player.shared.pause()
                } else {
                    Player.shared.play()
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(isPlayerReady == false)

            Button("Skip Back") {
                guard isPlayerReady else { return }
                Player.shared.skipback()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            .disabled(isPlayerReady == false)

            Button("Skip Forward") {
                guard isPlayerReady else { return }
                Player.shared.skipforward()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            .disabled(isPlayerReady == false)
        }
    }

    private func sectionButton(_ section: AppSection, key: KeyEquivalent) -> some View {
        Button(section.sidebarTitle) {
            navigation?.select(section)
        }
        .keyboardShortcut(key, modifiers: .command)
        .disabled(navigation == nil)
    }
}
#endif
