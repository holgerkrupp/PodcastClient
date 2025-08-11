//
//  EpisodeView.swift
//  Raul
//
//  Created by Holger Krupp on 05.05.25.
//

import SwiftUI
import RichText

struct EpisodeDetailView: View {
    @Environment(\.modelContext) private var context

    
    @Bindable var episode: Episode
    @StateObject private var backgroundImageLoader: ImageLoaderAndCache

    
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
                    .blur(radius: 50)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    
                    
            } else {
                Color.accentColor.ignoresSafeArea()
            }

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
                        if let episodeLink = episode.link {
                            Link(destination: episodeLink) {
                                Label("Open in Browser", systemImage: "safari")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                        Text((episode.publishDate?.formatted(date: .numeric, time: .shortened) ?? ""))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(.primary)
                    }
                    .padding()
                
                
                /*
                HStack {
                    
                    CoverImageView(episode: episode)
                        .frame(width: 50, height: 50)
                    VStack(alignment: .leading) {
                        HStack {
                            Group{
                                if let podcast = episode.podcast {
                                    NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
                                        Text(podcast.title)
                                    }
                                }
                            }
                            .font(.title2)
                                .foregroundColor(.primary)

                        }

                        HStack{
                            if let remainingTime = episode.remainingTime,remainingTime != episode.duration, remainingTime > 0 {
                                Text(Duration.seconds(episode.remainingTime ?? 0.0).formatted(.units(width: .narrow)) + " remaining")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }else{
                                Text(Duration.seconds(episode.duration ?? 0.0).formatted(.units(width: .narrow)))
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                        Spacer()
                            Text((episode.publishDate?.formatted(date: .numeric, time: .shortened) ?? ""))
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                        
                        
                    }
                }
                .padding()
            */
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
                


                RichText(html: episode.content ?? episode.desc ?? "")
                    .linkColor(light: Color.secondary, dark: Color.secondary)
                    .richTextBackground(.clear)
                    .padding()
                    
                  
           

                

                
                if episode.preferredChapters.count > 1 {
                    ChapterListView(episodeURL: episode.url)
                }
            }
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
               
            )
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

