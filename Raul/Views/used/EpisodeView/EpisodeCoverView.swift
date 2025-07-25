//
//  EpisodeCoverView.swift
//  Raul
//
//  Created by Holger Krupp on 15.05.25.
//

import SwiftUI

struct EpisodeCoverView: View {
    var episode: Episode
    var timecode: Double? = nil
    
    @State private var loadedImage: Image? = nil

    var body: some View {
        Group {
            if let loadedImage {
                loadedImage
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Color.accentColor)
                    
            }
        }
        .task(id: timecode) {
            await loadImage()
        }
    }
    
    @MainActor
    private func loadImage() async {
        // print("loading image for \(episode.title) at timestamp \(timecode ?? 0)")
        // Try to get chapter image first
        if let timecode = timecode,
           timecode > 0,
           episode.preferredChapters.count > 0,
           let chapter = episode.preferredChapters.sorted(by: { ($0.start ?? 0) < ($1.start ?? 0) }).last(where: { ($0.start ?? 0) <= timecode }){
            // print("loading chapter for \(chapter.title) at timestamp \(timecode)")
        
           if let imageData = chapter.imageData,
              let uiImage = UIImage(data: imageData) {
               // print("loading image directly from DATA")
               loadedImage = Image(uiImage: uiImage)
               return
           }else if let chapterImageURL = chapter.image{
               // print("loading image from URL \(chapterImageURL)")
               if let uiImage = await ImageLoaderAndCache.loadUIImage(from: chapterImageURL) {
                   // print("awaiting URL image")
                   loadedImage = Image(uiImage: uiImage)
                   return
               }
           }
        }
        // Fallback to episode or podcast cover
        if let episodeCover = episode.imageURL ?? episode.podcast?.imageURL {
            // print("loading episodeCOver from URL \(episodeCover)")
            if let uiImage = await ImageLoaderAndCache.loadUIImage(from: episodeCover) {
                loadedImage = Image(uiImage: uiImage)
                return
            }
        }
        // print("image is nil")
        loadedImage = nil // Or set a default placeholder
    }
}
/*
struct EpisodeCoverView: View {
    
    @Bindable var episode: Episode
    var timecode: Double? = nil
    
    
    
    var body: some View {
        Group {
            
            if let episodeCover = episode.imageURL {
                ImageWithURL(episodeCover)
                    .scaledToFit()
            }else if let podcastCover = episode.podcast?.imageURL {
                ImageWithURL(podcastCover)
                    .scaledToFit()
            }else {
                Image(systemName: "photo")
            }
        }
    }
}
*/

struct PodcastCoverView: View {
    
    @State var podcast: Podcast?
    var body: some View {
        Group {
            if let podcastCover = podcast?.imageURL {
                ImageWithURL(podcastCover)
                    .scaledToFit()
            }else {
                Image(systemName: "photo")
            }
        }
    }
}
