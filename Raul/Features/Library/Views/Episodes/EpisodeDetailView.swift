//
//  EpisodeView.swift
//  Raul
//
//  Created by Holger Krupp on 05.05.25.
//

import SwiftUI
import SwiftData
import ESADesignKit

struct EpisodeDetailView: View {
    @Environment(\.modelContext) private var context

    @Bindable var episode: Episode
    private let transcriptSearchNavigation: TranscriptSearchNavigation?

    @State private var errorMessage: String? = nil
    @State private var isLoadingTranscript: Bool = false
    @State private var showTranscriptSheet: Bool = false
#if DEBUG
    @State private var isDeletingTranscript = false
    @State private var showDeleteTranscriptConfirmation = false
#endif
    init(episode: Episode, transcriptSearchNavigation: TranscriptSearchNavigation? = nil) {
        self._episode = Bindable(wrappedValue: episode)
        self.transcriptSearchNavigation = transcriptSearchNavigation
        self._showTranscriptSheet = State(initialValue: transcriptSearchNavigation != nil)
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    EpisodeProgressView(episode: episode)
                        .fullPageScreenshotSupport()

                    EpisodeDetailPrimaryActionsView(episode: episode)
                        .modelContainer(context.container)

                    EpisodeDetailContentToolsView(
                        episode: episode,
                        isLoadingTranscript: isLoadingTranscript,
                        openTranscript: {
                            Task { @MainActor in await openTranscript() }
                        }
                    )
                    .modelContainer(context.container)

                    EpisodeDetailShowNotesSection(episode: episode)

                    EpisodeDetailMoreMenu(
                        episode: episode,
                        onDeleteTranscript: {
#if DEBUG
                            showDeleteTranscriptConfirmation = true
#endif
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    EpisodeDetailSupportSection(episode: episode)

                    if let podcast = episode.podcast {
                        EpisodeDetailPodcastLink(podcast: podcast)
                    } else if episode.source == .sideLoaded {
                        Label("Side loaded episode", systemImage: "square.and.arrow.down.on.square")
                            .font(.subheadline.weight(.semibold))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    EpisodeDetailMetadataSections(episode: episode)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .coverHero(image: .url(episode.imageURL ?? episode.podcast?.imageURL), title: episode.title)
        }
        .ESAFullBackground(image: episode.imageURL ?? episode.podcast?.imageURL)
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
        .platformInlineNavigationTitle()
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
                    endTime: line.endTime,
                    source: .publisher
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

private struct EpisodeDetailPrimaryActionsView: View {
    let episode: Episode

    var body: some View {
        VStack(spacing: 10) {
            EpisodeControlView(
                episode: episode,
                showsPlaylistPickerTip: true,
                usesDetailLayout: true
            )
            .frame(maxWidth: .infinity)

            if episode.source != .sideLoaded {
                DownloadControllView(episode: episode, showDelete: true, showsLabels: true)
                    .frame(minHeight: 44)
            }
        }
    }
}

private struct EpisodeDetailContentToolsView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var episode: Episode
    @State private var aiGeneration = EpisodeAIGenerationCoordinator.shared
    @State private var isShowingChapters = false

    let isLoadingTranscript: Bool
    let openTranscript: () -> Void

    private var hasTranscript: Bool {
        episode.transcriptLines?.isEmpty == false
            || episode.externalFiles.contains(where: { $0.category == .transcript })
    }

    private var hasChapters: Bool {
        episode.hasDisplayableChaptersOrSoundbites
    }

    private var generationAction: EpisodeAIGenerationAction? {
        guard episode.url != nil else { return nil }
        return EpisodeAIGenerationPolicy.action(
            isAvailable: AppleIntelligenceAvailability.isAvailable,
            hasTranscript: hasTranscript,
            hasUsableChapters: hasChapters
        )
    }

    private var bookmarkCount: Int {
        episode.bookmarks?.count ?? 0
    }

    var body: some View {
        if hasTranscript || hasChapters || bookmarkCount > 0 || generationAction != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Episode content")
                    .font(.headline)

                // Flow naturally sized native glass actions; don't stretch
                // each action to occupy a wide, flat grid cell.
                FlowRows(spacing: 8) {
                    if hasChapters {
                        Button {
                            isShowingChapters = true
                        } label: {
                            Label("Chapters", systemImage: "list.bullet")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.glass(.clear))
                        .accessibilityHint("Opens this episode's chapter list")
                    }

                    if hasTranscript {
                        Button(action: openTranscript) {
                            if isLoadingTranscript {
                                    Label("Loading transcript", systemImage: "ellipsis")
                                    .frame(minHeight: 44)
                            } else {
                                Label("Transcript", image: "custom.quote.bubble.rectangle.portrait")
                                    .frame(minHeight: 44)
                            }
                        }
                        .buttonStyle(.glass(.clear))
                        .disabled(isLoadingTranscript)
                        .accessibilityLabel(isLoadingTranscript ? "Loading transcript" : "Open captions and transcript")
                        .accessibilityHint("Opens episode captions if available")
                        .accessibilityInputLabels([Text("Open captions"), Text("Open transcript")])
                    }

                    if bookmarkCount > 0 {
                        NavigationLink(destination: BookmarkListView(episode: episode)) {
                            Label("Bookmarks (\(bookmarkCount))", systemImage: "bookmark.fill")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.glass(.clear))
                    }
                

                if let generationAction, let episodeURL = episode.url {
                    EpisodeAIGenerationControl(
                        action: generationAction,
                        state: aiGeneration.state(for: episodeURL),
                        start: { action in
                            aiGeneration.start(
                                action: action,
                                episodeURL: episodeURL,
                                modelContainer: modelContext.container
                            )
                        },
                        cancel: { Task { await aiGeneration.cancel(episodeURL: episodeURL) } }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheet(isPresented: $isShowingChapters) {
                NavigationStack {
                    ChapterListView(episode: episode)
                        .platformInlineNavigationTitle()
                }
                .presentationDragIndicator(.visible)
            }
        }
    }
}

private struct EpisodeDetailShowNotesSection: View {
    let episode: Episode

    private var notesHTML: String {
        episode.content ?? episode.desc ?? ""
    }

    var body: some View {
        if notesHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            VStack(alignment: .leading, spacing: 4) {
                Text("Show Notes")
                    .font(.headline)
                ShownoteContentView(html: notesHTML)
                    .padding(.top, 4)
            }
        }
    }
}

private struct EpisodeDetailMoreMenu: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var episode: Episode
    @Bindable private var player = Player.shared
    let onDeleteTranscript: () -> Void

    private var isCurrentEpisode: Bool {
        guard let episodeURL = episode.url else { return false }
        return player.currentEpisodeURL == episodeURL
    }

    private var isShowingVideo: Bool {
        isCurrentEpisode && player.currentPlaybackIsVideo
    }

    private var mediaSwitchTitle: String {
        isShowingVideo ? "Switch to Audio" : "Switch to Video"
    }

    var body: some View {
        Menu {
            if let episodeLink = episode.link {
                Link(destination: episodeLink) {
                    Label("Open in Browser", systemImage: "safari")
                }
            }

            if let shareURL = episode.deeplinks?.first ?? episode.link {
                ShareLink(item: shareURL) {
                    Label("Share episode", systemImage: "square.and.arrow.up")
                }
            }

            if episode.hasAlternateVideo {
                Button {
                    Task { await switchEpisodeMedia() }
                } label: {
                    Label(mediaSwitchTitle, systemImage: isShowingVideo ? "waveform" : "play.rectangle")
                }
            }

            Button {
                Task { await toggleArchivedState() }
            } label: {
                Label(
                    episode.metaData?.isArchived == true ? "Unarchive episode" : "Archive episode",
                    systemImage: episode.metaData?.isArchived == true ? "archivebox.fill" : "archivebox"
                )
            }

#if DEBUG
            Menu("Developer Tools", systemImage: "ladybug") {
                NavigationLink {
                    EpisodeDebugMetadataView(episode: episode)
                } label: {
                    Label("Episode Debug Metadata", systemImage: "info.circle")
                }
                if episode.transcriptLines?.isEmpty == false {
                    Button("Delete Transcript", systemImage: "trash", role: .destructive, action: onDeleteTranscript)
                        .accessibilityHint("Deletes this episode's transcript so it can be generated again")
                }
            }
#endif
        } label: {
            Label("More", systemImage: "ellipsis")
                .labelStyle(.titleAndIcon)
                .frame(minHeight: 50)
                .padding(.horizontal, 8)
        }
        .buttonStyle(.glass(.clear))
        .accessibilityLabel("More episode actions")
    }

    @MainActor
    private func switchEpisodeMedia() async {
        if isCurrentEpisode {
            await player.switchCurrentEpisodeMedia()
        } else {
            await player.playEpisode(episode.url, playDirectly: true, mediaSelection: .alternateVideo)
        }
    }

    @MainActor
    private func toggleArchivedState() async {
        let actor = EpisodeActor(modelContainer: modelContext.container)
        if episode.metaData?.isArchived == true {
            await actor.unarchiveEpisode(episode.url)
        } else {
            await actor.archiveEpisode(episode.url)
        }
    }
}

private struct EpisodeDetailSupportSection: View {
    let episode: Episode
    @State private var isExpanded = false

    private var funding: [FundingInfo] {
        episode.funding.isEmpty ? episode.podcast?.funding ?? [] : episode.funding
    }

    private var hasValueSplit: Bool {
        episode.optionalTags?.value?.contains(where: { $0.children.isEmpty == false }) == true
    }

    var body: some View {
        if funding.isEmpty == false || hasValueSplit {
            DisclosureGroup("Support & value", isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(funding) { fund in
                        Link(destination: fund.url) {
                            Label(fund.label, systemImage: "heart")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.glass(.clear))
                    }

                    if hasValueSplit {
                        PodcastValueSplitView(optionalTags: episode.optionalTags, funding: [])
                    }
                }
                .padding(.top, 8)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct EpisodeDetailPodcastLink: View {
    let podcast: Podcast

    var body: some View {
        NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
            HStack(spacing: 12) {
                CoverImageView(podcast: podcast, maxPixelSize: 192, loadDelay: .milliseconds(100))
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(podcast.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let author = podcast.author, author.isEmpty == false {
                        Text(author)
                            .font(.caption)
                            .esaForeground(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the podcast and its episodes")
    }
}

// Metadata is kept behind native disclosures so it remains available without
// competing with the episode's primary actions and show notes.
private struct EpisodeDetailMetadataSections: View {
    let episode: Episode
    @State private var isPeopleExpanded = false
    @State private var isTechnicalExpanded = false

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
        VStack(spacing: 10) {
            if episode.social.isEmpty == false || episode.people.isEmpty == false || fallbackAuthor != nil {
                DisclosureGroup("People & links", isExpanded: $isPeopleExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        if episode.social.isEmpty == false {
                            SocialView(socials: episode.social)
                        }
                        if episode.people.isEmpty == false || fallbackAuthor != nil {
                            PeopleView(people: episode.people, fallbackAuthor: fallbackAuthor)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if let optionalTags = episode.optionalTags, optionalTags.isEmpty == false {
                DisclosureGroup("Technical metadata", isExpanded: $isTechnicalExpanded) {
                    PodcastNamespaceMetadataView(
                        optionalTags: optionalTags,
                        title: "Episode Metadata",
                        hidesRenderableValueBlocks: true
                    )
                    .padding(.top, 8)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
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
