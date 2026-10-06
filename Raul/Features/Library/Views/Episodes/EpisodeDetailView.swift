//
//  EpisodeView.swift
//  Raul
//
//  Created by Holger Krupp on 05.05.25.
//

import SwiftUI
import SwiftData
import RichText
import ESADesignKit

private struct IdentifiableURL: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
}

struct EpisodeDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.deviceUIStyle) var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var episode: Episode
    private let transcriptSearchNavigation: TranscriptSearchNavigation?
    @Bindable private var player = Player.shared
    @State private var shareURL: IdentifiableURL?
    @State private var aiGeneration = EpisodeAIGenerationCoordinator.shared

    @State private var errorMessage: String? = nil
    @State private var isLoadingTranscript: Bool = false
    @State private var showTranscriptSheet: Bool = false
#if DEBUG
    @State private var isDeletingTranscript = false
    @State private var showDeleteTranscriptConfirmation = false
#endif
    @ScaledMetric(relativeTo: .title2) private var podcastCardWidth: CGFloat = 300


    
    init(episode: Episode, transcriptSearchNavigation: TranscriptSearchNavigation? = nil) {
        self._episode = Bindable(wrappedValue: episode)
        self.transcriptSearchNavigation = transcriptSearchNavigation
        self._showTranscriptSheet = State(initialValue: transcriptSearchNavigation != nil)
    }
    
    var body: some View {
        let _ = episode.refresh
        let hasLoadedTranscript = episode.transcriptLines?.isEmpty == false
        let hasRemoteTranscript = episode.externalFiles.contains(where: { $0.category == .transcript })
        
            ZStack {
                ScrollView {
                    EpisodeProgressView(episode: episode)
                        .padding()
                        .fullPageScreenshotSupport()
                        
                    if episode.source != .sideLoaded {
                        DownloadControllView(episode: episode, showDelete: false)
                            .symbolRenderingMode(.hierarchical)
                            .padding(8)
                            .foregroundColor(.accent)
                            
                    }
                    
                   
                        EpisodeControlView(episode: episode, showsPlaylistPickerTip: true)
                            .modelContainer(context.container)
                            .frame(height: 50)
                            .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    
                    
                    Spacer(minLength: 16)
                    
                    if episode.funding.count > 0 {
                        HStack{
                            ForEach(episode.funding ) { fund in
                                Link(destination: fund.url) {
                                    Label(fund.label, systemImage: style.currencySFSymbolName)
                                }
                                .buttonStyle(.glass(.clear))
                                if fund != episode.funding.last {
                                    Spacer()
                                }
                            }
                        }
                    }
                    PodcastValueSplitView(
                        optionalTags: episode.optionalTags,
                        funding: episode.funding.isEmpty ? episode.podcast?.funding ?? [] : episode.funding
                    )
                    
                        HStack{
                            if let bookMarkCount = episode.bookmarks?.count, bookMarkCount > 0 {
                                NavigationLink(destination: BookmarkListView(episode: episode)) {
                                    Label("Bookmarks", systemImage: "bookmark.fill")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.glass(.clear))
                                .padding()
                            }


                            if episode.hasAlternateVideo {
                                Button {
                                    Task {
                                        await switchEpisodeMedia()
                                    }
                                } label: {
                                    Label(
                                        episodeMediaSwitchTitle,
                                        systemImage: isCurrentEpisodeShowingVideo ? "waveform" : "play.rectangle"
                                    )
                                    .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.glass(.clear))
                                .padding()
                                .accessibilityLabel(episodeMediaSwitchTitle)
                                .accessibilityHint("Changes this episode between the audio enclosure and alternate video stream")
                            }
                            
                            if hasLoadedTranscript || hasRemoteTranscript {
                                Button {
                                    Task { @MainActor in
                                        await openTranscript()
                                    }
                                } label: {
                                    if isLoadingTranscript {
                                        Label("Loading Transcript", systemImage: "ellipsis")
                                    } else {
                                        Label("Transcript", image: "custom.quote.bubble.rectangle.portrait")
                                    }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.glass(.clear))
                                .padding()
                                .disabled(isLoadingTranscript)
                                .accessibilityLabel("Open captions and transcript")
                                .accessibilityHint("Opens episode captions if available")
                                .accessibilityInputLabels([Text("Open captions"), Text("Open transcript")])
                            }
                            if let url = episode.url {
                                EpisodeAIGenerationControl(
                                    action: EpisodeAIGenerationPolicy.action(
                                        isAvailable: AppleIntelligenceAvailability.isAvailable,
                                        hasTranscript: hasLoadedTranscript,
                                        hasUsableChapters: episode.hasDisplayableChaptersOrSoundbites
                                    ),
                                    state: aiGeneration.state(for: url),
                                    start: { action in
                                        aiGeneration.start(action: action, episodeURL: url, modelContainer: context.container)
                                    },
                                    cancel: { Task { await aiGeneration.cancel(episodeURL: url) } }
                                )
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                            }
#if DEBUG
                        if hasLoadedTranscript {
                            Button(role: .destructive) {
                                showDeleteTranscriptConfirmation = true
                            } label: {
                                Label(
                                    isDeletingTranscript ? "Deleting…" : "Delete Transcript",
                                    systemImage: "trash"
                                )
                            }
                            .buttonStyle(.glass(.clear))
                            .tint(.blue)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .disabled(isDeletingTranscript)
                            .accessibilityHint("Deletes this episode's transcript so it can be generated again")
                        }

                            Spacer()
                        
#endif
                        }
                    


                    
                    Spacer(minLength: 10)
                    

                    
                    HStack{
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
                        Spacer()
#endif
                        if let url = episode.deeplinks?.first ?? episode.link {
                            ShareLink(item: url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.glass(.clear))
                            .accessibilityLabel("Share episode")
                            .accessibilityHint("Opens the share sheet for this episode")
                        }
                    }
                    .padding()
                    if let podcast = episode.podcast {
                        NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
                            
                            PodcastRowView(podcast: podcast)
                            /*
                            HStack {
                                CoverImageView(episode: episode)
                                    .frame(width: 50, height: 50)
                                Text(podcast.title)
                                    .font(.title2)
                                    .esaForeground(.primary)
                            }
                             */
                        }
                     //   .padding()
                     //   .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20.0))
                        .frame(maxWidth: .infinity)
                    } else if episode.source == .sideLoaded {
                        Label("Side loaded", systemImage: "square.and.arrow.down.on.square")
                            .font(.title2.weight(.semibold))
                            .padding()
                            .frame(maxWidth: podcastCardWidth, alignment: .leading)
                            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20.0))
                    }
                    EpisodeDetailMetadataSections(episode: episode)
                }
                .coverHero(image: .url(episode.imageURL ?? episode.podcast?.imageURL), title: episode.title)
            }
            .ESAFullBackground(image: episode.imageURL ?? episode.podcast?.imageURL)
            .sheet(item: $shareURL) { identifiable in
                ShareLink(item: identifiable.url) { Text("Share Episode") }
            }
            .alert(
                "Transcript Error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { isPresented in
                        if isPresented == false {
                            errorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
#if DEBUG
            .confirmationDialog(
                "Delete this transcript?",
                isPresented: $showDeleteTranscriptConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Transcript", role: .destructive) {
                    Task { await deleteTranscript() }
                }
                .tint(.blue)
                Button("Cancel", role: .cancel) {}
                    .tint(.blue)
            } message: {
                Text("This removes the transcript and its transcription history so the episode can be transcribed again.")
            }
#endif
            .sheet(isPresented: $showTranscriptSheet) {
                NavigationStack {
                    if let transcriptLines = episode.transcriptLines, transcriptLines.isEmpty == false {
                        TranscriptListView(
                            transcriptLines: transcriptLines,
                            episode: episode,
                            searchNavigation: transcriptSearchNavigation
                        )
                            .navigationTitle("Captions & Transcript")
                            .platformInlineNavigationTitle()
                    } else {
                        ContentUnavailableView("Transcript Unavailable", systemImage: "quote.bubble")
                    }
                }
            }
            .task(id: episode.url) {
                SystemPressureGate.shared.noteUserInteraction()
            }
        
        //.navigationTitle(episode.title)
        .platformInlineNavigationTitle()
    }

    private var isCurrentEpisode: Bool {
        player.currentEpisodeURL == episode.url
    }

    private var isCurrentEpisodeShowingVideo: Bool {
        isCurrentEpisode && player.currentPlaybackIsVideo
    }

    private var episodeMediaSwitchTitle: String {
        isCurrentEpisodeShowingVideo ? "Switch to Audio" : "Switch to Video"
    }

    @MainActor
    private func switchEpisodeMedia() async {
        if isCurrentEpisode {
            await player.switchCurrentEpisodeMedia()
        } else {
            await player.playEpisode(
                episode.url,
                playDirectly: true,
                mediaSelection: .alternateVideo
            )
        }
    }

    @MainActor
    private func openTranscript() async {
        errorMessage = nil

        if episode.transcriptLines?.isEmpty == false {
            showTranscriptSheet = true
            return
        }

        guard !isLoadingTranscript else { return }
        isLoadingTranscript = true
        defer { isLoadingTranscript = false }

        do {
            try await downloadLinkedTranscriptIntoCurrentContext()
            showTranscriptSheet = episode.transcriptLines?.isEmpty == false
            if showTranscriptSheet == false {
                errorMessage = "The transcript file could not be loaded."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func downloadLinkedTranscriptIntoCurrentContext() async throws {
        let settingsActor = PodcastSettingsModelActor(modelContainer: context.container)
        guard await settingsActor.getTranscriptionsEnabled() else {
            throw EpisodeActor.TranscriptError.noTranscriptFileFound
        }

        guard let transcriptFile = bestTranscriptFile(in: episode.externalFiles.filter({ $0.category == .transcript })),
              let transcriptURL = URL(string: transcriptFile.url) else {
            throw EpisodeActor.TranscriptError.noTranscriptFileFound
        }

        guard let transcriptText = await downloadStringFile(url: transcriptURL) else {
            throw EpisodeActor.TranscriptError.decodingFailed
        }

        let lines = decodeTranscriptLines(transcriptText)
        guard lines.isEmpty == false else {
            throw EpisodeActor.TranscriptError.decodingFailed
        }

        episode.transcriptLines = lines
        episode.refresh.toggle()
        context.saveIfNeeded()

        if let episodeURL = episode.url {
            _ = await EpisodeActor(modelContainer: context.container).regenerateTranscriptChapters(for: episodeURL)
        }
    }

    private func bestTranscriptFile(in files: [ExternalFile]) -> ExternalFile? {
        let preferredTypes = [
            "text/vtt",
            "text/webvtt",
            "application/vtt",
            "application/x-subrip",
            "text/srt",
            "application/json",
            "text/json",
            "text/plain"
        ]

        if let fileByType = files.first(where: { file in
            guard let type = file.fileType?.lowercased() else { return false }
            return preferredTypes.contains { type.contains($0) }
        }) {
            return fileByType
        }

        if let vttByExtension = files.first(where: { URL(string: $0.url)?.pathExtension.lowercased() == "vtt" }) {
            return vttByExtension
        }
        if let srtByExtension = files.first(where: { URL(string: $0.url)?.pathExtension.lowercased() == "srt" }) {
            return srtByExtension
        }
        if let jsonByExtension = files.first(where: { URL(string: $0.url)?.pathExtension.lowercased() == "json" }) {
            return jsonByExtension
        }

        return files.first
    }

    private func downloadStringFile(url: URL) async -> String? {
        var resolvedURL = url
        let accessProfile = podcastAccessProfile

        do {
            let status = try await resolvedURL.status(profile: accessProfile)
            switch status?.statusCode {
            case 200:
                break
            case 404:
                return nil
            case 410:
                if let newURL = status?.newURL {
                    resolvedURL = newURL
                }
            default:
                break
            }

            let (data, _) = try await PodcastHTTPClient.shared.data(for: resolvedURL, profile: accessProfile)
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private var podcastAccessProfile: PodcastAccessProfile? {
        guard let metadata = episode.podcast?.metaData,
              let profileID = metadata.accessProfileID,
              let rawKind = metadata.accessKindRawValue,
              let kind = PodcastAccessKind(rawValue: rawKind),
              let feedURL = episode.podcast?.feed else {
            return nil
        }
        return PodcastAccessProfile(
            id: profileID,
            kind: kind,
            resourceURL: feedURL,
            providerID: metadata.accessProviderID.flatMap(PremiumPodcastProviderID.init(rawValue:))
        )
    }

    private func decodeTranscriptLines(_ transcriptText: String) -> [TranscriptLineAndTime] {
        TranscriptDecoder(transcriptText).transcriptLines
            .map { line in
                TranscriptLineAndTime(
                    speaker: line.speaker,
                    text: line.text,
                    startTime: line.startTime,
                    endTime: line.endTime
                )
            }
            .sorted {
                if $0.startTime != $1.startTime {
                    return $0.startTime < $1.startTime
                }
                let leftEnd = $0.endTime ?? .greatestFiniteMagnitude
                let rightEnd = $1.endTime ?? .greatestFiniteMagnitude
                return leftEnd < rightEnd
            }
    }

#if DEBUG
    @MainActor
    private func deleteTranscript() async {
        guard isDeletingTranscript == false, let episodeURL = episode.url else { return }
        isDeletingTranscript = true
        errorMessage = nil
        defer { isDeletingTranscript = false }

        do {
            try await EpisodeActor(modelContainer: context.container)
                .deleteTranscript(for: episodeURL)
            // The actor deletes through its own ModelContext. Clear this view's
            // relationship immediately instead of waiting for cross-context merging.
            episode.transcriptLines = nil
            episode.refresh.toggle()
            context.saveIfNeeded()
            showTranscriptSheet = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
#endif
}

// Trailing metadata block (socials, people, namespace tags, description, chapters).
// Extracted into its own view so it forms an observation boundary: it only
// re-evaluates when the metadata it reads changes, not on every playback-position
// or import-driven update to the episode. Keeping it small also shrinks the
// EpisodeDetailView body type, which is far cheaper for SwiftUI to copy/diff.
private struct EpisodeDetailMetadataSections: View {
    let episode: Episode

    private var fallbackAuthor: String? {
        guard episode.people.isEmpty else { return nil }
        guard let author = episode.author?.trimmingCharacters(in: .whitespacesAndNewlines),
              author.isEmpty == false,
              author != episode.podcast?.author
        else {
            return nil
        }
        return author
    }

    var body: some View {
        SocialView(socials: episode.social)

        PeopleView(people: episode.people, fallbackAuthor: fallbackAuthor)

        PodcastNamespaceMetadataView(
            optionalTags: episode.optionalTags,
            title: "Episode Metadata",
            hidesRenderableValueBlocks: true
        )

        ShownoteContentView(html: episode.content ?? episode.desc ?? "")
            .padding()

        if episode.hasDisplayableChaptersOrSoundbites {
            ChapterListView(episode: episode)
        }
    }
}

// A compact progress/status view that fits where the button sits.
@MainActor
private struct TranscriptionProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var progressCardWidth: CGFloat = 200
    let item: TranscriptionItem
    let queueEntry: TranscriptionQueueEntry?
    let activeEpisodeTitle: String?
    let moveToNext: () -> Void
    let cancel: () -> Void
    
    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch item.state {
                case .queued, .preparingModel, .downloadingModel, .analyzing, .saving:
                    Image(systemName: "quote.bubble.fill")
                        .symbolEffect(
                            .pulse.byLayer,
                            options: reduceMotion ? .nonRepeating : .repeat(.continuous)
                        )
                        .foregroundStyle(.accent)
                case .finished:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                case .cancelled:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .idle:
                    EmptyView()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Transcribing")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 6)
                    if showsPercent {
                        Text("\(progressValue.clamped(to: 0...1), format: .percent.precision(.fractionLength(0)))")
                            .font(.caption2)
                            .monospacedDigit()
                            .esaForeground(.secondary)
                    }
                }
                ProgressView(value: progressValue, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(.accent)
                Text(statusTitle)
                    .font(.caption2)
                    .esaForeground(.secondary)
                    .lineLimit(2)
                if case let .queued(position)? = queueEntry?.state {
                    if let activeEpisodeTitle {
                        Text("Currently transcribing: \(activeEpisodeTitle)")
                            .font(.caption2)
                            .esaForeground(.secondary)
                            .lineLimit(2)
                    }
                    if position > 1 {
                        Button("Move to Next", action: moveToNext)
                            .font(.caption.weight(.semibold))
                    } else {
                        Text("Next in queue")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.accent)
                    }
                }
                Button(role: .destructive, action: cancel) {
                    Label("Cancel", systemImage: "xmark.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel transcription")
            }
        }
        .frame(width: progressCardWidth, alignment: .leading)
        .padding(10)
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: item.progress)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: item.state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Captions processing")
        .accessibilityValue(statusTitle)
    }
    
    private var progressValue: Double {
        switch item.state {
        case .downloadingModel(let p):
            return p ?? item.progress
        case .analyzing, .saving, .preparingModel, .queued:
            return item.progress
        default:
            return item.progress
        }
    }
    
    private var showsPercent: Bool {
        switch item.state {
        case .downloadingModel(let p):
            return p != nil
        case .analyzing, .saving, .preparingModel:
            return true
        default:
            return false
        }
    }
    
    private var statusTitle: String {
        if item.statusText.isEmpty == false {
            return item.statusText
        }

        switch item.state {
        case .queued: return "Queued"
        case .preparingModel: return "Preparing model…"
        case .downloadingModel: return "Downloading model…"
        case .analyzing: return "Analyzing…"
        case .saving: return "Saving…"
        case .finished: return "Finished"
        case .failed(let err): return "Failed: \(err)"
        case .cancelled: return "Cancelled"
        case .idle: return ""
        }
    }
}

private extension Comparable where Self == Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview("Episode Detail - All Subviews") {
    let previewFilesManager = DownloadedFilesManager(folder: FileManager.default.temporaryDirectory)

    NavigationStack {
        EpisodeDetailView(episode: EpisodeDetailPreviewData.allSubviewsEpisode)
    }
    .environment(previewFilesManager)
    .modelContainer(for: Episode.self, inMemory: true)
}

private enum EpisodeDetailPreviewData {
    static var allSubviewsEpisode: Episode {
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        podcast.title = "Preview Weekly"
        podcast.author = "Preview Host"
        podcast.desc = "A preview podcast to exercise all EpisodeDetailView sections."
        podcast.imageURL = URL(string: "https://picsum.photos/400")

        let episode = Episode(
            title: "Building Better SwiftUI Previews",
            publishDate: Date(timeIntervalSinceNow: -(60 * 60 * 26)),
            url: URL(string: "https://example.com/audio/preview-episode.mp3")!,
            podcast: podcast,
            duration: 3600,
            author: "Preview Editor"
        )

        episode.desc = "Episode detail preview with <b>all</b> sections enabled."
        episode.content = """
        <p>This preview includes social links, people, chapters, funding, transcript actions, and namespace metadata.</p>
        <p><a href="https://example.com/episodes/swiftui-previews">Read full notes</a></p>
        """
        episode.link = URL(string: "https://example.com/episodes/swiftui-previews")
        episode.deeplinks = [URL(string: "https://example.com/app/episode/swiftui-previews")!]
        episode.imageURL = URL(string: "https://picsum.photos/600")
        episode.metaData?.playPosition = 1320
        episode.metaData?.maxPlayposition = 1800

        episode.funding = [
            FundingInfo(url: URL(string: "https://example.com/support")!, label: "Support"),
            FundingInfo(url: URL(string: "https://example.com/membership")!, label: "Membership")
        ]
        episode.social = [
            SocialInfo(url: URL(string: "https://example.social/@previewshow")!, socialprotocol: "activitypub", accountId: "@previewshow", accountURL: URL(string: "https://example.social/@previewshow"), priority: 1),
            SocialInfo(url: URL(string: "https://example.com/previewshow")!, socialprotocol: "website", accountId: nil, accountURL: nil, priority: 2)
        ]
        episode.people = [
            PersonInfo(name: "Ava Preview", role: "host", href: URL(string: "https://example.com/ava"), img: nil),
            PersonInfo(name: "Liam Sample", role: "guest", href: URL(string: "https://example.com/liam"), img: URL(string: "https://picsum.photos/80"))
        ]
        episode.externalFiles = [
            ExternalFile(
                url: "https://example.com/transcripts/swiftui-previews.vtt",
                category: .transcript,
                source: "podcastindex",
                fileType: "text/vtt"
            )
        ]
        episode.optionalTags = namespaceTags

        let intro = Marker(start: 0, title: "Intro", type: .mp3, duration: 180)
        let deepDive = Marker(start: 180, title: "Preview Data Setup", type: .mp3, duration: 1320)
        deepDive.link = URL(string: "https://example.com/chapters/preview-data-setup")
        let recap = Marker(start: 1500, title: "Recap", type: .mp3, duration: 240)

        episode.chapters = [intro, deepDive, recap]
        episode.chapters?.forEach { $0.episode = episode }

        return episode
    }

    static var namespaceTags: PodcastNamespaceOptionalTags {
        var tags = PodcastNamespaceOptionalTags()
        tags.chat = [
            NamespaceNode(
                name: "podcast:chat",
                attributes: ["url": "https://chat.example.com", "protocol": "irc"]
            )
        ]
        tags.license = [
            NamespaceNode(name: "podcast:license", value: "CC-BY-4.0")
        ]
        tags.value = [
            NamespaceNode(
                name: "podcast:value",
                attributes: ["type": "lightning", "method": "keysend"],
                children: [
                    NamespaceNode(
                        name: "podcast:valueRecipient",
                        attributes: ["name": "Host", "address": "03abc", "split": "95"]
                    ),
                    NamespaceNode(
                        name: "podcast:valueRecipient",
                        attributes: ["name": "Producer", "address": "03def", "split": "5"]
                    )
                ]
            )
        ]
        return tags
    }
}
