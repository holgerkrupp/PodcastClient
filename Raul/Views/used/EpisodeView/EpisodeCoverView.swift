//
//  EpisodeCoverView.swift
//  Raul
//
//  Created by Holger Krupp on 15.05.25.
//

import SwiftUI
import UIKit

struct CoverImageView: View {
    var episode: Episode? = nil
    var podcast: Podcast? = nil
    var imageURL: URL? = nil
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
        .task(id: taskId) {
            await loadImage()
        }
    }
    
    // Combine relevant parameters to trigger reload on change
    private var taskId: String {
        [
            episode?.id.uuidString ?? "",
            podcast?.id.uuidString ?? "",
            imageURL?.absoluteString ?? "",
            timecode.map { String($0) } ?? ""
        ].joined(separator: "-")
    }
    
    @MainActor
    private func loadImage() async {
        // 1) Load image for episode with chapter/timecode logic
        if let episode = episode {
            if let timecode = timecode,
               timecode > 0,
               episode.preferredChapters.count > 0,
               let chapter = episode.preferredChapters.sorted(by: { ($0.start ?? 0) < ($1.start ?? 0) }).last(where: { ($0.start ?? 0) <= timecode }) {
                
                // Try chapter image data first
                if let imageData = chapter.imageData,
                   let uiImage = UIImage(data: imageData) {
                    loadedImage = Image(uiImage: uiImage)
                    return
                }
                
                // Try chapter image URL second
                if let chapterImageURL = chapter.image {
                    if let uiImage = await ImageLoaderAndCache.loadUIImage(from: chapterImageURL) {
                        loadedImage = Image(uiImage: uiImage)
                        return
                    }
                }
            }
            
            // Fallback to episode or podcast cover URL if exists
            if let episodeCover = episode.imageURL ?? episode.podcast?.imageURL {
                if let uiImage = await ImageLoaderAndCache.loadUIImage(from: episodeCover) {
                    loadedImage = Image(uiImage: uiImage)
                    return
                }
            }
            
            // If no image found for episode, clear
            loadedImage = nil
            return
        }
        
        // 2) Load image from provided direct imageURL
        if let imageURL = imageURL {
            print("loading image from: \(imageURL)")
            if let uiImage = await ImageLoaderAndCache.loadUIImage(from: imageURL) {
                loadedImage = Image(uiImage: uiImage)
                return
            }
            loadedImage = nil
            return
        }
        
        // 3) Load image for podcast if exists
        if let podcast = podcast, let podcastCover = podcast.imageURL {
            if let uiImage = await ImageLoaderAndCache.loadUIImage(from: podcastCover) {
                loadedImage = Image(uiImage: uiImage)
                return
            }
        }
        
        // No image found, clear
        loadedImage = nil
    }
}
