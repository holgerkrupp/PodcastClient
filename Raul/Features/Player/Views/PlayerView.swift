import SwiftUI
import RichText
import ESADesignKit

struct PlayerView: View {
    @Bindable private var player = Player.shared
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage(PlayerLandscapePreference.controlsSideKey)
    private var landscapeControlsSideRawValue = LandscapePlayerControlsSide.trailing.rawValue
    @State private var landscapeTab: LandscapePlayerTab = .shownotes

    let fullSize: Bool

    var body: some View {
        if let episode = player.currentEpisode {
            GeometryReader { geometry in
                Group {
                    if fullSize && isPhoneLandscape(in: geometry.size) {
                        landscapePlayer(episode: episode)
                    } else if fullSize {
                        portraitFullPlayer(episode: episode)
                    } else {
                        compactPlayer(episode: episode)
                    }
                }
                .ESAFullBackground(image: episode.imageURL ?? episode.podcast?.imageURL)
            }
        } else {
            PlayerEmptyView()
        }
    }

    private func isPhoneLandscape(in size: CGSize) -> Bool {
        PlatformSupport.isPhone && verticalSizeClass == .compact && size.width > size.height
    }

    private var landscapeControlsSide: LandscapePlayerControlsSide {
        LandscapePlayerControlsSide(rawValue: landscapeControlsSideRawValue) ?? .trailing
    }

    private func landscapePlayer(episode: Episode) -> some View {
        GeometryReader { geometry in
            let controlsWidth = min(max(geometry.size.width * 0.41, 280), 360)

            HStack(spacing: 12) {
                if landscapeControlsSide == .leading {
                    landscapeControls(episode: episode)
                        .frame(width: controlsWidth)
                    landscapeContent(episode: episode)
                } else {
                    landscapeContent(episode: episode)
                    landscapeControls(episode: episode)
                        .frame(width: controlsWidth)
                }
            }
            .safeAreaPadding(.horizontal, 12)
            .safeAreaPadding(.vertical, 8)
        }
    }

