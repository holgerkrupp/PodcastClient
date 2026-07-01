import SwiftUI
import SwiftData
import AVFoundation

struct BookmarkListView: View {
    @Environment(\.modelContext) private var modelContext

    enum Sort: String, CaseIterable, Identifiable {
        case newestFirst, oldestFirst, podcastAZ, titleAZ
        var id: String { rawValue }

        var title: String {
            switch self {
            case .newestFirst: return "Newest First"
            case .oldestFirst: return "Oldest First"
            case .podcastAZ: return "Podcast A–Z"
            case .titleAZ: return "Title A–Z"
            }
        }
    }

    var podcast: Podcast?
    var episode: Episode?

    @Query private var bookmarks: [Bookmark]

    @State private var inlinePlayer: AVPlayer?
    @State private var playingBookmarkID: Marker.ID?
    @State private var isInlinePlaying = false
    @State private var inlinePlaybackEndObserver: NSObjectProtocol?
    @State private var exportingBookmark: Bookmark?

    @State private var searchText = ""
    @AppStorage("BookmarkListSort") private var sortRaw: String = Sort.newestFirst.rawValue
    private var sort: Sort { Sort(rawValue: sortRaw) ?? .newestFirst }

    private let pageSize = 30
    @State private var visibleCount = 30

    init(podcast: Podcast? = nil, episode: Episode? = nil) {
        self.podcast = podcast
        self.episode = episode
        if let episode {
            let episodeID = episode.persistentModelID
           
            _bookmarks = Query(
                filter: #Predicate<Bookmark> { bookmark in
                    bookmark.bookmarkEpisode?.persistentModelID == episodeID
                })
             
            
        } else if let podcast {
            let podcastID = podcast.persistentModelID
            _bookmarks = Query(
                filter: #Predicate<Bookmark> { bookmark in
                    bookmark.bookmarkEpisode?.podcast?.persistentModelID == podcastID
                }
            )
        } else {
            _bookmarks = Query()
        }
    
    }
       
    
    
    private var navigationTitleText: String {
        if let episode = episode {
            return "Bookmarks for \(episode.title)"
        } else if let podcast = podcast {
            return "Bookmarks in \(podcast.title)"
        } else {
            return "All Bookmarks"
        }
    }

    private var filteredSortedBookmarks: [Bookmark] {
        var result = bookmarks
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { marker in
                marker.title.localizedCaseInsensitiveContains(query)
                || (marker.bookmarkEpisode?.title.localizedCaseInsensitiveContains(query) ?? false)
                || (marker.bookmarkEpisode?.displayPodcastTitle?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }

        switch sort {
        case .newestFirst:
            result.sort { ($0.creationtime ?? .distantPast) > ($1.creationtime ?? .distantPast) }
        case .oldestFirst:
            result.sort { ($0.creationtime ?? .distantPast) < ($1.creationtime ?? .distantPast) }
        case .podcastAZ:
            result.sort {
                let lhs = $0.bookmarkEpisode?.displayPodcastTitle ?? ""
                let rhs = $1.bookmarkEpisode?.displayPodcastTitle ?? ""
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        case .titleAZ:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }

        return result
    }

    private var visibleBookmarks: [Bookmark] {
        Array(filteredSortedBookmarks.prefix(visibleCount))
    }

    var body: some View {
        Group {
            if bookmarks.isEmpty {
                BookmarkEmptyView()
            } else {
                List(visibleBookmarks, id: \.id) { marker in
                    BookmarkRowView(
                        marker: marker,
                        isPlaying: isPlayingInline(marker),
                        clipDisabled: marker.bookmarkEpisode.flatMap(resolvedAudioURL) == nil,
                        onPlayToggle: {
                            guard let episode = marker.bookmarkEpisode else { return }
                            toggleInlinePlayback(of: marker, episode: episode)
                        },
                        onClip: {
                            stopInlinePlayback()
                            exportingBookmark = marker
                        },
                        onLoad: {
                            guard let episode = marker.bookmarkEpisode else { return }
                            stopInlinePlayback()
                            Task {
                                await Player.shared.playEpisode(episode.url, playDirectly: true, startingAt: marker.start)
                            }
                        }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 0,
                                         trailing: 0))
                    .onAppear {
                        loadMoreIfNeeded(currentItem: marker)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .none) {
                            Task { @MainActor in
                                await deleteMarker(marker)
                            }
                        } label: {
                            Label("Delete Bookmark", systemImage: "bookmark.slash.fill")
                        }
                    }
                }
                .listStyle(.plain)
                .navigationTitle(navigationTitleText)
                .searchable(text: $searchText, prompt: "Search bookmarks")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker("Sort", selection: $sortRaw) {
                                ForEach(Sort.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .accessibilityLabel("Sort bookmarks")
                    }
                }
                .onChange(of: searchText) { _, _ in
                    visibleCount = pageSize
                }
                .onChange(of: sortRaw) { _, _ in
                    visibleCount = pageSize
                }
            }
        }
        .onDisappear {
            stopInlinePlayback()
        }
        .sheet(item: $exportingBookmark) { bookmark in
            if let episode = bookmark.bookmarkEpisode,
               let audioURL = resolvedAudioURL(for: episode) {
                AudioClipExportView(
                    title: episode.title,
                    audioURL: audioURL,
                    isVideo: episode.isVideo,
                    coverImageURL: episode.imageURL,
                    fallbackCoverImageURL: episode.podcast?.imageURL,
                    playPosition: bookmark.start ?? 0,
                    duration: episode.duration ?? 60
                )
            }
        }
    }

    private func loadMoreIfNeeded(currentItem: Bookmark) {
        guard currentItem.id == visibleBookmarks.last?.id else { return }
        guard visibleCount < filteredSortedBookmarks.count else { return }
        visibleCount = min(visibleCount + pageSize, filteredSortedBookmarks.count)
    }

    private func deleteMarker(_ marker: Marker) async {
        // print("archiveEpisode from PlaylistView - \(episode.title)")
        guard let id = marker.uuid else { return }
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        await episodeActor.deleteMarker(markerID: id)

    }

    private func isPlayingInline(_ marker: Marker) -> Bool {
        playingBookmarkID == marker.id && isInlinePlaying
    }

    private func toggleInlinePlayback(of marker: Marker, episode: Episode) {
        if playingBookmarkID == marker.id, let inlinePlayer {
            if isInlinePlaying {
                inlinePlayer.pause()
                isInlinePlaying = false
            } else {
                inlinePlayer.play()
                isInlinePlaying = true
            }
            return
        }

        guard let audioURL = resolvedAudioURL(for: episode) else { return }
        stopInlinePlayback()

        let player = AVPlayer(url: audioURL)
        player.seek(to: CMTime(seconds: marker.start ?? 0, preferredTimescale: 600))
        player.play()
        inlinePlayer = player
        playingBookmarkID = marker.id
        isInlinePlaying = true

        inlinePlaybackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in
                stopInlinePlayback()
            }
        }
    }

    private func stopInlinePlayback() {
        inlinePlayer?.pause()
        inlinePlayer = nil
        playingBookmarkID = nil
        isInlinePlaying = false
        if let inlinePlaybackEndObserver {
            NotificationCenter.default.removeObserver(inlinePlaybackEndObserver)
        }
        inlinePlaybackEndObserver = nil
    }

    private func resolvedAudioURL(for episode: Episode) -> URL? {
        if episode.metaData?.calculatedIsAvailableLocally == true,
           let localFile = episode.localFile,
           FileManager.default.fileExists(atPath: localFile.path) {
            return localFile
        }
        return episode.url
    }
}
