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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DEBUG")
                Image(systemName: episode.metaData?.isArchived ?? false ? "archivebox.fill" : "archivebox")
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

                  
                }
            }

            if isExtended {
                
                EpisodeControlView(episode: episode)
                    .modelContainer(modelContext.container)
                
                Button(action: {
                    Player.shared.playEpisode(episode)
                }) {
                    Image(systemName: "play.circle")
                        .resizable()
                }
                .buttonStyle(.plain)
                .frame(width: 50, height: 50)

          
            }
        }
        .padding(.vertical, 4)
        .onTapGesture {
            withAnimation {
                isExtended.toggle()
            }
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
