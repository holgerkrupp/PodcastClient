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
    // timecode remains as input to determine the active chapter,
    // but we will NOT key the async task directly off this Double.
    var timecode: Double? = nil

    @State private var loadedImage: Image? = nil
    @State private var lastAppliedKey: String = ""

    var body: some View {
        Group {
            if let loadedImage {
                loadedImage
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Color.accent)
            }
        }
        // Only run the task when the imageKey changes (i.e., at chapter boundaries
        // or when the underlying image source changes), not on every playback tick.
        .task(id: imageKey) {
            await loadImage(for: imageKey)
        }
    }

    // MARK: - Derived Keys

    // Compute the currently active chapter for the given timecode.
    private var activeChapter: Marker? {
        guard let episode = episode else { return nil }
        guard let time = timecode, time > 0 else { return nil }
        let chapters = episode.preferredChapters
        guard !chapters.isEmpty else { return nil }
        return chapters
            .sorted(by: { ($0.start ?? 0) < ($1.start ?? 0) })
            .last(where: { ($0.start ?? 0) <= time })
    }

    // Determine the most appropriate URL to use if no chapter-specific image is available.
    private var fallbackEpisodeOrPodcastURL: URL? {
        if let episode = episode {
            return episode.imageURL ?? episode.podcast?.imageURL
        }
        if let podcast = podcast {
            return podcast.imageURL
        }
        return imageURL
    }

    // Build a stable key that only changes when the selected chapter (or its image source)
    // changes, or when the episode/podcast fallback cover URL changes.
    private var imageKey: String {
        // Prefer chapter image if we have an active chapter
        if let chapter = activeChapter {
            let hasData = (chapter.imageData?.isEmpty == false)
            let chapterURL = chapter.image?.absoluteString ?? ""
            let chapterID = chapter.uuid?.uuidString
            return "chapter:\(chapterID ?? "invalid")|hasData:\(hasData)|url:\(chapterURL)"
        }

        // Otherwise prefer explicit imageURL passed in
        if let explicitURL = imageURL?.absoluteString {
            return "explicit:\(explicitURL)"
        }

        // Or episode/podcast fallback
        if let fallback = fallbackEpisodeOrPodcastURL?.absoluteString {
            return "fallback:\(fallback)"
        }

        // No image source
        return "none"
    }

    // MARK: - Loading

    @MainActor
    private func loadImage(for key: String) async {
        // If the key hasn't changed, avoid redundant work.
        guard key != lastAppliedKey else { return }

        // Resolve and load based on the current key.
        // Keep a local copy to guard against race conditions.
        let currentKey = key

        // 1) Try chapter image (data first, then URL)
        if let chapter = activeChapter {
            // Data first
            if let data = chapter.imageData, !data.isEmpty {
                if let uiImage = UIImage(data: data) {
                    // Only set state if the key is still current
                    if currentKey == imageKey {
                        loadedImage = Image(uiImage: uiImage)
                        lastAppliedKey = currentKey
                    }
                    return
                }
            }
            // URL next
            if let url = chapter.image {
                if let uiImage = await ImageLoaderAndCache.loadUIImage(from: url) {
                    if currentKey == imageKey {
                        loadedImage = Image(uiImage: uiImage)
                        lastAppliedKey = currentKey
                    }
                    return
                }
            }
        }

        // 2) If an explicit imageURL was provided, use it
        if let directURL = imageURL {
            if let uiImage = await ImageLoaderAndCache.loadUIImage(from: directURL) {
                if currentKey == imageKey {
                    loadedImage = Image(uiImage: uiImage)
                    lastAppliedKey = currentKey
                }
                return
            }
        }

        // 3) Fallback to episode or podcast cover
        if let fallback = fallbackEpisodeOrPodcastURL {
            if let uiImage = await ImageLoaderAndCache.loadUIImage(from: fallback) {
                if currentKey == imageKey {
                    loadedImage = Image(uiImage: uiImage)
                    lastAppliedKey = currentKey
                }
                return
            }
        }

        // 4) Nothing found; clear image if the key is still current
        if currentKey == imageKey {
            loadedImage = nil
            lastAppliedKey = currentKey
        }
    }
}
