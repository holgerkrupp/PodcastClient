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


struct PlayerControllView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openPodcastSettings) private var openSettings

    @Bindable private var player = Player.shared
    @State private var showTranscripts: Bool = false

    @State private var showFullTranscripts: Bool = false
    @State private var openFullTranscriptFollowingPlayback: Bool = false
    @State private var showPlaybackSpeedSettings = false
    @State private var showSleepTimerSettings = false
    @ScaledMetric(relativeTo: .body) private var mediaSectionHeight: CGFloat = 360
    @ScaledMetric(relativeTo: .body) private var transcriptCardHeight: CGFloat = 120
    @ScaledMetric(relativeTo: .body) private var mediaSectionSpacing: CGFloat = 12
    var showPrimaryTransportControls: Bool = true
    
    @Query(filter: #Predicate<PodcastSettings> { $0.title == "de.holgerkrupp.podbay.queue" } ) var globalSettings: [PodcastSettings]
    
    var body: some View {
        if let episode = player.currentEpisode {
            VStack {
                
                HStack {
                    AirPlayButtonView()
                        .tint(.primary)
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("AirPlay")
                        .accessibilityHint("Choose an audio output device")
                        
                    Spacer()

                    Button {
                        if let podcast = player.currentEpisode?.podcast {
                            openSettings(.podcast(podcast))
                        } else {
                            openSettings()
                        }
                    } label: {
                        Label {
                            Text("Settings")
                        } icon: {
                            Image(systemName: "gear")
                                .tint(.primary)
                        }
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                    .accessibilityHint("Opens all settings")
                    .accessibilityInputLabels([Text("Settings"), Text("All settings")])
                    
                    
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(3)
                .sheet(isPresented: $showPlaybackSpeedSettings) {
                    playbackSpeedSheet
                }
                .sheet(isPresented: $showSleepTimerSettings) {
                    sleepTimerSheet
                }
                
                VStack(spacing: mediaSectionSpacing) {
                    PlayerMediaView(
                        episode: episode,
                        player: player.videoPlayer,
                        isVideo: player.currentPlaybackIsVideo,
                        timecode: player.currentChapter?.start
                    )
                        .id("\(episode.url?.absoluteString ?? "")-\(player.currentPlaybackIsVideo)")
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(
                            height: showTranscripts
                                ? mediaSectionHeight - transcriptCardHeight - mediaSectionSpacing
                                : mediaSectionHeight,
                            alignment: .top
                        )

                    if let transcriptLines = player.currentEpisode?.transcriptLines,
                       showTranscripts {
                        Button {
                            openFullTranscriptFollowingPlayback = true
                            showFullTranscripts = true
                        } label: {
                            TranscriptView(
                                transcriptLines: transcriptLines.sorted(by: { $0.startTime < $1.startTime }),
                                currentTime: $player.playPosition
                            )
                            .frame(maxWidth: .infinity, minHeight: transcriptCardHeight, maxHeight: transcriptCardHeight, alignment: .topLeading)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Open full transcript")
                        .accessibilityHint("Opens the transcript list and jumps to the current playback line")
                        .accessibilityInputLabels([Text("Open captions"), Text("Open transcript")])
                        .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: mediaSectionHeight, alignment: .top)
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85), value: showTranscripts)
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
                
                if let transcripts = player.currentEpisode?.transcriptLines, transcripts.count > 0 {
                    HStack {
                        if showTranscripts{
                            Button {
                                    showTranscripts.toggle()
                                } label: {
                                    Image("custom.quote.bubble.slash")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Hide inline transcript")
                                .accessibilityHint("Removes the transcript panel below the artwork")
                                .accessibilityInputLabels([Text("Hide captions"), Text("Hide transcript")])
                        }else{
                            Button {
                                    showTranscripts.toggle()
                                } label: {
                                    Image(systemName: "quote.bubble")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Show inline transcript")
                                .accessibilityHint("Shows the transcript panel below the artwork")
                                .accessibilityInputLabels([Text("Show captions"), Text("Show transcript")])
                        }
                        Spacer()
                        Button {
                                openFullTranscriptFollowingPlayback = false
                                showFullTranscripts = true
                            } label: {
                                Image("custom.quote.bubble.rectangle.portrait")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open full transcript")
                            .accessibilityHint("Opens the full transcript in a sheet")
                            .accessibilityInputLabels([Text("Open captions"), Text("Open transcript")])
                    }
                }
                
                
                PlayerChapterView()
                
                
                Text("\(episode.title)")
                    .lineLimit(2)
                
                
                VStack {
                    PlayerProgressSliderView(value: $player.progress, markers: $player.chapters, allowTouch: globalSettings.first?.enableInAppSlider ?? true, sliderRange: 0...1)
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
                HStack{

                    

                    Button {
                        showPlaybackSpeedSettings = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "gauge.with.dots.needle.50percent")
                                .tint(.primary)
                            Text(playbackSpeedButtonTitle)
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(playbackSpeedButtonTitle)
                    .accessibilityHint("Opens playback speed controls")
                    .accessibilityInputLabels([Text("Playback speed"), Text("Speed")])

                    Spacer()
                    
                    
                    if let maxPlay = player.currentEpisode?.metaData?.maxPlayposition, maxPlay-5.0 > player.currentEpisode?.metaData?.playPosition ?? 0.0  {
                        Button(action: {
                            Task{
                                await player.jumpTo(time: maxPlay)
                            }
                        }) {
                            Label {
                                Text("max play position")
                                    .monospaced()
                                    .font(.caption)
                            } icon: {
                                Image(systemName: "forward.end.alt.fill")
                                   // .resizable()
                                    .scaledToFit()
                                
                            }
                            .labelStyle(.iconOnly)
                            
                        }
                        
                       
                        .buttonStyle(.glass)
                        .accessibilityLabel("Jump to max play position")
                        .accessibilityHint("Jumps to the furthest point you have listened to in this episode")
                    }
                    Spacer()
                    
                    Button {
                        showSleepTimerSettings = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "zzz")
                                .tint(player.remainingTime == nil && player.stopAfterEpisode == false ? .primary : .accent)
                            Text(sleepTimerButtonTitle)
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Sleep timer")
                    .accessibilityValue(sleepTimerAccessibilityValue)
                    .accessibilityHint("Opens sleep timer controls")
                    .accessibilityInputLabels([Text("Sleep timer"), Text("Timer")])
                }
                .frame(height: 50)
                
                if showPrimaryTransportControls {
                    PlayerPrimaryTransportControlsView(includeBookmark: true)
                        .tint(.primary)
                }

                
            }
            .padding()
        }
    }

    private var playbackSpeedButtonTitle: String {
        player.playbackRate.formatted(.number.precision(.fractionLength(0...1))) + "x"
    }

    private var sleepTimerButtonTitle: String {
        if let remaining = player.remainingTime {
            return Duration.seconds(remaining).formatted(.units(width: .narrow))
        }

        if player.stopAfterEpisode {
            return "Episode"
        }

        return ""
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
    let episode: Episode
    let player: AVPlayer
    let isVideo: Bool
    let timecode: Double?

    var body: some View {
        Group {
            if isVideo {
                NativeVideoPlayerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(Text(verbatim: "Video player"))
            } else {
                CoverImageView(episode: episode, timecode: timecode)
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
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                .frame(width: 50)
                .accessibilityLabel("Skip back \(player.skipBackStep.rawValue) seconds")
                .accessibilityHint("Moves playback backward by \(player.skipBackStep.rawValue) seconds")
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
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                .frame(width: 50)
                .accessibilityLabel("Skip forward \(player.skipForwardStep.rawValue) seconds")
                .accessibilityHint("Moves playback forward by \(player.skipForwardStep.rawValue) seconds")
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
