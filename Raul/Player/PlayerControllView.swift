//
//  PlayerControllView.swift
//  Raul
//
//  Created by Holger Krupp on 27.06.25.
//
import SwiftUI
import SwiftData


struct PlayerControllView: View {
    @Environment(\.modelContext) private var context

    @Bindable private var player = Player.shared
    @State private var showTranscripts: Bool = false
    @State private var showFullTranscripts: Bool = false
    @State var showSpeedSetting:Bool = false
    @State var showSettings: Bool = false
    @State private var showClipExport = false
    let preferWideLayout: Bool
    
    @Query(filter: #Predicate<PodcastSettings> { $0.title == "de.holgerkrupp.podbay.queue" } ) var globalSettings: [PodcastSettings]

    init(preferWideLayout: Bool = false) {
        self.preferWideLayout = preferWideLayout
    }
    
    var body: some View {
        if let episode = player.currentEpisode {
            VStack(spacing: 16) {
                topBar

                if preferWideLayout {
                    let widePanelHeight: CGFloat = 320
                    HStack(alignment: .top, spacing: 24) {
                        artworkSection(episode: episode)
                            .frame(width: widePanelHeight, height: widePanelHeight, alignment: .top)

                        controlsSection(episode: episode)
                            .frame(maxWidth: .infinity, maxHeight: widePanelHeight, alignment: .topLeading)
                    }
                } else {
                    artworkSection(episode: episode)
                    controlsSection(episode: episode)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var topBar: some View {
        HStack {
            AirPlayButtonView()
                .tint(.primary)
                .foregroundColor(.primary)
                .frame(width: 44, height: 44)

            Spacer()

            Button {
                showSpeedSetting = true
            } label: {
                Label {
                    Text("Playback Settings")
                } icon: {
                    Image(systemName: "gear")
                        .tint(.primary)
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showSpeedSetting, content: playbackSettingsSheet)
    }

    @ViewBuilder
    private func playbackSettingsSheet() -> some View {
        List {
            Section(header: Label("Playback Speed", systemImage: "gauge.with.dots.needle.50percent")) {
                Stepper(value: $player.playbackRate, in: 0.1...3.0, step: 0.1) {
                    Text(String(format: "%.1fx", player.playbackRate))
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
            }

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

            HStack {
                Spacer()
                Button("Show all Settings") {
                    showSettings = true
                }
                .buttonStyle(.glass(.clear))
                Spacer()
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
        .listStyle(.plain)
        .padding()
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .presentationDetents([.fraction(0.5)])
        .sheet(isPresented: $showSettings) {
            if let podcast = player.currentEpisode?.podcast {
                PodcastSettingsView(podcast: podcast, modelContainer: context.container)
                    .presentationBackground(.ultraThinMaterial)
            } else {
                PodcastSettingsView(podcast: nil, modelContainer: context.container)
                    .presentationBackground(.ultraThinMaterial)
            }
        }
    }

    @ViewBuilder
    private func artworkSection(episode: Episode) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Color.clear

                CoverImageView(episode: episode, timecode: player.currentChapter?.start)
                    .id(episode.url)
                    .scaledToFit()
                    .frame(maxWidth: preferWideLayout ? 320 : .infinity)
                    .overlay(alignment: .bottom) {
                        if let transcriptLines = player.currentEpisode?.transcriptLines,
                           player.playPosition.isNormal, showTranscripts {
                            TranscriptView(
                                transcriptLines: transcriptLines.sorted(by: { $0.startTime < $1.startTime }),
                                currentTime: $player.playPosition
                            )
                            .background(.ultraThinMaterial)
                        }
                    }
                    .sheet(isPresented: $showFullTranscripts) {
                        if let transcriptLines = player.currentEpisode?.transcriptLines {
                            TranscriptListView(transcriptLines: transcriptLines, episode: episode)
                                .presentationDetents([.large])
                                .presentationDragIndicator(.visible)
                        }
                    }
            }

            if preferWideLayout == false,
               let transcripts = player.currentEpisode?.transcriptLines,
               transcripts.count > 0 {
                HStack {
                    if showTranscripts {
                        Image("custom.quote.bubble.slash")
                            .onTapGesture {
                                showTranscripts.toggle()
                            }
                    } else {
                        Image(systemName: "quote.bubble")
                            .onTapGesture {
                                showTranscripts.toggle()
                            }
                    }
                    Spacer()
                    Image("custom.quote.bubble.rectangle.portrait")
                        .onTapGesture {
                            showFullTranscripts.toggle()
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func controlsSection(episode: Episode) -> some View {
        VStack(spacing: preferWideLayout ? 8 : 12) {
            PlayerChapterView()

            Text(episode.title)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if preferWideLayout {
                Spacer(minLength: 0)
            }

            VStack {
                PlayerProgressSliderView(value: $player.progress, allowTouch: globalSettings.first?.enableInAppSlider ?? true, sliderRange: 0...1)
                    .frame(height: 30)

                HStack {
                    Text(Duration.seconds(player.playPosition).formatted(.units(width: .narrow)))
                        .monospacedDigit()
                        .font(.caption)
                    Spacer()
                    if let maxPlay = player.currentEpisode?.metaData?.maxPlayposition,
                       maxPlay - 5.0 > player.currentEpisode?.metaData?.playPosition ?? 0.0 {
                        Button(action: {
                            Task {
                                await player.jumpTo(time: maxPlay)
                            }
                        }) {
                            Label {
                                Text("max play position")
                                    .monospaced()
                                    .font(.caption)
                            } icon: {
                                Image(systemName: "arrow.right.to.line.compact")
                                    .resizable()
                                    .scaledToFit()
                            }
                            .labelStyle(.titleOnly)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text(Duration.seconds(player.remaining ?? player.currentEpisode?.duration ?? 0.0).formatted(.units(width: .narrow)))
                        .monospacedDigit()
                        .font(.caption)
                }
            }

            if preferWideLayout {
                Spacer(minLength: 0)
            }

            HStack {
                Spacer()

                Button(action: player.skipback) {
                    Label {
                        Text("Skip Back")
                    } icon: {
                        Image(systemName: "15.arrow.trianglehead.counterclockwise")
                            .resizable()
                            .scaledToFit()
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .frame(width: 30)

                Spacer()
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
                }
                .buttonStyle(.borderless)
                .frame(width: 30)

                Spacer()
                Button(action: player.skipforward) {
                    Label {
                        Text("Skip Back")
                    } icon: {
                        Image(systemName: "30.arrow.trianglehead.clockwise")
                            .resizable()
                            .scaledToFit()
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .frame(width: 30)

                Spacer()
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
                .buttonStyle(.borderless)
                .frame(height: 30)
            }
            .frame(height: 40)
            .tint(.primary)

            if preferWideLayout {
                Spacer(minLength: 0)
            }

            accessoryActions(episode: episode)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func accessoryActions(episode: Episode) -> some View {
        HStack {
            if let episodeLink = episode.link {
                Link(destination: episodeLink) {
                    Label("Open in Browser", systemImage: "safari")
                }
                .buttonStyle(.glass(.clear))
            }

            Spacer()

            Button(action: {
                showClipExport = true
            }) {
                Image(systemName: "scissors")
            }
            .buttonStyle(.glass(.clear))
            .frame(height: 30)
            .help("Share audio clip")
            .sheet(isPresented: $showClipExport) {
                if let currentEpisode = player.currentEpisode,
                   let audioURL = currentEpisode.localFile ?? currentEpisode.url {
                    AudioClipExportView(
                        title: currentEpisode.title,
                        audioURL: audioURL,
                        coverImageURL: currentEpisode.imageURL,
                        fallbackCoverImageURL: currentEpisode.podcast?.imageURL,
                        playPosition: player.playPosition,
                        duration: currentEpisode.duration ?? 60
                    )
                } else {
                    EmptyView()
                }
            }

            Spacer()

            if let positionedURL = positionedShareURL(for: episode) {
                ShareLink(item: positionedURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass(.clear))
            }
        }

        HStack(spacing: 12) {
            if let publishDate = episode.publishDate {
                Text(publishDate.formatted(date: .numeric, time: .omitted))
            }
            if let duration = episode.duration, duration > 0 {
                Text(Duration.seconds(duration).formatted(.units(width: .narrow)))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func positionedShareURL(for episode: Episode) -> URL? {
        guard let url = episode.deeplinks?.first ?? episode.link,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "t" }
        let playPosition = Int(player.playPosition)
        queryItems.append(URLQueryItem(name: "t", value: "\(playPosition)"))
        components.queryItems = queryItems
        return components.url ?? url
    }
}
