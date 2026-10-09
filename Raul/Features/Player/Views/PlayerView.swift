import SwiftUI
import SwiftData
import ESADesignKit
import os
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
    @State private var contentAvailability: PlayerContentAvailability?
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
            .esaResolveTheme(image: currentArtworkSource)
            .onAppear {
                PlayerOpeningPerformance.firstMeaningfulFrame(artworkReady: player.currentArtworkImage != nil)
            }
            .background {
                ESADesignKit.ESAFullBackground(image: currentArtworkSource)
            }
            .onChange(of: episode.url) { _, _ in
                isTransportPinned = false
                contentAvailability = nil
            }
            .task(id: episode.url) {
                await refreshContentAvailability(for: episode)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .episodeReferencesDidChange)
                    .receive(on: DispatchQueue.main)
            ) { notification in
                guard notificationMatchesEpisode(notification, episode: episode) else { return }
                Task { @MainActor in
                    await refreshContentAvailability(for: episode, forceRefresh: true)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playerChapterDataDidChange)) { _ in
                Task { @MainActor in
                    await refreshContentAvailability(for: episode, forceRefresh: true)
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
                usesCachedContentAvailability: true,
                contentAvailability: contentAvailability,
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
                    let transcriptLines = episode.transcriptLines ?? []
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
                    let chapterMarkers = episode.chapters ?? []
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
                    usesCachedContentAvailability: true,
                    contentAvailability: contentAvailability,
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
            .onAppear {
                PlayerOpeningPerformance.controlsResponsive()
            }
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
                usesCachedContentAvailability: true,
                contentAvailability: contentAvailability,
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
            hasTranscript: contentAvailability?.episodeURL == episode.url
                && contentAvailability?.hasTranscript == true,
            hasUsableChapters: contentAvailability?.episodeURL == episode.url
                && contentAvailability?.hasUsableChapters == true
        )
    }

    private func startAIGeneration(_ action: EpisodeAIGenerationAction, for episode: Episode) {
        guard let episodeURL = episode.url else { return }
        aiGeneration.start(action: action, episodeURL: episodeURL, modelContainer: modelContext.container)
    }

    private func hasDisplayableChapters(in markers: [Marker], for episode: Episode) -> Bool {
        if markers.contains(where: { $0.type == .soundbite }) {
            return true
        }

        let displayChapters = episode.chaptersForDisplay(from: markers)
        return displayChapters.count > 1 || (displayChapters.first?.start ?? 0) > 0.5
    }

    @MainActor
    private func refreshContentAvailability(for episode: Episode, forceRefresh: Bool = false) async {
        guard let episodeURL = episode.url else { return }
        if contentAvailability?.episodeURL != episodeURL {
            contentAvailability = nil
        }
        let worker = PlayerContentAvailabilityModelActor(modelContainer: modelContext.container)
        if forceRefresh {
            await worker.invalidate(episodeURL: episodeURL)
        }
        let snapshot = await worker.availability(for: episodeURL)
        guard Task.isCancelled == false, player.currentEpisode?.url == episodeURL else { return }
        contentAvailability = snapshot
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

struct PlayerContentAvailability: Sendable, Equatable {
    let episodeURL: URL
    let hasTranscript: Bool
    let hasChapterSelectionUI: Bool
    let hasUsableChapters: Bool
}

private actor PlayerContentAvailabilitySnapshotCache {
    static let shared = PlayerContentAvailabilitySnapshotCache()

    private var snapshots: [URL: PlayerContentAvailability] = [:]
    private var order: [URL] = []
    private let limit = 24

    func snapshot(for episodeURL: URL) -> PlayerContentAvailability? {
        snapshots[episodeURL]
    }

    func store(_ snapshot: PlayerContentAvailability) {
        snapshots[snapshot.episodeURL] = snapshot
        order.removeAll { $0 == snapshot.episodeURL }
        order.append(snapshot.episodeURL)
        if order.count > limit {
            let evictedURL = order.removeFirst()
            snapshots.removeValue(forKey: evictedURL)
        }
    }

    func invalidate(episodeURL: URL) {
        snapshots.removeValue(forKey: episodeURL)
        order.removeAll { $0 == episodeURL }
    }
}

@ModelActor
actor PlayerContentAvailabilityModelActor {
    func availability(for episodeURL: URL) async -> PlayerContentAvailability {
        if let cached = await PlayerContentAvailabilitySnapshotCache.shared.snapshot(for: episodeURL) {
            os_signpost(.event, log: PlayerOpeningPerformance.log, name: "Player availability cache hit")
            return cached
        }

        let signpostID = OSSignpostID(log: PlayerOpeningPerformance.log)
        os_signpost(.begin, log: PlayerOpeningPerformance.log, name: "Player availability query", signpostID: signpostID)
        defer { os_signpost(.end, log: PlayerOpeningPerformance.log, name: "Player availability query", signpostID: signpostID) }

        let episodeDescriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.url == episodeURL }
        )
        let episode = (try? modelContext.fetch(episodeDescriptor))?.first

        var transcriptDescriptor = FetchDescriptor<TranscriptLineAndTime>(
            predicate: #Predicate { $0.episode?.url == episodeURL }
        )
        transcriptDescriptor.fetchLimit = 1
        let hasTranscript = (try? modelContext.fetch(transcriptDescriptor))?.isEmpty == false

        let markerDescriptor = FetchDescriptor<Marker>(
            predicate: #Predicate { $0.episode?.url == episodeURL }
        )
        let markers = (try? modelContext.fetch(markerDescriptor)) ?? []
        let displayChapters = episode?.chaptersForDisplay(from: markers) ?? []
        let hasChapterSelectionUI = displayChapters.count > 1
            || (displayChapters.first?.start ?? 0) > 0.5
        let hasUsableChapters = hasChapterSelectionUI
            || markers.contains(where: { $0.type == .soundbite })
        let snapshot = PlayerContentAvailability(
            episodeURL: episodeURL,
            hasTranscript: hasTranscript,
            hasChapterSelectionUI: hasChapterSelectionUI,
            hasUsableChapters: hasUsableChapters
        )

        await PlayerContentAvailabilitySnapshotCache.shared.store(snapshot)
        return snapshot
    }

    func invalidate(episodeURL: URL) async {
        await PlayerContentAvailabilitySnapshotCache.shared.invalidate(episodeURL: episodeURL)
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
