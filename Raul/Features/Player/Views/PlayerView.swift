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
    @State private var transcriptionItem: TranscriptionItem?
    @State private var isStartingTranscription = false
    @State private var isGeneratingChapters = false
    @State private var transcriptGenerationMessage: String?
    @State private var chapterGenerationMessage: String?
    @State private var refreshedContentEpisodeURL: URL?
    @State private var refreshedTranscriptLines: [TranscriptLineAndTime] = []
    @State private var refreshedChapterMarkers: [Marker] = []
    @State private var isTransportPinned = false

    let fullSize: Bool
    /// Set by the iOS presentation host because a sheet's local size class can
    /// differ from the scene that presented it.
    var usesExpandedLayout: Bool? = nil
    var onDismiss: (() -> Void)? = nil

    private var shouldUseExpandedLayout: Bool {
        usesExpandedLayout ?? (horizontalSizeClass == .regular)
    }

    private var currentArtworkSource: ESAImageSource {
        player.currentArtworkImage.map {
            .image(Image(uiImage: $0))
        } ?? .url(nil)
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
            .task(id: transcriptionItem?.id) {
                await followTranscription(for: episode)
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
                debugGenerateTranscriptAndChaptersAction: {
                    Task { await generateTranscript(for: episode, includeChapters: true) }
                },
                isDebugGeneratingTranscriptAndChapters: isTranscriptionBusy(for: episode) || isGeneratingChapters
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
            generationAction(
                title: "Generate Transcript",
                isBusy: isTranscriptionBusy(for: episode),
                progressMessage: transcriptionProgressMessage(for: episode),
                resultMessage: refreshedContentEpisodeURL == episode.url ? transcriptGenerationMessage : nil
            ) {
                Task { await generateTranscript(for: episode, includeChapters: false) }
            }
        }
    }

    private func missingChaptersView(episode: Episode) -> some View {
        ContentUnavailableView {
            Label("No Chapters", systemImage: "list.bullet.rectangle")
        } description: {
            Text("Generate a transcript and use it to create chapter markers.")
        } actions: {
            generationAction(
                title: "Generate Transcript and Chapters",
                isBusy: isTranscriptionBusy(for: episode) || isGeneratingChapters,
                progressMessage: isGeneratingChapters ? "Generating chapters…" : transcriptionProgressMessage(for: episode),
                resultMessage: refreshedContentEpisodeURL == episode.url ? chapterGenerationMessage : nil
            ) {
                Task { await generateTranscript(for: episode, includeChapters: true) }
            }
        }
    }

    @ViewBuilder
    private func generationAction(
        title: LocalizedStringKey,
        isBusy: Bool,
        progressMessage: String?,
        resultMessage: String?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                if isBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(progressMessage ?? "Starting…")
                    }
                } else {
                    Label(title, systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
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
                    debugGenerateTranscriptAndChaptersAction: {
                        Task { await generateTranscript(for: episode, includeChapters: true) }
                    },
                    isDebugGeneratingTranscriptAndChapters: isTranscriptionBusy(for: episode) || isGeneratingChapters
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
                debugGenerateTranscriptAndChaptersAction: {
                    Task { await generateTranscript(for: episode, includeChapters: true) }
                },
                isDebugGeneratingTranscriptAndChapters: isTranscriptionBusy(for: episode) || isGeneratingChapters
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

    private func isTranscriptionBusy(for episode: Episode) -> Bool {
        isStartingTranscription
            || (transcriptionItem?.episodeURL == episode.url && transcriptionItem?.isTranscribing == true)
    }

    private func transcriptionProgressMessage(for episode: Episode) -> String? {
        if isStartingTranscription {
            return "Starting transcript…"
        }

        guard let transcriptionItem,
              transcriptionItem.episodeURL == episode.url,
              transcriptionItem.isTranscribing else { return nil }
        return transcriptionItem.statusText.isEmpty ? "Generating transcript…" : transcriptionItem.statusText
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

        return episode.chaptersForDisplay(from: markers).count > 1
    }

    @MainActor
    private func generateTranscript(for episode: Episode, includeChapters: Bool) async {
        guard isTranscriptionBusy(for: episode) == false, isGeneratingChapters == false else { return }
        guard let episodeURL = episode.url else {
            setGenerationMessage("This episode does not have an audio URL.", includeChapters: includeChapters)
            return
        }

        if includeChapters, availableTranscriptLines(for: episode).isEmpty == false {
            await generateChapters(for: episodeURL, episode: episode)
            return
        }

        let settingsActor = PodcastSettingsModelActor(modelContainer: modelContext.container)
        guard await settingsActor.getTranscriptionsEnabled() else {
            setGenerationMessage(
                "Enable episode transcriptions in Settings before generating one.",
                includeChapters: includeChapters
            )
            return
        }

        isStartingTranscription = true
        setGenerationMessage(nil, includeChapters: includeChapters)
        defer { isStartingTranscription = false }

        let manager = TranscriptionManager.shared
        if let existingItem = await manager.item(for: episodeURL), existingItem.isTranscribing == false {
            await manager.clearTranscriptionState(for: episodeURL)
        }

        do {
            try await EpisodeActor(modelContainer: modelContext.container).transcribe(episodeURL)
            transcriptionItem = await manager.item(for: episodeURL)
            if transcriptionItem?.isTranscribing == true {
                await manager.moveToFrontOfQueue(episodeURL: episodeURL)
            }
            await refreshGenerationState(for: episode)

            if transcriptionItem == nil, availableTranscriptLines(for: episode).isEmpty {
                setGenerationMessage(
                    "The transcript could not be started. Download the episode and try again.",
                    includeChapters: includeChapters
                )
            } else if includeChapters, transcriptionItem?.isTranscribing == true {
                chapterGenerationMessage = "Chapters will be generated when the transcript is ready."
            }
        } catch {
            setGenerationMessage(error.localizedDescription, includeChapters: includeChapters)
        }
    }

    @MainActor
    private func generateChapters(for episodeURL: URL, episode: Episode) async {
        guard isGeneratingChapters == false else { return }
        isGeneratingChapters = true
        chapterGenerationMessage = nil
        defer { isGeneratingChapters = false }

        let didGenerate = await EpisodeActor(modelContainer: modelContext.container)
            .regenerateTranscriptChapters(for: episodeURL)
        await refreshGenerationState(for: episode)

        if didGenerate == false {
            chapterGenerationMessage = "No chapters could be generated from this transcript."
        }
    }

    @MainActor
    private func followTranscription(for episode: Episode) async {
        guard let item = transcriptionItem else { return }

        while item.isTranscribing && Task.isCancelled == false {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await refreshGenerationState(for: episode)
        }

        await refreshGenerationState(for: episode)
        switch item.state {
        case .failed(let error):
            transcriptGenerationMessage = error
            if chapterGenerationMessage != nil {
                chapterGenerationMessage = error
            }
        case .cancelled:
            transcriptGenerationMessage = "Transcript generation was cancelled."
        case .finished:
            transcriptGenerationMessage = nil
        default:
            break
        }
    }

    @MainActor
    private func refreshGenerationState(for episode: Episode) async {
        guard let episodeURL = episode.url else { return }
        if refreshedContentEpisodeURL != episodeURL {
            refreshedContentEpisodeURL = episodeURL
            refreshedTranscriptLines = []
            refreshedChapterMarkers = []
            transcriptGenerationMessage = nil
            chapterGenerationMessage = nil
        }
        transcriptionItem = await TranscriptionManager.shared.item(for: episodeURL)

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

    private func setGenerationMessage(_ message: String?, includeChapters: Bool) {
        if includeChapters {
            chapterGenerationMessage = message
        } else {
            transcriptGenerationMessage = message
        }
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
