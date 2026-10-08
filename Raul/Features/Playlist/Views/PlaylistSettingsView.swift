//
//  PlaylistSettingsView.swift
//  Raul
//

import SwiftUI
import SwiftData

/// Everything about one playlist that is not its contents: its name and icon,
/// its own download policy, what a play elsewhere does to it, and which podcasts
/// feed into it.
struct PlaylistSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openPodcastSettings) private var openPodcastSettings

    @Bindable var playlist: Playlist

    @Query private var playlistEntries: [PlaylistEntry]
    @Query private var allPlaylists: [Playlist]

    @State private var draftName: String = ""
    @State private var smartFilterDraft = SmartPlaylistFilter()
    @State private var routedPodcasts: [PlaylistRoutedPodcast] = []
    @State private var hasLoadedRoutedPodcasts = false
    @FocusState private var isNameFocused: Bool

    init(playlist: Playlist) {
        self.playlist = playlist
        let playlistID = playlist.id
        _playlistEntries = Query(
            filter: #Predicate<PlaylistEntry> { entry in
                entry.playlist?.id == playlistID
            },
            sort: [SortDescriptor(\PlaylistEntry.order, order: .forward)]
        )
    }

    private var episodeCount: Int {
        playlistEntries.reduce(into: 0) { partialResult, entry in
            if entry.episode != nil {
                partialResult += 1
            }
        }
    }

    /// The built-in queue stores a reserved title that `ensureDefaultQueue`
    /// rewrites on every launch, so its name is the one thing here that cannot
    /// be edited.
    private var isDefaultQueue: Bool {
        playlist.title == Playlist.defaultQueueTitle
    }

    private var isLimited: Bool {
        playlist.autoDownloadEpisodeLimit != nil
    }

    private var limitValue: Int {
        playlist.resolvedAutoDownloadEpisodeLimit ?? Playlist.defaultAutoDownloadEpisodeLimit
    }

    var body: some View {
        Form {
            Section("Name") {
                if isDefaultQueue {
                    LabeledContent("Name") {
                        Text(Playlist.defaultQueueDisplayName)
                            .foregroundStyle(.secondary)
                    }

                    Text("This is the built-in queue, so its name is fixed. You can still give it any icon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Name", text: $draftName)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .onSubmit { commitName() }
                        .accessibilityLabel("Playlist name")
                }
            }

            Section("Icon") {
                PlaylistSymbolGridPicker(
                    selection: Binding(
                        get: { playlist.displaySymbolName },
                        set: { symbolName in
                            playlist.symbolName = symbolName
                            save()
                        }
                    )
                )
            }

            if playlist.isSmartPlaylist {
                SmartPlaylistFilterEditor(filter: $smartFilterDraft)
                Text("Smart playlists contain matching library episodes automatically. Membership is derived and does not change your manual playlists or queue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
            Section("Automatic Downloads") {
                Toggle(
                    "Download episodes automatically",
                    isOn: Binding(
                        get: { playlist.autoDownloadEnabled },
                        set: { isEnabled in
                            playlist.autoDownloadEnabled = isEnabled
                            save()
                        }
                    )
                )

                if playlist.autoDownloadEnabled {
                    Toggle(
                        "Limit downloaded episodes",
                        isOn: Binding(
                            get: { isLimited },
                            set: { shouldLimit in
                                playlist.autoDownloadEpisodeLimit = shouldLimit
                                    ? limitValue
                                    : nil
                                save()
                            }
                        )
                    )

                    if isLimited {
                        Stepper(
                            value: Binding(
                                get: { limitValue },
                                set: { newLimit in
                                    playlist.autoDownloadEpisodeLimit = newLimit
                                    save()
                                }
                            ),
                            in: Playlist.autoDownloadEpisodeLimitRange,
                            step: 1
                        ) {
                            LabeledContent("Download at most") {
                                Text("\(limitValue)")
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                Text(downloadExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Played Episodes") {
                Toggle(
                    "Remove episodes played in another playlist",
                    isOn: Binding(
                        get: { playlist.removesEpisodesPlayedElsewhere },
                        set: { removesPlayedElsewhere in
                            playlist.removesEpisodesPlayedElsewhere = removesPlayedElsewhere
                            save()
                        }
                    )
                )

                Text(
                    playlist.removesEpisodesPlayedElsewhere
                        ? "An episode you finish anywhere else also leaves this playlist. Finishing an episode here always removes it from this playlist."
                        : "This playlist keeps its episodes even after you finish them in another playlist. Finishing an episode here still removes it from this playlist."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            routedPodcastsSection
            }

            Section {
                LabeledContent("Episodes in playlist") {
                    Text(episodeCount, format: .number)
                        .monospacedDigit()
                }
            }
        }
        .navigationTitle(playlist.displayTitle)
        .platformInlineNavigationTitle()
        .task {
            draftName = playlist.displayTitle
            smartFilterDraft = playlist.smartFilter ?? SmartPlaylistFilter()
            await loadRoutedPodcasts()
        }
        .onChange(of: isNameFocused) { _, isFocused in
            if isFocused == false {
                commitName()
            }
        }
        .onDisappear {
            commitName()
            commitSmartFilter()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .podcastSettingsDidChange)
        ) { _ in
            Task { await loadRoutedPodcasts() }
        }
    }

    @ViewBuilder
    private var routedPodcastsSection: some View {
        Section("Podcasts Added Automatically") {
            if hasLoadedRoutedPodcasts == false {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking podcasts…")
                        .foregroundStyle(.secondary)
                }
            } else if routedPodcasts.isEmpty {
                Text("No podcast puts its new episodes here. A podcast's own settings decide which playlist it fills.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(routedPodcasts) { podcast in
                    Button {
                        openPodcastSettings()
                    } label: {
                        routedPodcastRow(podcast)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens podcast settings")
                }

                Text("New episodes of these podcasts are queued into this playlist as they arrive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func routedPodcastRow(_ podcast: PlaylistRoutedPodcast) -> some View {
        HStack(spacing: 12) {
            CoverImageView(imageURL: podcast.imageURL)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title)
                    .lineLimit(2)

                Text(subtitle(for: podcast))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func subtitle(for podcast: PlaylistRoutedPodcast) -> LocalizedStringKey {
        switch (podcast.position, podcast.usesCustomSettings) {
        case (.front, true):
            return "Added to the top · Podcast setting"
        case (.front, false):
            return "Added to the top · Global default"
        case (.end, true):
            return "Added to the bottom · Podcast setting"
        case (.end, false):
            return "Added to the bottom · Global default"
        case (.none, _):
            // Never routed here; kept exhaustive rather than silently mislabelled.
            return "Not added automatically"
        }
    }

    private var downloadExplanation: LocalizedStringKey {
        guard playlist.autoDownloadEnabled else {
            return "Episodes in this playlist are only downloaded when you start them or when a podcast's own automatic downloads cover them."
        }

        if isLimited {
            return "Keeps the first episodes of this playlist downloaded, in playlist order. Later episodes download as the ones above them leave the playlist. Downloads already on this device are never deleted by this setting."
        }

        return "Downloads every episode in this playlist. Turn on the limit to keep only the next few episodes on this device."
    }

    private func loadRoutedPodcasts() async {
        routedPodcasts = await PodcastSettingsModelActor(
            modelContainer: modelContext.container
        ).podcastsRouted(toPlaylistID: playlist.id)
        hasLoadedRoutedPodcasts = true
    }

    private func commitName() {
        guard isDefaultQueue == false else { return }

        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            draftName = playlist.displayTitle
            return
        }
        guard trimmed != playlist.title else { return }

        // Keep names distinct the same way creating a playlist does, so two
        // playlists never end up indistinguishable in the picker.
        let uniqueName = Playlist.normalizedPlaylistName(
            trimmed,
            existing: allPlaylists.filter { $0.id != playlist.id }
        )
        playlist.title = uniqueName
        draftName = uniqueName
        save()
    }

    private func commitSmartFilter() {
        guard playlist.isSmartPlaylist,
              playlist.smartFilter != smartFilterDraft else { return }
        playlist.smartFilter = smartFilterDraft
        save()
    }

    private func save() {
        modelContext.saveIfNeeded()
        StoreSplitPlaylistSyncCoordinator.publish(playlist)

        guard playlist.autoDownloadEnabled else { return }
        PlaylistAutoDownloadCoordinator.schedule(
            playlistID: playlist.id,
            modelContainer: modelContext.container,
            force: true
        )
    }
}
