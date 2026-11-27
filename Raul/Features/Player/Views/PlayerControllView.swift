//
//  PlayerControllView.swift
//  Raul
//
//  Created by Holger Krupp on 27.06.25.
//
import SwiftUI
import SwiftData
import AVFoundation
import AVKit
import TipKit

/// The player shell. It observes only the current episode identity and its own
/// presentation state; every frequently changing value (playback ticks, live
/// cues, sleep countdown, chapter-skip history, generation progress) is read by
/// a narrow island further down so it cannot rebuild this hierarchy (#520).
struct PlayerControllView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openPodcastSettings) private var openSettings

    @State private var showTranscripts: Bool = false

    @State private var showFullTranscripts: Bool = false
    @State private var openFullTranscriptFollowingPlayback: Bool = false
#if os(iOS)
    @State private var settingsRequest: SettingsWindowRequest?
#endif
    var showPrimaryTransportControls: Bool = true
    /// The enclosing player derives this from its live scene geometry. A nil
    /// value preserves the cover's natural square presentation for inline use.
    var mediaHeight: CGFloat?
    var showsMedia = true
    var showsInlineTranscript = true
    var showsTranscriptOverHero = false
    var showsPlaybackUtilities = true
    /// Prepared off-main by `PlayerContentAvailabilityModelActor`. Nil means
    /// unknown: transcript/chapter affordances wait for it instead of faulting
    /// relationships during body evaluation.
    var contentAvailability: PlayerContentAvailability?

    private var player: Player { .shared }

    var body: some View {
        if let episode = player.currentEpisode {
            VStack(spacing: 8) {
                if showsMedia, let mediaHeight {
                    VStack(spacing: 0) {
                        PlayerMediaSurface(episodeURL: episode.url)
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(
                                height: showsInlineTranscript && showTranscripts
                                    ? mediaHeight * 0.6
                                    : mediaHeight,
                                alignment: .top
                            )

                        if showsInlineTranscript, showTranscripts {
                            transcriptCard(episode: episode)
                            .frame(maxWidth: .infinity, maxHeight: mediaHeight * 0.4, alignment: .topLeading)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityHint("Scroll to read along. Tap a caption to open the full transcript.")
                            .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: mediaHeight, alignment: .top)
                    .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85), value: showTranscripts)
                } else if showsMedia {
                    PlayerMediaSurface(episodeURL: episode.url)
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                } else if !showsTranscriptOverHero,
                          showsInlineTranscript,
                          showTranscripts {
                    transcriptCard(episode: episode)
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                
                PlayerChapterControlSlot(
                    episode: episode,
                    showTranscripts: $showTranscripts,
                    showsInlineTranscript: showsInlineTranscript,
                    showsTranscriptOverHero: showsTranscriptOverHero,
                    contentAvailability: contentAvailability,
                    onOpenPlaybackSettings: openPlaybackSettings
                )

                ChapterSkipSuggestionIsland(episode: episode) { podcast, suggestion in
                    openSuggestedChapterRule(for: podcast, suggestion: suggestion)
                }
                
                Text("\(episode.title)")
                    .font(.body)
                    .lineLimit(2)
                    .esaForeground(.primary)
                
                
                PlayerPlaybackTimelineView()

                PlayerSkipProtectionUndoIsland()

                if showPrimaryTransportControls {
                    PlayerPrimaryTransportControlsView(includeBookmark: true)
                        .tint(.primary)
                }

                if showsPlaybackUtilities {
                    PlayerPlaybackUtilitiesRow()
                }
            }
            .padding()
            .onAppear {
                if showPrimaryTransportControls {
                    PlayerOpeningPerformance.controlsResponsive()
                }
            }
            .overlay(alignment: .top) {
                if showsTranscriptOverHero,
                   showsInlineTranscript,
                   showTranscripts {
                    transcriptCard(episode: episode)
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                    .offset(y: -132)
                    .accessibilityHint("Scroll to read along. Tap a caption to open the full transcript.")
                }
            }
            .sheet(isPresented: $showFullTranscripts, onDismiss: {
                openFullTranscriptFollowingPlayback = false
            }) {
                NavigationStack {
                    TranscriptPane(
                        episode: episode,
                        availability: contentAvailability,
                        startFollowingPlayback: openFullTranscriptFollowingPlayback
                    )
                    .navigationTitle("Captions & Transcript")
                    .platformInlineNavigationTitle()
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .onAppear { PlayerOpeningPerformance.interactionVisible(.fullTranscript) }
            }
#if os(iOS)
            .sheet(item: $settingsRequest) { request in
                SettingsWindowContent(request: request)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .onAppear { PlayerOpeningPerformance.interactionVisible(.settingsSheet) }
            }
#endif
        }
    }

    private func transcriptCard(episode: Episode) -> some View {
        PlayerTranscriptOverlayHost(episode: episode) { followPlayback in
            PlayerOpeningPerformance.beginInteraction(.fullTranscript)
            openFullTranscriptFollowingPlayback = followPlayback
            showFullTranscripts = true
        }
        .onAppear { PlayerOpeningPerformance.interactionVisible(.transcriptShow) }
        .onDisappear { PlayerOpeningPerformance.interactionVisible(.transcriptHide) }
    }

    private func openPlaybackSettings() {
        let request = SettingsWindowRequest.playback(for: player.currentEpisode?.podcast)
#if os(iOS)
        settingsRequest = request
#else
        openSettings(request)
        PlayerOpeningPerformance.interactionVisible(.settingsSheet)
#endif
    }

    private func openSuggestedChapterRule(
        for podcast: Podcast,
        suggestion: ChapterSkipRuleSuggestion
    ) {
        let request = SettingsWindowRequest.suggestedChapterRule(
            for: podcast,
            suggestion: suggestion
        )
#if os(iOS)
        settingsRequest = request
#else
        openSettings(request)
#endif
    }

}