    private func landscapeControls(episode: Episode) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Playback")
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    landscapeControlsSideRawValue = landscapeControlsSide.opposite.rawValue
                } label: {
                    Label(
                        landscapeControlsSide == .trailing ? "Move controls to left" : "Move controls to right",
                        systemImage: "arrow.left.arrow.right"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass(.clear))
                .accessibilityLabel(
                    landscapeControlsSide == .trailing
                        ? "Move playback controls to left"
                        : "Move playback controls to right"
                )
                .accessibilityHint("Changes the landscape player layout for left- or right-handed use")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                PlayerControllView(
                    showPrimaryTransportControls: true,
                    layout: .landscapeCompact
                )
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback controls for \(episode.title)")
    }

    private func landscapeContent(episode: Episode) -> some View {
        VStack(spacing: 0) {
            Picker("Player content", selection: $landscapeTab) {
                ForEach(LandscapePlayerTab.allCases) { tab in
                    Text(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)
            .accessibilityLabel("Player content")

            Divider()

            Group {
                switch landscapeTab {
                case .shownotes:
                    ScrollView {
                        PlayerShownotesView(html: episode.content ?? episode.desc ?? "")
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .transcript:
                    if let transcriptLines = episode.transcriptLines, transcriptLines.isEmpty == false {
                        TranscriptListView(
                            transcriptLines: transcriptLines,
                            episode: episode,
                            startFollowingPlayback: true
                        )
                    } else {
                        ContentUnavailableView("No Transcript", systemImage: "quote.bubble")
                    }
                case .chapters:
                    ChapterListView(episode: episode, showsTitle: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func portraitFullPlayer(episode: Episode) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                PlayerControllView(showPrimaryTransportControls: false)
                    .padding()

                Section {
                    HStack {
                        if let episodeLink = episode.link {
                            Link(destination: episodeLink) {
                                Label("Open in Browser", systemImage: "safari")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.glass(.clear))
                        }

                        Spacer()
#if DEBUG
                        NavigationLink(destination: EpisodeDebugMetadataView(episode: episode)) {
                            Image(systemName: "ladybug")
                                .imageScale(.small)
                        }
                        .buttonStyle(.glass(.clear))
                        .frame(height: 30)
                        .accessibilityLabel("Episode debug metadata")
                        Spacer()
#endif

                        if player.canSwitchCurrentEpisodeMedia {
                            Button {
                                Task {
                                    await player.switchCurrentEpisodeMedia()
                                }
                            } label: {
                                Label {
                                    Text(player.currentPlaybackIsVideo ? "Switch to Audio" : "Switch to Video")
                                } icon: {
                                    Image(systemName: player.currentPlaybackIsVideo ? "waveform" : "play.rectangle")
                                        .resizable()
                                        .scaledToFit()
                                }
                                .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .frame(height: 30)
                            .accessibilityLabel(player.currentPlaybackIsVideo ? "Switch to audio" : "Switch to video")
                            .accessibilityHint("Changes the current episode between the audio enclosure and alternate video stream")
                        }

                        Spacer()

                        if let url = episode.deeplinks?.first ?? episode.link {
                            ShareLink(item: positionedURL(for: url)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.glass(.clear))
                            .accessibilityLabel("Share episode link at current time")
                            .accessibilityHint("Opens the share sheet with the current playback timestamp")
                        }

                        ListenTogetherButton(episode: episode)
                    }
                    .padding()

                    PlayerShownotesView(html: episode.content ?? episode.desc ?? "")
                        .padding()
                } header: {
                    PlayerPrimaryTransportControlsView(includeBookmark: true)
                        .tint(.primary)
                        .padding(.horizontal)
                        .padding(.top, 20)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity)
                        .zIndex(3)
                }
            }
        }
    }

    private func compactPlayer(episode: Episode) -> some View {
        VStack(spacing: 0) {
            PlayerControllView()
                .padding()
#if DEBUG
            NavigationLink(destination: EpisodeDebugMetadataView(episode: episode)) {
                Image(systemName: "ladybug")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Episode debug metadata")
#endif
        }
    }

    private func positionedURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "t" }
        queryItems.append(URLQueryItem(name: "t", value: "\(Int(player.playPosition))"))
        components.queryItems = queryItems
        return components.url ?? url
    }
}

private enum PlayerLandscapePreference {
    static let controlsSideKey = "player.landscapeControlsSide"
}

private enum LandscapePlayerControlsSide: String {
    case leading
    case trailing

    var opposite: Self {
        self == .leading ? .trailing : .leading
    }
}

private enum LandscapePlayerTab: String, CaseIterable, Identifiable {
    case shownotes
    case transcript
    case chapters

    var id: Self { self }

    var title: String {
        switch self {
        case .shownotes: "Shownotes"
        case .transcript: "Transcript"
        case .chapters: "Chapters"
        }
    }
}

private struct PlayerShownotesView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var reloadGeneration = 0
    @State private var wasBackgrounded = false

    let html: String

    var body: some View {
        Group {
#if os(iOS)
            RichText(html: html)
                .linkColor(light: Color.secondary, dark: Color.secondary)
                .backgroundColor(.transparent)
#else
            RichText(html: html)
                .backgroundColor(.transparent)
#endif
        }
        .id(reloadGeneration)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                wasBackgrounded = true
            } else if newPhase == .active, wasBackgrounded {
                wasBackgrounded = false
                reloadGeneration &+= 1
            }
        }
    }
}

#Preview {
    @Previewable @State var fullSize: Bool = false
    let episode = Episode(
        title: "Test Episode",
        url: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!,
        podcast: Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!)
    )
    let _: () = Player.shared.currentEpisode = episode

    Toggle("Full Size", isOn: $fullSize)
    PlayerView(fullSize: fullSize)
}
