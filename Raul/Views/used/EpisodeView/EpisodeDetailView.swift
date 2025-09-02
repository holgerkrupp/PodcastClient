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
                   // .blur(radius: 50)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    
                    
            } else {
                Color.accentColor.ignoresSafeArea()
            }
            
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            // Main content
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
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 8.0))
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
                        }else{
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
                            Label("Open Transcript", systemImage: "custom.quote.bubble.rectangle.portrait")
                        }
                        .buttonStyle(.glass)
                        .padding()
                    }else{
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                        }else{
                            if let url = episode.url{
                                Button(action: {
                                    Task{
                                        let actor = EpisodeActor(modelContainer: context.container)
                                        do{
                                            try await actor.transcribe(url)
                                        }catch{
                                            errorMessage = error.localizedDescription
                                        }
                                        
                                    }
                                }) {
                                    Label("Transcribe Episode", systemImage: "quote.bubble.fill")
                                }
                                .buttonStyle(.glass)
                                .padding()
                            }
                            
                        }
                    }
                }
                
            Spacer(minLength: 10)
                
                DownloadControllView(episode: episode, showDelete: false)
                   .symbolRenderingMode(.hierarchical)
                  // .scaledToFit()
                   .padding(8)
                   .foregroundColor(.accentColor)
                //   .minimumScaleFactor(0.5)
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
                      //  shareURL = IdentifiableURL(url: url)
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly) }
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
          //          ChapterListView(chaptes: episode.chapters)
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

#Preview {
    // Sample podcast
    let samplePodcast = Podcast(feed: URL(string: "https://sample.com/feed.xml")!)
    samplePodcast.title = "Sample Podcast"
    samplePodcast.author = "Sample Author"
    samplePodcast.desc = "A podcast about everything and nothing."

    // Sample episode
    let sampleEpisode = Episode(
        id: UUID(),
        guid: "sample-episode-1",
        title: "Episode 1: The Beginning",
        publishDate: .now,
        url: URL(string: "https://sample.com/episode1.mp3")!,
        podcast: samplePodcast,
        duration: 3600,
        author: "Sample Author"
    )
    sampleEpisode.desc = "A fascinating deep dive into the start of something new."
    sampleEpisode.content = "<p>This is some HTML content for the episode.</p>"
    sampleEpisode.link = URL(string: "https://sample.com/episode1")
    sampleEpisode.imageURL = URL(string: "https://sample.com/cover.jpg")
    sampleEpisode.metaData = EpisodeMetaData()
    sampleEpisode.metaData?.episode = sampleEpisode

    let tempFolder = FileManager.default.temporaryDirectory
    let previewFilesManager = DownloadedFilesManager(folder: tempFolder)

    return NavigationStack {
        EpisodeDetailView(episode: sampleEpisode)
            .environment(previewFilesManager)
    }
}