private struct PlayerPlaybackTimelineView: View {
    @Environment(\.openURL) private var openURL
    @Bindable private var player = Player.shared
    @Query(filter: #Predicate<PodcastSettings> { $0.title == "de.holgerkrupp.podbay.queue" })
    private var globalSettings: [PodcastSettings]

    var body: some View {
        Group {
        if player.isLivePlayback {
            VStack(spacing: 8) {
                Label(player.livePlaybackState.label, systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                Button {
                    Task { await player.endLivePlayback() }
                } label: {
                    Label("Return to Previous Episode", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Stops live playback and restores the previous episode and its position")

                if globalSettings.first?.showLivePodcasts != false,
                   let liveItem = player.currentLiveItem,
                   (liveItem.chat.isEmpty == false || liveItem.contentLinks.isEmpty == false) {
                    Menu {
                        ForEach(liveItem.chat) { chat in
                            Button {
                                openURL(chat.url)
                            } label: {
                                Label(chat.label, systemImage: "bubble.left.and.bubble.right")
                            }
                        }
                        ForEach(liveItem.contentLinks) { contentLink in
                            Button {
                                openURL(contentLink.url)
                            } label: {
                                Label(contentLink.label, systemImage: "link")
                            }
                        }
                    } label: {
                        Label("Companion Links", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Opens publisher-provided chat and live companion pages")
                }
            }
        } else {
            VStack {
                PlayerProgressSliderView(
                    value: $player.progress,
                    markers: $player.chapters,
                    allowTouch: globalSettings.first?.enableInAppSlider ?? true,
                    chapterTimelineDuration: player.currentEpisode?.duration,
                    adSegments: player.showDetectedAdvertisements ? player.adSegments : [],
                    onEditingChanged: { isEditing, progress in
                        if isEditing {
                            PlayerOpeningPerformance.noteInteraction()
                            player.beginSkipProtectionSeek()
                        } else {
                            player.endSkipProtectionSeek(at: progress)
                        }
                    },
                    sliderRange: 0...1
                )
                .frame(height: 30)

                HStack {
                    Text(Duration.seconds(player.playPosition).formatted(.units(width: .narrow)))
                        .monospacedDigit()
                        .font(.caption)
                        .esaForeground(.secondary)

                    Spacer()
                    Text(Duration.seconds(player.remaining ?? player.currentEpisode?.duration ?? 0.0).formatted(.units(width: .narrow)))
                        .monospacedDigit()
                        .font(.caption)
                        .esaForeground(.secondary)
                }
            }
        }
        }
        .onAppear {
            PlayerOpeningPerformance.event("Player timeline settings appeared")
        }
    }
}

/// Playback speed, AirPlay, furthest position and sleep timer. Each control is
/// its own island so the sleep countdown or a persisted play position updates
/// only the button that displays it.
struct PlayerPlaybackUtilitiesRow: View {
    var body: some View {
        ZStack {
            airPlayButton

            HStack(spacing: 10) {
                PlayerPlaybackSpeedControl()
                Spacer(minLength: 0)

                PlayerMaxPlayPositionButton()

                PlayerSleepTimerControl()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .zIndex(3)
    }

    private var airPlayButton: some View {
        AirPlayButtonView()
            .tint(.primary)
            .esaForeground(.primary)
            .frame(width: 44, height: 44)
            .glassEffect(.regular, in: Circle())
            .accessibilityLabel("AirPlay")
            .accessibilityHint("Choose an audio output device")
            .help("Choose where audio plays")
    }
}

private struct PlayerPlaybackSpeedControl: View {
    @Bindable private var player = Player.shared
    @State private var showPlaybackSpeedSettings = false
    @State private var currentAudioSettings: PodcastSettings?

    var body: some View {
        playbackSpeedButton
            .sheet(isPresented: $showPlaybackSpeedSettings) {
                audioSpeedSettingsSheet
            }
    }

    private var playbackSpeedButton: some View {
        Button {
            PlayerOpeningPerformance.beginInteraction(.speedSheet)
            currentAudioSettings = player.audioSpeedSettingsModel()
            showPlaybackSpeedSettings = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                Text(playbackSpeedButtonTitle)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(playbackSpeedButtonTitle)
        .accessibilityHint("Opens playback speed controls")
        .help("Change how fast episodes play")
        .accessibilityInputLabels([Text("Playback speed"), Text("Speed")])
    }

    private var playbackSpeedButtonTitle: String {
        player.playbackRate.formatted(.number.precision(.fractionLength(0...1))) + "x"
    }

    private var audioSpeedSettingsSheet: some View {
        NavigationStack {
            Form {
                if let currentAudioSettings {
                    AudioSpeedSettingsSection(
                        settings: currentAudioSettings,
                        scope: .currentPlayback,
                        onChange: { player.applyAudioSpeedSettings(currentAudioSettings) }
                    )
                }
            }
            .navigationTitle("Audio & Speed")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
        .onAppear { PlayerOpeningPerformance.interactionVisible(.speedSheet) }
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
    }
}

private struct PlayerMaxPlayPositionButton: View {
    private var player: Player { .shared }
    private let furthestPositionTip = FurthestPositionTip()

    var body: some View {
        if let maxPlay = player.currentEpisode?.metaData?.maxPlayposition,
           maxPlay - 5 > player.currentEpisode?.metaData?.playPosition ?? 0 {
            button(maxPlay: maxPlay)
        }
    }

    private func button(maxPlay: Double) -> some View {
        Button {
            furthestPositionTip.invalidate(reason: .actionPerformed)
            Task { await player.jumpTo(time: maxPlay) }
        } label: {
            Label("Max play position", systemImage: "forward.end.alt.fill")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Jump to max play position")
        .accessibilityHint("Jumps to the furthest point you have listened to in this episode")
        .help("Jump to the furthest point you've listened to")
        .popoverTip(furthestPositionTip)
    }
}

private struct PlayerSleepTimerControl: View {
    private var player: Player { .shared }
    @State private var showSleepTimerSettings = false

    var body: some View {
        sleepTimerButton
            .sheet(isPresented: $showSleepTimerSettings) {
                PlayerSleepTimerSheet()
            }
    }

    private var sleepTimerButton: some View {
        Button {
            PlayerOpeningPerformance.beginInteraction(.sleepSheet)
            showSleepTimerSettings = true
        } label: {
            Image(systemName: "zzz")
                .tint(player.remainingTime == nil && player.stopAfterEpisode == false ? .primary : .accent)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(sleepTimerAccessibilityValue)
        .accessibilityHint("Opens sleep timer controls")
        .help("Stop playback after a set time or at the end of the episode")
        .accessibilityInputLabels([Text("Sleep timer"), Text("Timer")])
    }

    private var sleepTimerAccessibilityValue: String {
        if player.isStopAfterChapterEnabled {
            let title = player.stopAfterChapterTitle ?? "current chapter"
            let countdown = Duration.seconds(player.remainingTime ?? 0).formatted(.units(width: .wide))
            return "Stop at end of \(title), in \(countdown)"
        }
        if let remaining = player.remainingTime {
            return Duration.seconds(remaining).formatted(.units(width: .wide))
        }

        if player.stopAfterEpisode {
            return "Stop after this episode"
        }

        return "Off"
    }
}

private struct PlayerSleepTimerSheet: View {
    @Bindable private var player = Player.shared

    var body: some View {
        List {
            Section(header: Label("Sleep timer", systemImage: "zzz")) {
                if player.isStopAfterChapterEnabled {
                    HStack {
                        Label(
                            "Stop at end of \(player.stopAfterChapterTitle ?? "chapter")",
                            systemImage: "bookmark"
                        )
                        Spacer()
                        Text(Duration.seconds(player.remainingTime ?? 0).formatted(.units(width: .narrow)))
                            .monospacedDigit()
                            .accessibilityLabel("Time remaining")
                    }
                    .accessibilityElement(children: .combine)
                }

                
                if player.isStopAfterChapterEnabled || player.remainingTime != nil || player.stopAfterEpisode {
                    
                        Button("Off / Cancel sleep timer", systemImage: "xmark.circle", role: .destructive) {
                            player.cancelSleepTimer()
                        }
                        .accessibilityHint("Turns off timed, chapter, and episode-end sleep modes")
                    
                }else{
                    Text("Choose a duration, chapter, or episode end. Selecting one replaces the active sleep mode.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            }

            if player.canRestartLastSleepTimer == true,
               player.isStopAfterChapterEnabled == false,
               player.remainingTime == nil,
               player.stopAfterEpisode == false {
                Section(header: Label("Recent timer", systemImage: "arrow.clockwise")) {
                    Button {
                        _ = player.restartLastSleepTimer()
                    } label: {
                        Label(
                            "Restart Last Timer",
                            systemImage: "arrow.clockwise.circle"
                        )
                    }
                    .accessibilityValue(player.lastSleepTimerSummary ?? "")
                    .accessibilityHint("Restores the last sleep timer setting")
                }
            }

            

            Section(header: Label("Timed sleep", systemImage: "clock")) {
                SleepTimerView()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))

                Toggle(isOn: $player.stopAfterEpisode) {
                    Text("Stop after this episode")
                }
                .tint(.accent)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
            }
            Section(header: Label("Stop after chapter", systemImage: "bookmark")) {
                if player.chapterSleepTimerOptions.isEmpty {
                    Text("No current or upcoming chapter has a known end time.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(player.chapterSleepTimerOptions) { option in
                        Button {
                            _ = player.stopAfterChapter(option)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(option.title)
                                            .lineLimit(2)
                                        if option.isCurrent {
                                            Text("Current")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(Duration.seconds(option.start).formatted(.units(width: .narrow)))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 8)

                                if player.isSelectedChapter(option) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            option.isCurrent ? "\(option.title), current chapter" : option.title
                        )
                        .accessibilityValue(
                            player.isSelectedChapter(option) ? "Selected" : "Starts at \(Duration.seconds(option.start).formatted(.units(width: .wide)))"
                        )
                        .accessibilityHint("Stops playback at the end of this chapter")
                    }
                }
            }
            
        }
        .listStyle(.plain)
        .padding()
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .onAppear { PlayerOpeningPerformance.interactionVisible(.sleepSheet) }
#if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
#endif
    }
}

struct PlayerMediaView: View {
    let player: AVPlayer
    let isVideo: Bool
    let artworkImage: UIImage?

    var body: some View {
        Group {
            if isVideo {
                NativeVideoPlayerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(Text(verbatim: "Video player"))
            } else if let artworkImage {
                Image(uiImage: artworkImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Color.accent)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .esaForeground(.secondary)
                    }
            }
        }
    }
}

private struct NativeVideoPlayerView: View {
    let player: AVPlayer

    var body: some View {
        VideoPlayer(player: player)
    }
}

struct PlayerPrimaryTransportControlsView: View {
    @Bindable private var player = Player.shared
    var includeBookmark: Bool = false
    @ScaledMetric(relativeTo: .body) private var centerControlsSpacing: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var skipIconOpticalOffset: CGFloat = 2
    @ScaledMetric(relativeTo: .body) private var playIconOpticalOffset: CGFloat = 2
    @State private var showClipExport = false
    @State private var bookmarkError: String?

    var body: some View {
        ZStack {
            HStack(spacing: centerControlsSpacing) {
                Button(action: {
                    PlayerOpeningPerformance.noteInteraction()
                    player.skipback()
                }) {
                    Label {
                        Text("Skip back")
                    } icon: {
                        Image(systemName: player.skipBackStep.triangleBackString)
                            .resizable()
                            .scaledToFit()
                            .offset(y: -skipIconOpticalOffset)
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                .frame(width: 50)
                .accessibilityLabel("Skip back \(player.skipBackStep.rawValue) seconds")
                .accessibilityHint("Moves playback backward by \(player.skipBackStep.rawValue) seconds")
                .help("Go back \(player.skipBackStep.rawValue) seconds")
                .accessibilityInputLabels([Text("Skip back"), Text("Back \(player.skipBackStep.rawValue) seconds")])
                
                Button(action: {
                    PlayerOpeningPerformance.beginInteraction(.playPause)
                    if player.isPlaying {
                        player.pause()
                    } else {
                        player.play()
                    }
                }) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(5)
                        .offset(x: player.isPlaying ? 0 : playIconOpticalOffset )
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                .frame(width: 80)
                .accessibilityLabel(player.isPlaying ? "Pause playback" : "Start playback")
                .accessibilityHint(player.isPlaying ? "Pauses the current episode" : "Starts playing the current episode")
                .accessibilityInputLabels([Text("Play"), Text("Pause"), Text("Playback")])
                
                Button(action: {
                    PlayerOpeningPerformance.noteInteraction()
                    player.skipforward()
                }) {
                    Label {
                        Text("Skip forward")
                    } icon: {
                        Image(systemName: player.skipForwardStep.triangleForwardString)
                            .resizable()
                            .scaledToFit()
                            .offset(y: -skipIconOpticalOffset)
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                .frame(width: 50)
                .accessibilityLabel("Skip forward \(player.skipForwardStep.rawValue) seconds")
                .accessibilityHint("Moves playback forward by \(player.skipForwardStep.rawValue) seconds")
                .help("Go forward \(player.skipForwardStep.rawValue) seconds")
                .accessibilityInputLabels([Text("Skip forward"), Text("Forward \(player.skipForwardStep.rawValue) seconds")])
            }

            HStack {

#if os(iOS)
                Button(action: { showClipExport = true }) {
                    Label {
                        Text("Create audio clip")
                    } icon: {
                        Image(systemName: "scissors")
                            .resizable()
                            .scaledToFit()
                    }
                    .labelStyle(.iconOnly)
                }
                
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .frame(height: 30)
                .help("Share audio clip")
                .accessibilityLabel("Create audio clip")
                .accessibilityHint("Opens clip export for the current episode")
                .sheet(isPresented: $showClipExport) {
                    if let episode = player.currentEpisode, let audioURL = player.currentPlaybackURL {
                        AudioClipExportView(
                            title: episode.title,
                            episodeURL: episode.url,
                            episodeLink: episode.link,
                            audioURL: audioURL,
                            isVideo: player.currentPlaybackIsVideo,
                            coverImageURL: episode.imageURL,
                            fallbackCoverImageURL: episode.podcast?.imageURL,
                            playPosition: player.playPosition,
                            duration: episode.duration ?? 60
                        )
                    } else {
                        EmptyView()
                    }
                }
#endif

                Spacer()

                if includeBookmark {
                    Button {
                        Task {
                            do { try await player.createBookmark() }
                            catch { bookmarkError = error.localizedDescription }
                        }
                    } label: {
                        Label {
                            Text("Bookmark")
                        } icon: {
                            Image(systemName: "bookmark.fill")
                                .resizable()
                                .scaledToFit()
                        }
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .frame(height: 30)
                    .accessibilityLabel("Add bookmark")
                    .accessibilityHint("Saves the current playback position as a bookmark")
                    .help("Save this moment to your bookmarks")
                    .accessibilityInputLabels([Text("Bookmark"), Text("Add bookmark")])
                }
            }
        }
        .frame(height: 50)
        .zIndex(3)
        .onChange(of: player.isPlaying) {
            PlayerOpeningPerformance.interactionVisible(.playPause)
        }
        .alert("Couldn’t Save Bookmark", isPresented: Binding(
            get: { bookmarkError != nil },
            set: { if !$0 { bookmarkError = nil } }
        )) {
            Button("OK", role: .cancel) { bookmarkError = nil }
        } message: {
            Text(bookmarkError ?? "")
        }
    }
}

#Preview {
    let previewFeedURL = URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!
    let previewPodcast = Podcast(feed: previewFeedURL)
    let previewEpisode = Episode(
        title: "Preview Episode",
        url: previewFeedURL,
        podcast: previewPodcast
    )
    let _: () = Player.shared.currentEpisode = previewEpisode

    return PlayerControllView()
        .modelContainer(for: PodcastSettings.self, inMemory: true, isAutosaveEnabled: true)
}
