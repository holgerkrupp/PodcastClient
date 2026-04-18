//
//  EpisodeView.swift
//  Raul
//
//  Created by Holger Krupp on 05.05.25.
//

import SwiftUI
import RichText

private struct IdentifiableURL: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
}

struct EpisodeDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.deviceUIStyle) var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var episode: Episode
    @StateObject private var backgroundImageLoader: ImageLoaderAndCache
    @State private var shareURL: IdentifiableURL?

    @State private var errorMessage: String? = nil
    @State private var liveTranscriptionItem: TranscriptionItem?
    @State private var isLoadingTranscript: Bool = false
    @State private var isStartingTranscription: Bool = false
    @State private var showTranscriptSheet: Bool = false
    @ScaledMetric(relativeTo: .title2) private var podcastCardWidth: CGFloat = 300
    @ScaledMetric(relativeTo: .title2) private var artworkSize: CGFloat = 300


    
    init(episode: Episode) {
        self._episode = Bindable(wrappedValue: episode)
        let imageURL = episode.imageURL ?? episode.podcast?.imageURL
        _backgroundImageLoader = StateObject(wrappedValue: ImageLoaderAndCache(imageURL: imageURL ?? URL(string: "about:blank")!))
    }
    
    var body: some View {
        let _ = episode.refresh
        let hasLoadedTranscript = episode.transcriptLines?.isEmpty == false
        let hasRemoteTranscript = episode.externalFiles.contains(where: { $0.category == .transcript })
        let activeTranscriptionItem = liveTranscriptionItem ?? episode.transcriptionItem
        
            ZStack {


                ScrollView {
                    if let podcast = episode.podcast {
                        NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
                            HStack {
                                CoverImageView(episode: episode)
                                    .frame(width: 50, height: 50)
                                Text(podcast.title)
                                    .font(.title2)
                                    .foregroundColor(.primary)
                            }
                        }
                        .padding()
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20.0))
                        .frame(maxWidth: podcastCardWidth)
                    } else if episode.source == .sideLoaded {
                        Label("Side loaded", systemImage: "square.and.arrow.down.on.square")
                            .font(.title2.weight(.semibold))
                            .padding()
                            .frame(maxWidth: podcastCardWidth, alignment: .leading)
                            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20.0))
                    }

                    CoverImageView(episode: episode)
                        .frame(width: artworkSize, height: artworkSize)
                        .accessibilityHidden(true)
                    
                    HStack{
                        if let remainingTime = episode.remainingTime,remainingTime != episode.duration, remainingTime > 0 {
                            Text(Duration.seconds(episode.remainingTime ?? 0.0).formatted(.units(width: .narrow)) + " remaining")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundColor(.primary)
                        } else {
                            Text(Duration.seconds(episode.duration ?? 0.0).formatted(.units(width: .narrow)))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundColor(.primary)
                        }
                        Spacer()
                        Text((episode.publishDate?.formatted(date: .numeric, time: .shortened) ?? ""))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(.primary)
                    }
                    .padding()
                    
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
                    GlassEffectContainer(spacing: 20.0) {
                        HStack{
                            NavigationLink(destination: BookmarkListView(episode: episode)) {
                                Label("Bookmarks", systemImage: "bookmark.fill")
                            }
                            .buttonStyle(.glass(.clear))
                            .padding()
                            
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
                                .buttonStyle(.glass(.clear))
                                .padding()
                                .disabled(isLoadingTranscript)
                                .accessibilityLabel("Open captions and transcript")
                                .accessibilityHint("Opens episode captions if available")
                                .accessibilityInputLabels([Text("Open captions"), Text("Open transcript")])
                            } else if let item = activeTranscriptionItem, item.isTranscribing || isStartingTranscription {
                                TranscriptionProgressView(item: item)
                                    .padding()
                            } else if let url = episode.url {
                                Button(action: {
                                    Task { await startTranscription(from: url) }
                                }) {
                                    Label("Transcribe", systemImage: "quote.bubble.fill")
                                }
                                .buttonStyle(.glass(.clear))
                                .padding()
                                .disabled(isStartingTranscription)
                                .accessibilityLabel("Generate captions")
                                .accessibilityHint("Creates an on-device transcript to use as captions")
                                .accessibilityInputLabels([Text("Generate captions"), Text("Transcribe episode")])
                            }
                        }
                    }
                    
                    Spacer(minLength: 10)
                    
                    if episode.source != .sideLoaded {
                        DownloadControllView(episode: episode, showDelete: false)
                            .symbolRenderingMode(.hierarchical)
                            .padding(8)
                            .foregroundColor(.accent)
                            .labelStyle(.iconOnly)
                    }
                    
                    if Player.shared.currentEpisodeURL != episode.url {
                        EpisodeControlView(episode: episode)
                            .modelContainer(context.container)
                            .frame(height: 50)
                            .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    }
                    
                    HStack{
                        if let episodeLink = episode.link {
                            Link(destination: episodeLink) {
                                Label("Open in Browser", systemImage: "safari")
                            }
                            .buttonStyle(.glass(.clear))
                        }
                        Spacer()
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
                    
                    SocialView(socials: episode.social)
                        .padding()
                    PeopleView(people: episode.people)
                        .padding()
                    PodcastNamespaceMetadataView(optionalTags: episode.optionalTags)
                        .padding()
                    
                    RichText(html: episode.content ?? episode.desc ?? "")
                        .linkColor(light: Color.secondary, dark: Color.secondary)
                        .backgroundColor(.transparent)
                        .padding()
                    
                    if episode.preferredChapters.count > 1 {
                        ChapterListView(episode: episode)
                    }
                }
            }
            .background{
                if let image = backgroundImageLoader.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity) // Ensure it takes up all available space
                                        .ignoresSafeArea(.all) // Crucial: extends the image behind safe areas (like under the status bar)
                                        
                        .blur(radius: 20)
                        .opacity(0.5)

                    
                } else {
                    Color.accent.ignoresSafeArea()
                }
            }
            .sheet(item: $shareURL) { identifiable in
                ShareLink(item: identifiable.url) { Text("Share Episode") }
            }
            .sheet(isPresented: $showTranscriptSheet) {
                NavigationStack {
                    if let transcriptLines = episode.transcriptLines, transcriptLines.isEmpty == false {
                        TranscriptListView(transcriptLines: transcriptLines, episode: episode)
                            .navigationTitle("Captions & Transcript")
                            .navigationBarTitleDisplayMode(.inline)
                    } else {
                        ContentUnavailableView("Transcript Unavailable", systemImage: "quote.bubble")
                    }
                }
            }
            .task(id: episode.url) {
                liveTranscriptionItem = await currentTranscriptionItem()
            }
            .onChange(of: activeTranscriptionItem?.state) {
                if case .finished = activeTranscriptionItem?.state {
                    liveTranscriptionItem = nil
                }
            }
        
        .navigationTitle(episode.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func openTranscript() async {
        if episode.transcriptLines?.isEmpty == false {
            showTranscriptSheet = true
            return
        }

        guard !isLoadingTranscript else { return }
        isLoadingTranscript = true
        defer { isLoadingTranscript = false }

        do {
            let actor = EpisodeActor(modelContainer: context.container)
            try await actor.downloadTranscript(episode.persistentModelID)
            showTranscriptSheet = episode.transcriptLines?.isEmpty == false
            if showTranscriptSheet == false {
                errorMessage = "The transcript file could not be loaded."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func startTranscription(from url: URL) async {
        guard !isStartingTranscription else { return }
        isStartingTranscription = true
        errorMessage = nil

        if let existingItem = await currentTranscriptionItem() {
            liveTranscriptionItem = existingItem
        } else {
            let placeholder = TranscriptionItem(episodeURL: url, sourceURL: url)
            placeholder.setState(.queued, progress: 0.0, status: "Queued")
            liveTranscriptionItem = placeholder
        }

        defer {
            isStartingTranscription = false
        }

        do {
            let actor = EpisodeActor(modelContainer: context.container)
            try await actor.transcribe(url)
            if let item = await currentTranscriptionItem() {
                liveTranscriptionItem = item
            }
        } catch {
            errorMessage = error.localizedDescription
            liveTranscriptionItem?.setState(.failed(error: error.localizedDescription), status: "Failed")
        }
    }

    private func currentTranscriptionItem() async -> TranscriptionItem? {
        guard let episodeURL = episode.url else { return nil }
        return await TranscriptionManager.shared.item(for: episodeURL)
    }
}

// A compact progress/status view that fits where the button sits.
@MainActor
private struct TranscriptionProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var progressCardWidth: CGFloat = 200
    let item: TranscriptionItem
    
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
                        Text("\(Int((progressValue.clamped(to: 0...1)) * 100))%")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: progressValue, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(.accent)
                Text(statusTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
