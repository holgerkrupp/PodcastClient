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
    @State private var bookmarkError: String?

    @State private var searchText = ""
    @AppStorage("BookmarkListSort") private var sortRaw: String = Sort.newestFirst.rawValue
    private var sort: Sort { Sort(rawValue: sortRaw) ?? .newestFirst }

    private let pageSize = 30
    @State private var visibleCount = 30
    @State private var filteredSortedBookmarks: [BookmarkRowSnapshot] = []

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

    private var visibleBookmarks: [BookmarkRowSnapshot] {
        Array(filteredSortedBookmarks.prefix(visibleCount))
    }

    /// Reads each bookmark's episode relationship once per rebuild; search,
    /// sort and the rows then work on the snapshot values (#498).
    private func buildFilteredSortedBookmarks() -> [BookmarkRowSnapshot] {
        var result = bookmarks.map(BookmarkRowSnapshot.init(bookmark:))
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.matches(query) }
        }
        BookmarkRowSnapshot.sort(&result, by: sort)
        return result
    }

    var body: some View {
        Group {
            if bookmarks.isEmpty {
                BookmarkEmptyView()
            } else {
                List {
                    ForEach(Array(visibleBookmarks.enumerated()), id: \.element.id) { index, snapshot in
                        let marker = snapshot.bookmark
                        BookmarkRowView(
                            marker: marker,
                            snapshot: snapshot,
                            isPlaying: isPlayingInline(marker),
                            // `resolvedAudioURL` falls back to the remote URL,
                            // so Clip only needs an episode URL. No per-row
                            // file-system check (#498).
                            clipDisabled: snapshot.canClip == false,
                            groupPosition: GroupedListRowPosition(index: index, count: visibleBookmarks.count),
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
                            loadMoreIfNeeded(currentItem: snapshot)
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
                }
                .listStyle(.plain)
                .navigationTitle(navigationTitleText)
                .searchable(text: $searchText, prompt: "Search bookmarks")
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) {
                        Menu {
                            Picker("Sort", selection: $sortRaw) {
                                ForEach(Sort.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                        } label: {
                            Label("Sort bookmarks", systemImage: "arrow.up.arrow.down")
                        }
                        .accessibilityLabel("Sort bookmarks")
                    }
                }
                .onChange(of: searchText) { _, _ in
                    visibleCount = pageSize
                    Debounce.shared.perform(key: "BookmarkListView.search") {
                        rebuildFilteredSortedBookmarks()
                    }
                }
                .onChange(of: sortRaw) { _, _ in
                    visibleCount = pageSize
                    rebuildFilteredSortedBookmarks()
                }
                .onChange(of: bookmarks.map(\.persistentModelID)) { _, _ in
                    rebuildFilteredSortedBookmarks()
                }
            }
        }
        .task {
            rebuildFilteredSortedBookmarks()
        }
        .onDisappear {
            stopInlinePlayback()
        }
        .alert("Couldn’t Remove Bookmark", isPresented: Binding(
            get: { bookmarkError != nil },
            set: { if !$0 { bookmarkError = nil } }
        )) {
            Button("OK", role: .cancel) { bookmarkError = nil }
        } message: {
            Text(bookmarkError ?? "")
        }
        .sheet(item: $exportingBookmark) { bookmark in
            if let episode = bookmark.bookmarkEpisode,
               let audioURL = resolvedAudioURL(for: episode) {
                AudioClipExportView(
                    title: episode.title,
                    episodeURL: episode.url,
                    episodeLink: episode.link,
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

    private func loadMoreIfNeeded(currentItem: BookmarkRowSnapshot) {
        guard currentItem.id == visibleBookmarks.last?.id else { return }
        guard visibleCount < filteredSortedBookmarks.count else { return }
        visibleCount = min(visibleCount + pageSize, filteredSortedBookmarks.count)
    }

    private func rebuildFilteredSortedBookmarks() {
        filteredSortedBookmarks = buildFilteredSortedBookmarks()
        visibleCount = min(max(visibleCount, pageSize), max(filteredSortedBookmarks.count, pageSize))
    }

    private func deleteMarker(_ marker: Marker) async {
        // print("archiveEpisode from PlaylistView - \(episode.title)")
        guard let id = marker.uuid else {
            bookmarkError = BookmarkSaveError.deleteFailed.localizedDescription
            return
        }
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        do { try await episodeActor.deleteMarker(markerID: id) }
        catch { bookmarkError = error.localizedDescription }

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

/// Value presentation of one bookmark row. `bookmark` and `episode` are kept
/// for actions and artwork; everything the row, search and sort read is
/// captured once when the list is rebuilt.
struct BookmarkRowSnapshot: Identifiable {
    let bookmark: Bookmark
    let episode: Episode?
    let id: PersistentIdentifier
    let title: String
    let creationTime: Date?
    let episodeTitle: String?
    let podcastTitle: String?
    let artworkURL: URL?
    let canClip: Bool

    init(bookmark: Bookmark) {
        let episode = bookmark.bookmarkEpisode
        self.bookmark = bookmark
        self.episode = episode
        self.id = bookmark.persistentModelID
        self.title = bookmark.title
        self.creationTime = bookmark.creationtime
        self.episodeTitle = episode?.title
        self.podcastTitle = episode?.displayPodcastTitle
        self.artworkURL = episode?.imageURL ?? episode?.podcast?.imageURL
        self.canClip = episode?.url != nil
    }

    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query)
            || (episodeTitle?.localizedCaseInsensitiveContains(query) ?? false)
            || (podcastTitle?.localizedCaseInsensitiveContains(query) ?? false)
    }

    static func sort(_ snapshots: inout [BookmarkRowSnapshot], by sort: BookmarkListView.Sort) {
        switch sort {
        case .newestFirst:
            snapshots.sort { ($0.creationTime ?? .distantPast) > ($1.creationTime ?? .distantPast) }
        case .oldestFirst:
            snapshots.sort { ($0.creationTime ?? .distantPast) < ($1.creationTime ?? .distantPast) }
        case .podcastAZ:
            snapshots.sort {
                ($0.podcastTitle ?? "").localizedCaseInsensitiveCompare($1.podcastTitle ?? "") == .orderedAscending
            }
        case .titleAZ:
            snapshots.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }
}
