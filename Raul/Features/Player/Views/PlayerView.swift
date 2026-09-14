import SwiftUI
import SwiftData
import RichText
import ESADesignKit

struct PlayerView: View {
    @Bindable private var player = Player.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage(PlayerLandscapePreference.controlsSideKey)
    private var landscapeControlsSideRawValue = LandscapePlayerControlsSide.trailing.rawValue
    @State private var landscapeTab: LandscapePlayerTab = .shownotes
    @State private var transcriptionItem: TranscriptionItem?
    @State private var isStartingTranscription = false
    @State private var isGeneratingChapters = false
    @State private var transcriptGenerationMessage: String?
    @State private var chapterGenerationMessage: String?
    @State private var refreshedContentEpisodeURL: URL?
    @State private var refreshedTranscriptLines: [TranscriptLineAndTime] = []
    @State private var refreshedChapterMarkers: [Marker] = []

    let fullSize: Bool

    var body: some View {
        if let episode = player.currentEpisode {
            let _ = episode.refresh

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
        let transcriptLines = availableTranscriptLines(for: episode)
        let chapterMarkers = availableChapterMarkers(for: episode)

        return VStack(spacing: 0) {
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
                    if hasDisplayableChapters(in: chapterMarkers) {
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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

    private func hasDisplayableChapters(in markers: [Marker]) -> Bool {
        if markers.contains(where: { $0.type == .soundbite }) {
            return true
        }

        let preferredOrder: [MarkerType] = [.mp3, .mp4, .podlove, .extracted, .ai]
        let availableTypes = Set(markers.map(\.type))
        if let selectedType = preferredOrder.first(where: { availableTypes.contains($0) }) {
            return markers.lazy.filter { $0.type == selectedType }.prefix(2).count > 1
        }

        return markers.lazy
            .filter { $0.type != .bookmark && $0.type != .soundbite }
            .prefix(2)
            .count > 1
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
