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

    @Bindable var episode: Episode
    @StateObject private var backgroundImageLoader: ImageLoaderAndCache
    @State private var shareURL: IdentifiableURL?

    @State private var errorMessage: String? = nil
    @State private var liveTranscriptionItem: TranscriptionItem?
    @State private var isLoadingTranscript: Bool = false
    @State private var isStartingTranscription: Bool = false
    @State private var showTranscriptSheet: Bool = false


    
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
                        .frame(width: 300)
                    }
                    
                    CoverImageView(episode: episode)
                        .frame(width: 300, height: 300)
                    
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
                            }
                        }
                    }
                    
                    Spacer(minLength: 10)
                    
                    DownloadControllView(episode: episode, showDelete: false)
                        .symbolRenderingMode(.hierarchical)
                        .padding(8)
                        .foregroundColor(.accent)
                        .labelStyle(.iconOnly)
                    
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
                        }
                    }
                    .padding()
                    
                    SocialView(socials: episode.social)
                        .padding()
                    PeopleView(people: episode.people)
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
                if let image = UIImage(data: backgroundImageLoader.imageData) {
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
                            .navigationTitle("Transcript")
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
    let item: TranscriptionItem
    
    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch item.state {
                case .queued, .preparingModel, .downloadingModel, .analyzing, .saving:
                    Image(systemName: "quote.bubble.fill")
                        .symbolEffect(.pulse.byLayer, options: .repeat(.continuous))
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
        .frame(width: 200, alignment: .leading)
        .padding(10)
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.2), value: item.progress)
        .animation(.easeInOut(duration: 0.2), value: item.state)
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
