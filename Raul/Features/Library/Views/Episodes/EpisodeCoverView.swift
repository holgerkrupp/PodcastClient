//
//  EpisodeCoverView.swift
//  Raul
//
//  Created by Holger Krupp on 15.05.25.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct CoverImageView: View {
    var episode: Episode? = nil
    var podcast: Podcast? = nil
    var imageURL: URL? = nil
    /// A lightweight credential profile supplied by value-only row presenters.
    var accessProfileOverride: PodcastAccessProfile? = nil
    // timecode remains as input to determine the active chapter,
    // but we will NOT key the async task directly off this Double.
    var timecode: Double? = nil
    var maxPixelSize: CGFloat = ImageLoaderAndCache.defaultMaxPixelSize
    var loadDelay: Duration = .zero

    @State private var loadedImage: Image? = nil
    @State private var lastAppliedKey: String = ""
    @State private var retryRevision = 0
    @State private var lastEpisodeIdentity: String?

    var body: some View {
        Group {
            if let loadedImage {
                loadedImage
                    .resizable()
                    .scaledToFit()
            } else if let cachedImage {
                cachedImage
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Color.accent)
            }
        }
        // Only run the task when the imageKey changes (i.e., at chapter boundaries
        // or when the underlying image source changes), not on every playback tick.
        .onReceive(NotificationCenter.default.publisher(for: .artworkConnectivityRecovered)) { _ in
            retryRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .podcastSettingsDidChange)) { _ in
            Task { @MainActor in
                await ArtworkRecoveryCoordinator.shared.resetAuthenticationFailures(profileID: accessProfile?.id)
                retryRevision &+= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .episodeDownloadFinished)) { notification in
            guard let completedURL = notification.userInfo?[EpisodeDownloadNotificationKey.episodeURL] as? URL,
                  completedURL == episode?.url else { return }
            retryRevision &+= 1
        }
        .onChange(of: resolvedEpisodeIdentity) { _, _ in
            loadedImage = nil
            lastAppliedKey = ""
        }
        .task(id: "\(imageKey)|\(retryRevision)", priority: .userInitiated) {
            let key = imageKey
            let episodeIdentity = resolvedEpisodeIdentity
            if let lastEpisodeIdentity, lastEpisodeIdentity != episodeIdentity {
                loadedImage = nil
                lastAppliedKey = ""
            }
            lastEpisodeIdentity = episodeIdentity
            seedFromCacheIfPossible(for: imageKey)
            if lastAppliedKey == imageKey {
                return
            }

            // With no intentional delay, the repository already checks memory,
            // disk, and network in that order. Calling the disk-only API first
            // would repeat every cache miss before an inbox cover can download.
            if loadDelay > .zero {
                if await loadPersistedImage(for: imageKey) {
                    return
                }
                do {
                    try await Task.sleep(for: loadDelay)
                } catch {
                    return
                }
            }
            while !Task.isCancelled, key == imageKey {
                await loadImage(for: key)
                guard key == imageKey, lastAppliedKey != key,
                      let retryURL = preferredRetryURL,
                      let delay = await ArtworkRecoveryCoordinator.shared.retryDelayRemaining(
                          for: SharedImageRepository.recoveryKey(for: retryURL, profileID: accessProfile?.id)
                      ) else { return }
                do {
                    try await Task.sleep(for: .seconds(max(delay, ArtworkRetryPolicy.minimumConnectivityGap)))
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - Derived Keys

    // Compute the currently active chapter for the given timecode.
    private var activeChapter: Marker? {
        guard let episode = episode else { return nil }
        guard let time = timecode, time > 0 else { return nil }
        let chapters = episode.preferredChapters
        guard !chapters.isEmpty else { return nil }
        return chapters.last(where: { ($0.start ?? 0) <= time })
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

    private var resolvedEpisodeIdentity: String {
        episode?.url?.absoluteString
            ?? imageURL?.absoluteString
            ?? episode?.imageURL?.absoluteString
            ?? podcast?.imageURL?.absoluteString
            ?? "none"
    }

    private var accessProfile: PodcastAccessProfile? {
        if let accessProfileOverride {
            return accessProfileOverride
        }
        let sourcePodcast = episode?.podcast ?? podcast
        guard let metadata = sourcePodcast?.metaData,
              let id = metadata.accessProfileID,
              let rawKind = metadata.accessKindRawValue,
              let kind = PodcastAccessKind(rawValue: rawKind),
              let feed = sourcePodcast?.feed else { return nil }
        return PodcastAccessProfile(
            id: id,
            kind: kind,
            resourceURL: feed,
            providerID: metadata.accessProviderID.flatMap(PremiumPodcastProviderID.init(rawValue:))
        )
    }

    private var preferredRetryURL: URL? {
        activeChapter?.image ?? imageURL ?? episode?.imageURL ?? fallbackEpisodeOrPodcastURL
    }

    // Build a stable key that only changes when the selected chapter (or its image source)
    // changes, or when the episode/podcast fallback cover URL changes.
    private var imageKey: String {
        let fallbackSources = [
            imageURL?.absoluteString,
            episode?.imageURL?.absoluteString,
            episode?.podcast?.imageURL?.absoluteString,
            podcast?.imageURL?.absoluteString
        ].compactMap { $0 }.joined(separator: ",")
        let profileKey = accessProfile?.id ?? "public"
        // Prefer chapter image if we have an active chapter
        if let chapter = activeChapter {
            let hasData = (chapter.imageData?.isEmpty == false)
            let chapterURL = chapter.image?.absoluteString ?? ""
            let chapterID = chapter.uuid?.uuidString
            return "chapter:\(chapterID ?? "invalid")|hasData:\(hasData)|url:\(chapterURL)|fallback:\(fallbackSources)|profile:\(profileKey)"
        }
        return "sources:\(fallbackSources)|profile:\(profileKey)"
    }

    private var cachedImage: Image? {
        guard let uiImage = cachedUIImageForCurrentSource() else { return nil }
        return Image(uiImage: uiImage)
    }

    // MARK: - Loading

    @MainActor
    private func seedFromCacheIfPossible(for key: String) {
        guard key != lastAppliedKey else { return }
        for (index, url) in remoteImageCandidates.enumerated() {
            guard let uiImage = cachedUIImage(for: url) else { continue }
            loadedImage = Image(uiImage: uiImage)
            if index == 0 {
                lastAppliedKey = key
            }
            return
        }
    }

    private func cachedUIImageForCurrentSource() -> UIImage? {
        if let chapter = activeChapter {
            if let url = chapter.image,
               let uiImage = cachedUIImage(for: url) {
                return uiImage
            }
        }

        if let directURL = imageURL,
           let uiImage = cachedUIImage(for: directURL) {
            return uiImage
        }

        if let fallbackURL = fallbackEpisodeOrPodcastURL,
           let uiImage = cachedUIImage(for: fallbackURL) {
            return uiImage
        }
        if let podcastURL = podcastFallbackURL,
           let uiImage = cachedUIImage(for: podcastURL) {
            return uiImage
        }

        return nil
    }

    private func cachedUIImage(for url: URL) -> UIImage? {
        // Keep body evaluation cheap. Disk-cache access and image decoding are
        // handled by SharedImageRepository from the asynchronous task below.
        SharedImageRepository.cachedImage(
            for: url,
            maxPixelSize: maxPixelSize,
            profileID: accessProfile?.id
        )
    }

    @MainActor
    private func loadPersistedImage(for key: String) async -> Bool {
        guard key == imageKey, accessProfile == nil else { return false }

        let url: URL?
        if let chapter = activeChapter, chapter.imageData?.isEmpty != false {
            url = chapter.image
        } else if activeChapter != nil {
            return lastAppliedKey == key
        } else {
            url = imageURL ?? fallbackEpisodeOrPodcastURL
        }

        guard let url,
              let uiImage = await ImageLoaderAndCache.loadPersistedUIImage(
                from: url,
                maxPixelSize: maxPixelSize
              ),
              key == imageKey else {
            return false
        }

        loadedImage = Image(uiImage: uiImage)
        lastAppliedKey = key
        return true
    }

    @MainActor
    private func loadImage(for key: String) async {
        // Resolve and load based on the current key.
        // Keep a local copy to guard against race conditions.
        let currentKey = key

        // Chapter data remains the highest priority, followed by chapter URL,
        // episode URL, and podcast artwork. A lower priority success remains
        // visible while a failed preferred source is scheduled for retry.
        if let chapter = activeChapter {
            if let data = chapter.imageData, !data.isEmpty {
                let uiImage = await Task.detached(priority: .userInitiated) {
                    ImageLoaderAndCache.makeUIImage(from: data, maxPixelSize: maxPixelSize)
                }.value
                if let uiImage {
                    if currentKey == imageKey {
                        loadedImage = Image(uiImage: uiImage)
                        lastAppliedKey = currentKey
                    }
                    return
                }
            }
        }

        let candidates = remoteImageCandidates
        for (index, directURL) in candidates.enumerated() {
            if let uiImage = await ImageLoaderAndCache.loadUIImage(
                from: directURL,
                maxPixelSize: maxPixelSize,
                profile: accessProfile
            ) {
                if currentKey == imageKey {
                    loadedImage = Image(uiImage: uiImage)
                    if index == 0 { lastAppliedKey = currentKey }
                }
                return
            }
        }

        // Only use an already completed local media file. This is deliberately
        // below chapter and episode artwork, and it never starts a download.
        if let episode,
           episode.source == .sideLoaded || episode.metaData?.isAvailableLocally == true,
           let localFile = episode.localFile,
           let image = await EmbeddedAudioArtworkService.shared.thumbnail(
               for: localFile,
               maxPixelSize: maxPixelSize
           ),
           currentKey == imageKey {
            loadedImage = Image(uiImage: image)
            // Keep this as a fallback, not as a completed preferred source:
            // the remote candidate continues through the shared retry policy.
        }

        // Keep a previously applied image while a retry is pending.
        if currentKey == imageKey {
            return
        }
    }

    private var podcastFallbackURL: URL? {
        episode?.podcast?.imageURL ?? podcast?.imageURL
    }

    private var remoteImageCandidates: [URL] {
        PlayerArtworkUpdatePolicy.orderedImageURLs(
            chapterURL: activeChapter?.image,
            episodeURL: imageURL ?? episode?.imageURL,
            podcastURL: podcastFallbackURL
        )
    }
}

struct BlurredCoverImageView: View {
    var episode: Episode? = nil
    var podcast: Podcast? = nil
    var imageURL: URL? = nil
    /// A lightweight credential profile supplied by value-only row presenters.
    var accessProfileOverride: PodcastAccessProfile? = nil
    var radius: CGFloat = 8
    var maxPixelSize: CGFloat = ImageLoaderAndCache.defaultMaxPixelSize
    var loadDelay: Duration = .zero

    @State private var loadedImage: Image?
    @State private var lastAppliedKey = ""
    @State private var retryRevision = 0
    @State private var lastEpisodeIdentity: String?

    var body: some View {
        Group {
            if let loadedImage {
                loadedImage
                    .resizable()
            } else if let cachedImage {
                cachedImage
                    .resizable()
            } else {
                Rectangle()
                    .fill(Color.accent)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .artworkConnectivityRecovered)) { _ in
            retryRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .podcastSettingsDidChange)) { _ in
            Task { @MainActor in
                await ArtworkRecoveryCoordinator.shared.resetAuthenticationFailures(profileID: accessProfile?.id)
                retryRevision &+= 1
            }
        }
        .onChange(of: resolvedEpisodeIdentity) { _, _ in
            loadedImage = nil
            lastAppliedKey = ""
        }
        .task(id: "\(imageKey)|\(retryRevision)", priority: .utility) {
            let episodeIdentity = resolvedEpisodeIdentity
            if let lastEpisodeIdentity, lastEpisodeIdentity != episodeIdentity {
                loadedImage = nil
                lastAppliedKey = ""
            }
            lastEpisodeIdentity = episodeIdentity
            seedFromCacheIfPossible(for: imageKey)
            if lastAppliedKey == imageKey {
                return
            }

            if loadDelay > .zero {
                if await loadPersistedImage(for: imageKey) {
                    return
                }
                do {
                    try await Task.sleep(for: loadDelay)
                } catch {
                    return
                }
            }
            while !Task.isCancelled {
                await loadImage(for: imageKey)
                guard lastAppliedKey != imageKey,
                      let resolvedURL,
                      let delay = await ArtworkRecoveryCoordinator.shared.retryDelayRemaining(
                          for: SharedImageRepository.recoveryKey(for: resolvedURL, profileID: accessProfile?.id)
                      ) else { return }
                do {
                    try await Task.sleep(for: .seconds(max(delay, ArtworkRetryPolicy.minimumConnectivityGap)))
                } catch {
                    return
                }
            }
        }
    }

    private var resolvedURL: URL? {
        if let imageURL {
            return imageURL
        }

        if let episode {
            return episode.imageURL ?? episode.podcast?.imageURL
        }

        return podcast?.imageURL
    }

    private var resolvedEpisodeIdentity: String {
        episode?.url?.absoluteString
            ?? imageURL?.absoluteString
            ?? episode?.imageURL?.absoluteString
            ?? podcast?.imageURL?.absoluteString
            ?? "none"
    }

    private var accessProfile: PodcastAccessProfile? {
        if let accessProfileOverride {
            return accessProfileOverride
        }
        let sourcePodcast = episode?.podcast ?? podcast
        guard let metadata = sourcePodcast?.metaData,
              let id = metadata.accessProfileID,
              let rawKind = metadata.accessKindRawValue,
              let kind = PodcastAccessKind(rawValue: rawKind),
              let feed = sourcePodcast?.feed else { return nil }
        return PodcastAccessProfile(
            id: id,
            kind: kind,
            resourceURL: feed,
            providerID: metadata.accessProviderID.flatMap(PremiumPodcastProviderID.init(rawValue:))
        )
    }

    private var imageKey: String {
        guard let resolvedURL else { return "none" }
        return SharedImageRepository.blurredCacheKey(
            for: resolvedURL,
            radius: radius,
            maxPixelSize: maxPixelSize,
            profileID: accessProfile?.id
        )
    }

    private var cachedImage: Image? {
        guard let uiImage = SharedImageRepository.cachedBlurredImage(for: imageKey) else { return nil }
        return Image(uiImage: uiImage)
    }

    @MainActor
    private func seedFromCacheIfPossible(for key: String) {
        guard key != lastAppliedKey else { return }
        guard let uiImage = SharedImageRepository.cachedBlurredImage(for: key) else { return }
        loadedImage = Image(uiImage: uiImage)
        lastAppliedKey = key
    }

    @MainActor
    private func loadPersistedImage(for key: String) async -> Bool {
        guard key == imageKey,
              accessProfile == nil,
              let resolvedURL,
              let uiImage = await ImageLoaderAndCache.loadPersistedBlurredUIImage(
                from: resolvedURL,
                radius: radius,
                maxPixelSize: maxPixelSize
              ),
              key == imageKey else {
            return false
        }

        loadedImage = Image(uiImage: uiImage)
        lastAppliedKey = key
        return true
    }

    @MainActor
    private func loadImage(for key: String) async {
        guard key != lastAppliedKey else { return }
        guard let resolvedURL else {
            loadedImage = nil
            lastAppliedKey = key
            return
        }

        if let uiImage = await ImageLoaderAndCache.loadBlurredUIImage(
            from: resolvedURL,
            radius: radius,
            maxPixelSize: maxPixelSize,
            profile: accessProfile
        ),
           key == imageKey {
            loadedImage = Image(uiImage: uiImage)
            lastAppliedKey = key
        }
    }
}
