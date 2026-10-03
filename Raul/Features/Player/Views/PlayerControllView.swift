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

struct PlayerControllView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openPodcastSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    @Bindable private var player = Player.shared
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
    var debugGenerateTranscriptAndChaptersAction: (() -> Void)?
    var isDebugGeneratingTranscriptAndChapters = false
    
    @Query(filter: #Predicate<PodcastSettings> { $0.title == "de.holgerkrupp.podbay.queue" } ) var globalSettings: [PodcastSettings]
    
    var body: some View {
        if let episode = player.currentEpisode {
            VStack(spacing: 8) {
                if showsMedia, let mediaHeight {
                    VStack(spacing: 0) {
                        PlayerMediaView(
                            player: player.videoPlayer,
                            isVideo: player.currentPlaybackIsVideo,
                            artworkImage: player.currentArtworkImage
                        )
                            .id("\(episode.url?.absoluteString ?? "")-\(player.currentPlaybackIsVideo)")
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(
                                height: showsInlineTranscript && showTranscripts
                                    ? mediaHeight * 0.6
                                    : mediaHeight,
                                alignment: .top
                            )

                        if let transcriptLines = player.currentEpisode?.transcriptLines,
                           showsInlineTranscript,
                           showTranscripts {
                            inlineTranscriptCard(transcriptLines: transcriptLines)
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
                    PlayerMediaView(
                        player: player.videoPlayer,
                        isVideo: player.currentPlaybackIsVideo,
                        artworkImage: player.currentArtworkImage
                    )
                    .id("\(episode.url?.absoluteString ?? "")-\(player.currentPlaybackIsVideo)")
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                } else if !showsTranscriptOverHero,
                          showsInlineTranscript,
                          showTranscripts,
                          let transcriptLines = episode.transcriptLines {
                    inlineTranscriptCard(transcriptLines: transcriptLines)
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                
                chapterControlsRow
                
                
                Text("\(episode.title)")
                    .font(.body)
                    .lineLimit(2)
                
                
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
                            chapterTimelineDuration: player.currentEpisode?.duration, adSegments: player.showDetectedAdvertisements ? player.adSegments : [],
                            onEditingChanged: { isEditing, progress in
                                if isEditing {
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

                            Spacer()
                            Text(Duration.seconds(player.remaining ?? player.currentEpisode?.duration ?? 0.0).formatted(.units(width: .narrow)))
                                .monospacedDigit()
                                .font(.caption)
                        }
                    }
                }

                if let undo = player.skipProtectionUndo {
                    Button {
                        Task {
                            await player.undoSkipProtection(undoID: undo.id)
                        }
                    } label: {
                        Label("Undo skip", systemImage: "arrow.uturn.backward.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Returns to \(undo.episodeTitle) at the previous playback position")
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                }

                if showPrimaryTransportControls {
                    PlayerPrimaryTransportControlsView(includeBookmark: true)
                        .tint(.primary)
                }

                if showsPlaybackUtilities {
                    PlayerPlaybackUtilitiesRow()
                }
            }
            .padding()
            .overlay(alignment: .top) {
                if showsTranscriptOverHero,
                   showsInlineTranscript,
                   showTranscripts,
                   let transcriptLines = episode.transcriptLines,
                   !transcriptLines.isEmpty {
                    inlineTranscriptCard(transcriptLines: transcriptLines)
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
                if let transcriptLines = player.currentEpisode?.transcriptLines {
                    TranscriptListView(
                        transcriptLines: transcriptLines,
                        episode: episode,
                        startFollowingPlayback: openFullTranscriptFollowingPlayback
                    )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
            }
#if os(iOS)
            .sheet(item: $settingsRequest) { request in
                SettingsWindowContent(request: request)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
#endif
        }
    }

    private var chapterControlsRow: some View {
        ZStack {
            if player.currentEpisode?.preferredChapters.count ?? 0 > 1 {
                PlayerChapterView()
                    .padding(.horizontal, 16)
            } else {
#if DEBUG
                if let debugGenerateTranscriptAndChaptersAction {
                    Button(action: debugGenerateTranscriptAndChaptersAction) {
                        if isDebugGeneratingTranscriptAndChapters {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Create transcript/chapters", systemImage: "sparkles")
                                .font(.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .buttonStyle(.glass(.clear))
                    .tint(.blue)
                    .disabled(isDebugGeneratingTranscriptAndChapters)
                    .padding(.horizontal, 50)
                    .accessibilityLabel("Create transcript and chapters")
                    .accessibilityHint("Generates a transcript and chapter markers for this episode")
                }
#endif
            }

            if player.canSkipCurrentAdvertisement {
                Button {
                    Task { await player.skipCurrentAdvertisement() }
                } label: {
                    Label("Skip Ad", systemImage: "forward.end.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass(.clear))
                .accessibilityLabel("Skip advertisement")
                .accessibilityHint("Seeks to the end of the detected advertisement")
            }

            HStack(spacing: 0) {
                if showsInlineTranscript,
                   player.currentEpisode?.transcriptLines?.isEmpty == false {
                    transcriptVisibilityButton
                } else {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 0)
                playbackSettingsButton
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .zIndex(3)
    }

    private var playbackSettingsButton: some View {
        Button {
            openPlaybackSettings()
        } label: {
            Label("Playback Settings", systemImage: "gear")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .accessibilityLabel("Playback Settings")
        .accessibilityHint("Opens settings related to playback")
        .help("Adjust playback options for this podcast")
        .accessibilityInputLabels([Text("Playback settings"), Text("Player settings")])
    }

    private var transcriptVisibilityButton: some View {
        Button {
            showTranscripts.toggle()
        } label: {
            if showTranscripts {
                Image("custom.quote.bubble.slash")
            } else {
                Image(systemName: "quote.bubble")
            }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .accessibilityLabel(showTranscripts ? "Hide inline transcript" : "Show inline transcript")
        .accessibilityHint(transcriptVisibilityAccessibilityHint)
        .help(showTranscripts ? "Hide the transcript" : "Show the transcript")
        .accessibilityInputLabels([Text(showTranscripts ? "Hide captions" : "Show captions"), Text("Transcript")])
    }

    private var transcriptVisibilityAccessibilityHint: String {
        if showsTranscriptOverHero {
            return showTranscripts
                ? "Removes the transcript panel from the artwork"
                : "Shows the transcript panel over the artwork"
        }
        return showTranscripts
            ? "Removes the transcript panel below the artwork"
            : "Shows the transcript panel below the artwork"
    }

    private func inlineTranscriptCard(transcriptLines: [TranscriptLineAndTime]) -> some View {
        TranscriptView(
            transcriptLines: transcriptLines.sorted(by: { $0.startTime < $1.startTime }),
            currentTime: $player.playPosition,
            onOpenFullTranscript: {
                openFullTranscriptFollowingPlayback = true
                showFullTranscripts = true
            },
            reservesBottomTrailingAccessory: true
        )
        .overlay(alignment: .bottomTrailing) {
            Button {
                openFullTranscriptFollowingPlayback = false
                showFullTranscripts = true
            } label: {
                Image("custom.quote.bubble.rectangle.portrait")
            }
            .buttonStyle(.glass(.clear))
            .frame(width: 44, height: 44)
            .padding(6)
            .accessibilityLabel("Open full transcript")
            .accessibilityHint("Opens the full transcript in a sheet")
            .help("Read the whole episode as text")
            .accessibilityInputLabels([Text("Open captions"), Text("Open transcript")])
        }
    }

    private func openPlaybackSettings() {
        let request = SettingsWindowRequest.playback(for: player.currentEpisode?.podcast)
#if os(iOS)
        settingsRequest = request
#else
        openSettings(request)
#endif
    }

}

struct PlayerPlaybackUtilitiesRow: View {
    @Bindable private var player = Player.shared
    @State private var showPlaybackSpeedSettings = false
    @State private var showSleepTimerSettings = false
    private let furthestPositionTip = FurthestPositionTip()

    var body: some View {
        ZStack {
            airPlayButton

            HStack(spacing: 10) {
                playbackSpeedButton
                Spacer(minLength: 0)

                if let maxPlay = player.currentEpisode?.metaData?.maxPlayposition,
                   maxPlay - 5 > player.currentEpisode?.metaData?.playPosition ?? 0 {
                    maxPlayPositionButton(maxPlay: maxPlay)
                }

                sleepTimerButton
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .zIndex(3)
        .sheet(isPresented: $showPlaybackSpeedSettings) {
            playbackSpeedSheet
        }
        .sheet(isPresented: $showSleepTimerSettings) {
            sleepTimerSheet
        }
    }

    private var airPlayButton: some View {
        AirPlayButtonView()
            .tint(.primary)
            .foregroundColor(.primary)
            .frame(width: 44, height: 44)
            .glassEffect(.regular, in: Circle())
            .accessibilityLabel("AirPlay")
            .accessibilityHint("Choose an audio output device")
            .help("Choose where audio plays")
    }

    private var playbackSpeedButton: some View {
        Button {
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

    private func maxPlayPositionButton(maxPlay: Double) -> some View {
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

    private var sleepTimerButton: some View {
        Button {
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

    private var playbackSpeedButtonTitle: String {
        player.playbackRate.formatted(.number.precision(.fractionLength(0...1))) + "x"
    }

    private var sleepTimerAccessibilityValue: String {
        if let remaining = player.remainingTime {
            return Duration.seconds(remaining).formatted(.units(width: .wide))
        }

        if player.stopAfterEpisode {
            return "Stop after this episode"
        }

        return "Off"
    }

    private var playbackSpeedSheet: some View {
        List {
            Section(header: Label("Playback Speed", systemImage: "gauge.with.dots.needle.50percent")) {
                Stepper(value: $player.playbackRate, in: 0.1...3.0, step: 0.1) {
                    Text(String(format: "%.1fx", player.playbackRate))
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
        }
        .listStyle(.plain)
        .padding()
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .presentationDetents([.fraction(0.25)])
    }

    private var sleepTimerSheet: some View {
        List {
            Section(header: Label("Sleep Timer", systemImage: "zzz")) {
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
        }
        .listStyle(.plain)
        .padding()
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .presentationDetents([.fraction(0.25)])
    }
}

private struct PlayerMediaView: View {
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
                            .foregroundStyle(.secondary)
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

    var body: some View {
        ZStack {
            HStack(spacing: centerControlsSpacing) {
                Button(action: player.skipback) {
                    Label {
                        Text("Skip Back")
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
                
                Button(action: player.skipforward) {
                    Label {
                        Text("Skip Forward")
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
                    Button(action: player.createBookmark) {
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
