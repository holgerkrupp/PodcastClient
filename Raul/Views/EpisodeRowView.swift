//
//  EpisodeRowView.swift
//  Raul
//
//  Created by Holger Krupp on 12.04.25.
//
import SwiftUI
import SwiftData

struct EpisodeRowView: View {
    static func == (lhs: EpisodeRowView, rhs: EpisodeRowView) -> Bool {
        lhs.episode.id == rhs.episode.id &&
        lhs.episode.metaData?.lastPlayed == rhs.episode.metaData?.lastPlayed
    }
    @Environment(\.modelContext) private var modelContext
    
    
    let episode: Episode
    @State private var isExtended: Bool = false
    @State private var image: Image?
    @State private var showDetails: Bool = false
     var playlistViewModel = PlaylistViewModel(container: ModelContainerManager().container)
    
    var body: some View {
      
            VStack(alignment: .leading, spacing: 8) {
                VStack{
                    HStack {
                        Text("DEBUG")
                        Image(systemName: episode.metaData?.isArchived ?? false ? "archivebox.fill" : "archivebox")
                        Image(systemName: episode.metaData?.isInbox ?? false ? "tray.fill" : "tray")
                        Image(systemName: episode.metaData?.isHistory ?? false ? "newspaper.fill" : "newspaper")
                        
                        Image(systemName: episode.metaData?.isAvailableLocally ?? false ? "document.fill" : "document")
                            .foregroundColor(episode.metaData?.calculatedIsAvailableLocally ?? false == episode.metaData?.isAvailableLocally ?? false ? .primary : .red)
                        Image(systemName: episode.metaData?.calculatedIsAvailableLocally ?? false ? "document.viewfinder.fill" : "document.viewfinder")
                            .foregroundColor(episode.metaData?.calculatedIsAvailableLocally ?? false == episode.metaData?.isAvailableLocally ?? false ? .primary : .red)
                        
                        if episode.downloadItem?.isDownloading ?? false {
                            Image(systemName: "arrow.down")
                            
                                .id(episode.downloadItem?.id ?? UUID())
                        }
                        
                        
                    }
                    .font(.caption)
                    
                    
                    HStack {
                        Group {
                            if let image = image {
                                image
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                Color.gray.opacity(0.2)
                            }
                            
                        }
                        .frame(width: 50, height: 50)
                        .task {
                            await loadImage()
                        }
                        
                        VStack(alignment: .leading) {
                            HStack {
                                Text(episode.podcast?.title ?? "")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text((episode.publishDate?.formatted(.relative(presentation: .named)) ?? ""))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(episode.title)
                                .font(.headline)
                                .lineLimit(2)
                            if let remainingTime = episode.remainingTime,remainingTime != episode.duration, remainingTime > 0 {
                                Text(Duration.seconds(episode.remainingTime ?? 0.0).formatted(.units(width: .narrow)) + " remaining")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }else{
                                Text(Duration.seconds(episode.duration ?? 0.0).formatted(.units(width: .narrow)))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Button(action: {
                                showDetails.toggle()
                            }) {
                                Text("details")
                            }
                            .buttonStyle(.plain)
                            
                            
                        }
                        
                       
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                
                .onTapGesture {
                    withAnimation {
                        isExtended.toggle()
                    }
                }
                
                if isExtended {
                    
                    EpisodeControlView(episode: episode)
                        .modelContainer(modelContext.container)
                    
                    HStack{
                        Button(action: {
                            Task{
                                await Player.shared.playEpisode(episode.id)
                            }
                        }) {
                            Image(systemName: "play.fill")
                                .resizable()
                                .scaledToFit()
                                .padding(12)
                                .clipShape(Circle())
                                .foregroundColor(.background)
                                .background(
                                    Circle()
                                        .fill(.accent)
                                )
                        }
                        .buttonStyle(.plain)
                        .frame(width: 50, height: 50)
                        
                        Spacer()
                        
                        Button {
                            Task{
                                await playlistViewModel.addEpisode(episode, to: .front)
                                
                            }
                        } label: {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .symbolRenderingMode(.hierarchical)
                            
                                .resizable()
                                .scaledToFit()
                                .padding(12)
                                .foregroundColor(.background)
                                .background(
                                    Circle()
                                        .fill(.accent)
                                )
                            
                            
                        }
                        .buttonStyle(.plain)
                        .frame(width: 50, height: 50)
                        Button {
                            Task{
                                await playlistViewModel.addEpisode(episode, to: .end)
                            }
                        } label: {
                            Image(systemName: "text.line.last.and.arrowtriangle.forward")
                                .symbolRenderingMode(.hierarchical)
                            
                                .resizable()
                                .scaledToFit()
                                .padding(12)
                                .foregroundColor(.background)
                                .background(
                                    Circle()
                                        .fill(.accent)
                                )
                            
                            
                            
                        }
                        .buttonStyle(.plain)
                        .frame(width: 50, height: 50)
                        
                        Spacer()
                        
                        Button {
                            Task{
                                await EpisodeActor(modelContainer: modelContext.container).archiveEpisode(episodeID: episode.id)
                            }
                        } label: {
                            Image(systemName: episode.metaData?.isArchived ?? false ? "archivebox.fill" : "archivebox")
                                .symbolRenderingMode(.hierarchical)
                                .resizable()
                                .scaledToFit()
                                .padding(12)
                                .foregroundColor(.background)
                                .background(
                                    Circle()
                                        .fill(.accent)
                                )
                            
                            
                            
                        }
                        .buttonStyle(.plain)
                        .frame(width: 50, height: 50)
                        
                        
                    }
                }
                
                
            }
            .sheet(isPresented: $showDetails) {
                EpisodeDetailView(episode: episode)
                    .padding()
                  
            }
        

    }
    
    private func loadImage() async {
        if let imageURL = episode.imageURL ?? episode.podcast?.coverImageURL {
            if let uiImage = await ImageLoader.shared.loadImage(from: imageURL) {
                await MainActor.run {
                    self.image = Image(uiImage: uiImage)
                }
            }
        }
    }
}

// Add this class to handle image loading
actor ImageLoader {
    static let shared = ImageLoader()
    private var cache = NSCache<NSString, UIImage>()
    
    private init() {}
    
    func loadImage(from url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        
        if let cached = cache.object(forKey: key) {
            return cached
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                cache.setObject(image, forKey: key)
                return image
            }
        } catch {
            print("Error loading image: \(error)")
        }
        return nil
    }
}
