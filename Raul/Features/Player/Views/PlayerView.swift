import SwiftUI
import SwiftData
import ESADesignKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct PlayerView: View {
    @Bindable private var player = Player.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var contentTab: PlayerContentTab = .shownotes
    @State private var refreshedContentEpisodeURL: URL?
    @State private var refreshedTranscriptLines: [TranscriptLineAndTime] = []
    @State private var refreshedChapterMarkers: [Marker] = []
    @State private var isTransportPinned = false
    @State private var aiGeneration = EpisodeAIGenerationCoordinator.shared

    let fullSize: Bool
    /// Set by the iOS presentation host because a sheet's local size class can
    /// differ from the scene that presented it.
    var usesExpandedLayout: Bool? = nil
    var onDismiss: (() -> Void)? = nil

    private var shouldUseExpandedLayout: Bool {
        usesExpandedLayout ?? (horizontalSizeClass == .regular)
    }

    private var currentArtworkSource: ESAImageSource {
        guard let image = player.currentArtworkImage else { return .url(nil) }
#if os(macOS)
        // Player keeps its decoded artwork as UIImage on every platform. The
        // design kit uses NSImage on macOS, so bridge the same pixels without
        // changing which chapter/episode image the player selected.
        if let cgImage = image.cgImage {
            return .platformImage(NSImage(
                cgImage: cgImage,
                size: NSSize(width: image.size.width, height: image.size.height)
            ))
        }
        if let data = image.pngData(), let nsImage = NSImage(data: data) {
            return .platformImage(nsImage)
        }
        return .url(nil)
#else
        return .platformImage(image)
#endif
    }

    var body: some View {
        if let episode = player.currentEpisode {
            let _ = episode.refresh

            GeometryReader { geometry in
                Group {
                    if fullSize && shouldUseExpandedLayout && !PlatformSupport.isPhone {
                        expandedPlayer(episode: episode, in: geometry.size)
                    } else if fullSize {
                        compactFullPlayer(episode: episode, in: geometry.size)
                    } else {
                        compactPlayer(episode: episode)
                    }
                }
            }
            .background {
                ESADesignKit.ESAFullBackground(image: currentArtworkSource)
            }
            .onChange(of: episode.url) { _, _ in
                isTransportPinned = false
            }
            .task(id: episode.url) {
                await refreshGenerationState(for: episode)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .episodeReferencesDidChange)
                    .receive(on: DispatchQueue.main)
            ) { notification in
                guard notificationMatchesEpisode(notification, episode: episode) else { return }
                Task { @MainActor in
                    await refreshGenerationState(for: episode)
                }
            }
        } else {
            PlayerEmptyView()
        }
    }

    private func expandedPlayer(episode: Episode, in size: CGSize) -> some View {
        HStack(spacing: 0) {
            playerContentPane(episode: episode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Keep the panes clear of the Duo's central division without
            // coupling the layout to a device-specific measurement.
            Color.clear
                .frame(width: size.width * 0.06)
                .accessibilityHidden(true)

            Divider()

            PlayerControllView(
                mediaHeight: min(size.width, size.height) * 0.33,
                showsInlineTranscript: false,
                generationAction: generationAction(for: episode),
                generationState: episode.url.flatMap { aiGeneration.state(for: $0) },
                generateAction: { action in startAIGeneration(action, for: episode) },
                cancelGeneration: { if let url = episode.url { Task { await aiGeneration.cancel(episodeURL: url) } } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Playback controls for \(episode.title)")
        }
        .safeAreaPadding()
    }

    private func playerContentPane(episode: Episode) -> some View {
        let transcriptLines = availableTranscriptLines(for: episode)
        let chapterMarkers = availableChapterMarkers(for: episode)

        return VStack(spacing: 0) {
            Picker("Player content", selection: $contentTab) {
                ForEach(PlayerContentTab.allCases) { tab in
                    Text(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            .accessibilityLabel("Player content")

            Divider()

            Group {
                switch contentTab {
                case .shownotes:
                    ScrollView {
                        PlayerShownotesView(html: episode.content ?? episode.desc ?? "")
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .transcript:
                    if transcriptLines.isEmpty == false {
                        TranscriptListView(
                            transcriptLines: transcriptLines,
                            episode: episode,
                            startFollowingPlayback: true
                        )
                    } else {
                        missingTranscriptView(episode: episode)
                    }
                case .chapters:
                    if hasDisplayableChapters(in: chapterMarkers, for: episode) {
                        ChapterListView(
                            episode: episode,
                            showsTitle: false,
                            markersOverride: chapterMarkers
                        )
                    } else {
                        missingChaptersView(episode: episode)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
    }

    private func missingTranscriptView(episode: Episode) -> some View {
        ContentUnavailableView {
            Label("No Transcript", systemImage: "quote.bubble")
        } description: {
            Text("Generate a transcript to read along with this episode.")
        } actions: {
            Text("Use the chapter row to generate a transcript on this device.")
        }
    }

    private func missingChaptersView(episode: Episode) -> some View {
        ContentUnavailableView {
            Label("No Chapters", systemImage: "list.bullet.rectangle")
        } description: {
            Text("Generate a transcript and use it to create chapter markers.")
        } actions: {
            Text("Use the chapter row to generate chapters on this device.")
        }
    }

    private func compactFullPlayer(episode: Episode, in size: CGSize) -> some View {
        let usesArtworkHero = !player.currentPlaybackIsVideo && colorSchemeContrast != .increased

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PlayerControllView(
                    showPrimaryTransportControls: false,
                    mediaHeight: min(max(0, size.width - 32), size.height * 0.72),
                    showsMedia: !usesArtworkHero,
                    showsTranscriptOverHero: usesArtworkHero,
                    showsPlaybackUtilities: false,
                    generationAction: generationAction(for: episode),
                    generationState: episode.url.flatMap { aiGeneration.state(for: $0) },
                    generateAction: { action in startAIGeneration(action, for: episode) },
                    cancelGeneration: { if let url = episode.url { Task { await aiGeneration.cancel(episodeURL: url) } } }
                )
                    .frame(maxWidth: .infinity, alignment: .top)

                transportControls
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named("playerViewport")).minY
                    } action: { _, headerY in
                        isTransportPinned = headerY <= 0
                    }
                    .opacity(isTransportPinned ? 0 : 1)
                    .allowsHitTesting(!isTransportPinned)

                PlayerPlaybackUtilitiesRow()
                    .padding(.horizontal)
                    .padding(.bottom, 12)

                compactShownotes(episode: episode)

            }
            .fullPageScreenshotSupport()
            .safeAreaPadding(.horizontal)
            .safeAreaPadding(.bottom)
            .safeAreaPadding(.top, usesArtworkHero ? 0 : nil)
        }
        .coordinateSpace(name: "playerViewport")
        .coverHero(
            image: currentArtworkSource,
            enabled: usesArtworkHero,
            placeholderAspectRatio: 1.0
        )
        .overlay(alignment: .top) {
            if isTransportPinned {
                transportControls
                    .safeAreaPadding(.horizontal)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onDismiss {
                Button(action: onDismiss) {
                    Label("Close player", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass(.clear))
                .accessibilityLabel("Close player")
                .padding()
            }
        }
        // A square cover should fit within a short landscape iPhone viewport.
        .frame(width: min(size.width, size.height * 0.55))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollIndicators(.automatic)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback controls and shownotes for \(episode.title)")
    }

    private var transportControls: some View {
        PlayerPrimaryTransportControlsView(includeBookmark: true)
            .tint(.primary)
            .padding(.horizontal)
            .padding(.trailing, onDismiss == nil ? 0 : 48)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
    }

    private func compactShownotes(episode: Episode) -> some View {
        VStack(alignment: .leading) {
            Divider()

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
                .tint(.blue)
                .accessibilityLabel("Episode debug metadata")
#endif

                if player.canSwitchCurrentEpisodeMedia {
                    Button {
                        Task { await player.switchCurrentEpisodeMedia() }
                    } label: {
                        Label(
                            player.currentPlaybackIsVideo ? "Switch to Audio" : "Switch to Video",
                            systemImage: player.currentPlaybackIsVideo ? "waveform" : "play.rectangle"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel(player.currentPlaybackIsVideo ? "Switch to audio" : "Switch to video")
                }

                Spacer()

                if let url = episode.deeplinks?.first ?? episode.link {
                    ShareLink(item: positionedURL(for: url)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass(.clear))
                    .accessibilityLabel("Share episode link at current time")
                }

                ListenTogetherButton(episode: episode)
            }

            Text("Shownotes")
                .font(.headline)

            PlayerShownotesView(html: episode.content ?? episode.desc ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactPlayer(episode: Episode) -> some View {
        VStack(spacing: 0) {
            PlayerControllView(
                generationAction: generationAction(for: episode),
                generationState: episode.url.flatMap { aiGeneration.state(for: $0) },
                generateAction: { action in startAIGeneration(action, for: episode) },
                cancelGeneration: { if let url = episode.url { Task { await aiGeneration.cancel(episodeURL: url) } } }
            )
                .padding()
#if DEBUG
            NavigationLink(destination: EpisodeDebugMetadataView(episode: episode)) {
                Image(systemName: "ladybug")
                    .imageScale(.small)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .tint(.blue)
            .accessibilityLabel("Episode debug metadata")
#endif
        }
    }

    private func generationAction(for episode: Episode) -> EpisodeAIGenerationAction? {
        EpisodeAIGenerationPolicy.action(
            isAvailable: AppleIntelligenceAvailability.isAvailable,
            hasTranscript: availableTranscriptLines(for: episode).isEmpty == false,
            hasUsableChapters: episode.hasDisplayableChaptersOrSoundbites
        )
    }

    private func startAIGeneration(_ action: EpisodeAIGenerationAction, for episode: Episode) {
        guard let episodeURL = episode.url else { return }
        aiGeneration.start(action: action, episodeURL: episodeURL, modelContainer: modelContext.container)
    }

    private func availableTranscriptLines(for episode: Episode) -> [TranscriptLineAndTime] {
        if let transcriptLines = episode.transcriptLines, transcriptLines.isEmpty == false {
            return transcriptLines
        }
        guard refreshedContentEpisodeURL == episode.url else { return [] }
        return refreshedTranscriptLines
    }

    private func availableChapterMarkers(for episode: Episode) -> [Marker] {
        if refreshedContentEpisodeURL == episode.url, refreshedChapterMarkers.isEmpty == false {
            return refreshedChapterMarkers
        }
        return episode.chapters ?? []
    }

    private func hasDisplayableChapters(in markers: [Marker], for episode: Episode) -> Bool {
        if markers.contains(where: { $0.type == .soundbite }) {
            return true
        }

        let displayChapters = episode.chaptersForDisplay(from: markers)
        return displayChapters.count > 1 || (displayChapters.first?.start ?? 0) > 0.5
    }

    @MainActor
    private func refreshGenerationState(for episode: Episode) async {
        guard let episodeURL = episode.url else { return }
        if refreshedContentEpisodeURL != episodeURL {
            refreshedContentEpisodeURL = episodeURL
            refreshedTranscriptLines = []
            refreshedChapterMarkers = []
        }

        let transcriptDescriptor = FetchDescriptor<TranscriptLineAndTime>(
            predicate: #Predicate { line in
                line.episode?.url == episodeURL
            },
            sortBy: [SortDescriptor(\.startTime)]
        )
        refreshedTranscriptLines = (try? modelContext.fetch(transcriptDescriptor)) ?? []

        let chapterDescriptor = FetchDescriptor<Marker>(
            predicate: #Predicate { marker in
                marker.episode?.url == episodeURL
            }
        )
        refreshedChapterMarkers = ((try? modelContext.fetch(chapterDescriptor)) ?? [])
            .sorted { ($0.start ?? 0) < ($1.start ?? 0) }
    }

    private func notificationMatchesEpisode(_ notification: Notification, episode: Episode) -> Bool {
        guard let changedURL = notification.userInfo?[EpisodeReferenceNotificationKey.episodeURL] as? URL else {
            return true
        }
        return changedURL == episode.url
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

private enum PlayerContentTab: String, CaseIterable, Identifiable {
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
    let html: String

    var body: some View {
        ShownoteContentView(html: html)
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
