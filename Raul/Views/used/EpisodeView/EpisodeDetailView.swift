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
    // Add this near your other state vars:
    @State private var liveTranscriptionItem: TranscriptionItem?


    
    init(episode: Episode) {
        self._episode = Bindable(wrappedValue: episode)
        let imageURL = episode.imageURL ?? episode.podcast?.imageURL
        _backgroundImageLoader = StateObject(wrappedValue: ImageLoaderAndCache(imageURL: imageURL ?? URL(string: "about:blank")!))
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = UIImage(data: backgroundImageLoader.imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Color.accent.ignoresSafeArea()
                }
                
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

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
                                .buttonStyle(.glass)
                                if fund != episode.funding.last {
                                    Spacer()
                                }
                            }
                        }
                    }
                    
                    HStack{
                        NavigationLink(destination: BookmarkListView(episode: episode)) {
                            Label("Show Bookmarks", systemImage: "bookmark.fill")
                        }
                        .buttonStyle(.glass)
                        .padding()
                        
                        if let transcriptLines = episode.transcriptLines, transcriptLines.count > 0 {
                            NavigationLink(destination:  TranscriptListView(transcriptLines: transcriptLines)) {
                                Label("Transcript", image: "custom.quote.bubble.rectangle.portrait")
                            }
                            .buttonStyle(.glass)
                            .padding()
                        } else {
                            // Replace the slot where you show "Transcribe" with:
                            if let item = liveTranscriptionItem ?? episode.transcriptionItem, item.isTranscribing {
                                TranscriptionProgressView(item: item)
                                    .padding()
                                    .onAppear {
                                        // Keep local state synced if episode.transcriptionItem arrives later
                                        if liveTranscriptionItem == nil {
                                            liveTranscriptionItem = episode.transcriptionItem
                                        }
                                    }
                            } else if let url = episode.url {
                                Button(action: {
                                    Task { @MainActor in
                                        do {
                                            let actor = EpisodeActor(modelContainer: context.container)
                                            try await actor.transcribe(url)
                                            // Grab the item from the manager and set local state so UI flips immediately
                                            if let id = episode.id as UUID?,
                                               let item = await TranscriptionManager.shared.item(for: id) {
                                                liveTranscriptionItem = item
                                            } else {
                                                // Fallback: if item not yet registered, poll once after a short delay
                                                try? await Task.sleep(nanoseconds: 200_000_000)
                                                if let id = episode.id as UUID?,
                                                   let item = await TranscriptionManager.shared.item(for: id) {
                                                    liveTranscriptionItem = item
                                                }
                                            }
                                        } catch {
                                            errorMessage = error.localizedDescription
                                        }
                                    }
                                }) {
                                    Label("Transcribe", systemImage: "quote.bubble.fill")
                                }
                                .buttonStyle(.glass)
                                .padding()
                            }
                        }
                    }
                    
                    Spacer(minLength: 10)
                    
                    DownloadControllView(episode: episode, showDelete: false)
                        .symbolRenderingMode(.hierarchical)
                        .padding(8)
                        .foregroundColor(.accent)
                        .labelStyle(.iconOnly)
                    
                    if Player.shared.currentEpisodeID != episode.id {
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
                            .buttonStyle(.glass)
                        }
                        Spacer()
                        if let url = episode.deeplinks?.first ?? episode.link {
                            ShareLink(item: url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.glass)
                        }
                    }
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
            .sheet(item: $shareURL) { identifiable in
                ShareLink(item: identifiable.url) { Text("Share Episode") }
            }
        }
        .navigationTitle(episode.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// A compact progress/status view that fits where the button sits.
@MainActor
private struct TranscriptionProgressView: View {
    @State var item: TranscriptionItem
    
    var body: some View {
        VStack(spacing: 8) {
            Group {
                switch item.state {
                case .queued, .preparingModel, .downloadingModel, .analyzing, .saving:
                    ProgressView(value: progressValue, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.caption)
                if showsPercent {
                    Text("\(Int((item.progress.clamped(to: 0...1)) * 100))%")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
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
