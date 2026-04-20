import SwiftUI
import SwiftData

struct PodcastListView: View {
    enum LibraryScope: String, CaseIterable, Identifiable {
        case subscribed
        case unsubscribed
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .subscribed:
                return "Subscribed"
            case .unsubscribed:
                return "Not Subscribed"
            case .all:
                return "All"
            }
        }
    }

    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Podcast.title) private var podcasts: [Podcast]

    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var selectedPlaylistID: String = ""
    @AppStorage(PlaylistPreferenceKeys.inboxBasePlaylistID) private var inboxBasePlaylistID: String = ""

    @StateObject private var viewModel: PodcastListViewModel
    private let modelContainer: ModelContainer
    @State private var selectedScope: LibraryScope = .subscribed

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        _viewModel = StateObject(wrappedValue: PodcastListViewModel(modelContainer: modelContainer))
    }

    private var podcastsInScope: [Podcast] {
        podcasts.filter { podcast in
            switch selectedScope {
            case .subscribed:
                return podcast.isSubscribed
            case .unsubscribed:
                return podcast.isSubscribed == false
            case .all:
                return true
            }
        }
    }

    var body: some View {
        List {
            NavigationLink(destination: LibrarySearchView()) {
                Label("Search Library", systemImage: "magnifyingglass")
                    .font(.headline)
            }

            NavigationLink(destination: AllEpisodesListView()) {
                Label("All Episodes", systemImage: "rectangle.stack")
                    .font(.headline)
            }

            NavigationLink(destination: AllEpisodesListView().onlyPlayed()) {
                Label("Recently Played Episodes", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
            }

            NavigationLink(destination: DownloadedEpisodesView()) {
                Label("Downloaded Episodes", systemImage: "arrow.down.circle")
                    .font(.headline)
            }

            NavigationLink(destination: SideLoadedEpisodesView(modelContainer: modelContainer)) {
                Label("Side loaded", systemImage: "square.and.arrow.down.on.square")
                    .font(.headline)
            }

            NavigationLink(destination: BookmarkListView()) {
                Label("All Bookmarks", systemImage: "bookmark")
                    .font(.headline)
            }

            NavigationLink(destination: LibraryPlaylistsView()) {
                Label("Playlists", systemImage: "list.bullet")
                    .font(.headline)
            }

            NavigationLink(destination: PlaySessionDebugView()) {
                Label("Listening History", systemImage: "waveform")
                    .font(.headline)
            }

            if podcastsInScope.isEmpty {
                if selectedScope == .subscribed {
                    PodcastsEmptyView()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 16,
                                             leading: 0,
                                             bottom: 16,
                                             trailing: 0))
                } else {
                    ContentUnavailableView(
                        selectedScope == .unsubscribed ? "No Unsubscribed Podcasts" : "No Podcasts",
                        systemImage: selectedScope == .unsubscribed ? "pause.circle" : "dot.radiowaves.left.and.right",
                        description: Text(selectedScope == .unsubscribed ? "Podcasts kept in the database but excluded from refresh will appear here." : "No podcasts are stored in the library yet.")
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 16,
                                         leading: 0,
                                         bottom: 16,
                                         trailing: 0))
                }
            } else {
                ForEach(podcastsInScope) { podcast in
                    ZStack {
                        PodcastRowView(podcast: podcast)
                        NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
                            EmptyView()
                        }.opacity(0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open podcast \(podcast.title)")
                    .accessibilityHint("Opens this podcast details screen")
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 0,
                                         trailing: 0))
                }
                .onDelete { indexSet in
                    Task {
                        for index in indexSet {
                            await viewModel.deletePodcast(podcastsInScope[index])
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .animation(.easeInOut, value: podcastsInScope.map(\.persistentModelID))
        .listStyle(.plain)
        .listRowSpacing(0)
        .task {
            _ = Playlist.ensureDefaultQueue(in: modelContext)
            ensurePlaylistPreferencesValid()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Podcast Scope", selection: $selectedScope) {
                        ForEach(LibraryScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                } label: {
                    Image(systemName: selectedScope == .unsubscribed ? "pause.circle" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Podcast scope")
                .accessibilityHint("Filter library by subscribed, not subscribed, or all podcasts")
                .accessibilityInputLabels([Text("Podcast scope"), Text("Library scope")])
            }

            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: LibrarySearchView()) {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search library")
                .accessibilityHint("Search podcasts, episodes, chapters, and transcripts")
                .accessibilityInputLabels([Text("Search library"), Text("Library search")])
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await viewModel.refreshAllPodcasts() }
                } label: {
                    if viewModel.isLoading {
                        if viewModel.total != 0 {
                            CircularProgressView(
                                value: Double(viewModel.completed),
                                total: Double(viewModel.total)
                            )
                        } else {
                            ProgressView()
                        }
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isLoading)
                .accessibilityLabel(viewModel.isLoading ? "Refreshing podcasts" : "Refresh podcasts")
                .accessibilityHint("Updates all podcast feeds in your library")
                .accessibilityInputLabels([Text("Refresh podcasts"), Text("Refresh library")])
            }
        }
    }

    private func ensurePlaylistPreferencesValid() {
        let defaultPlaylist = Playlist.ensureDefaultQueue(in: modelContext)
        let currentPlaylists = Playlist.manualVisibleSorted((try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? [])
        let allIDs = Set(currentPlaylists.map(\.id))

        if let selectedID = UUID(uuidString: selectedPlaylistID),
           allIDs.contains(selectedID) == false {
            selectedPlaylistID = defaultPlaylist.id.uuidString
        } else if selectedPlaylistID.isEmpty {
            selectedPlaylistID = defaultPlaylist.id.uuidString
        }

        if let inboxID = UUID(uuidString: inboxBasePlaylistID),
           allIDs.contains(inboxID) == false {
            inboxBasePlaylistID = defaultPlaylist.id.uuidString
        } else if inboxBasePlaylistID.isEmpty {
            inboxBasePlaylistID = defaultPlaylist.id.uuidString
        }
    }
}

private struct LibraryPlaylistsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\Playlist.sortIndex, order: .forward), SortDescriptor(\Playlist.title, order: .forward)])
    private var playlists: [Playlist]

    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var selectedPlaylistID: String = ""
    @AppStorage(PlaylistPreferenceKeys.inboxBasePlaylistID) private var inboxBasePlaylistID: String = ""
    @State private var showCreatePlaylistSheet: Bool = false

    private var visiblePlaylists: [Playlist] {
        Playlist.manualVisibleSorted(playlists)
    }

    var body: some View {
        return List {
            if visiblePlaylists.isEmpty {
                ContentUnavailableView(
                    "No playlists yet.",
                    systemImage: "list.bullet.rectangle.portrait"
                )
            } else {
                ForEach(visiblePlaylists) { playlist in
                    playlistRowContent(for: playlist)
                    .deleteDisabled(playlist.deleteable == false)
                }
                .onDelete(perform: deletePlaylists)
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreatePlaylistSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create playlist")
                .accessibilityHint("Adds a new playlist")
            }
        }
        .sheet(isPresented: $showCreatePlaylistSheet) {
            LibraryNewPlaylistSheet { playlistName in
                createPlaylist(named: playlistName)
            }
        }
        .task {
            _ = Playlist.ensureDefaultQueue(in: modelContext)
            ensurePlaylistPreferencesValid()
        }
    }

    private func deletePlaylists(at offsets: IndexSet) {
        let candidates = visiblePlaylists
        let defaultPlaylist = Playlist.ensureDefaultQueue(in: modelContext)

        for index in offsets {
            guard index < candidates.count else { continue }
            let playlist = candidates[index]
            guard playlist.deleteable else { continue }

            if let selectedID = UUID(uuidString: selectedPlaylistID),
               selectedID == playlist.id {
                selectedPlaylistID = defaultPlaylist.id.uuidString
            }

            if let inboxID = UUID(uuidString: inboxBasePlaylistID),
               inboxID == playlist.id {
                inboxBasePlaylistID = defaultPlaylist.id.uuidString
            }

            for entry in playlist.items ?? [] {
                modelContext.delete(entry)
            }
            modelContext.delete(playlist)
        }

        modelContext.saveIfNeeded()
        ensurePlaylistPreferencesValid()
    }

    private func itemCount(for playlist: Playlist) -> Int {
        return playlist.ordered.reduce(into: 0) { partialResult, entry in
            if entry.episode != nil {
                partialResult += 1
            }
        }
    }

    private func ensurePlaylistPreferencesValid() {
        let defaultPlaylist = Playlist.ensureDefaultQueue(in: modelContext)
        let currentPlaylists = Playlist.manualVisibleSorted((try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? [])
        let allIDs = Set(currentPlaylists.map(\.id))

        if let selectedID = UUID(uuidString: selectedPlaylistID),
           allIDs.contains(selectedID) == false {
            selectedPlaylistID = defaultPlaylist.id.uuidString
        } else if selectedPlaylistID.isEmpty {
            selectedPlaylistID = defaultPlaylist.id.uuidString
        }

        if let inboxID = UUID(uuidString: inboxBasePlaylistID),
           allIDs.contains(inboxID) == false {
            inboxBasePlaylistID = defaultPlaylist.id.uuidString
        } else if inboxBasePlaylistID.isEmpty {
            inboxBasePlaylistID = defaultPlaylist.id.uuidString
        }
    }

    private func createPlaylist(named rawName: String) {
        let allPlaylists = Playlist.manualVisibleSorted(playlists)
        let title = Playlist.normalizedPlaylistName(rawName, existing: allPlaylists)

        let playlist = Playlist()
        playlist.title = title
        playlist.deleteable = true
        playlist.hidden = false
        playlist.sortIndex = (allPlaylists.map(\.sortIndex).max() ?? 0) + 1
        playlist.kind = .manual
        playlist.smartFilter = nil

        modelContext.insert(playlist)
        modelContext.saveIfNeeded()
    }

    private func playlistRowContent(for playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            Label(
                playlist.displayTitle,
                systemImage: "list.bullet"
            )
            .font(.headline)

            Spacer()

            Text(itemCount(for: playlist), format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if playlist.deleteable == false {
                Text("Default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LibraryNewPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var playlistName: String = ""

    let onCreate: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist") {
                    TextField("Name", text: $playlistName)
                }
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(playlistName)
                        dismiss()
                    }
                    .disabled(canCreate == false)
                }
            }
        }
    }

    private var canCreate: Bool {
        playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct SideLoadedEpisodesView: View {
    let modelContainer: ModelContainer

    @Query(
        filter: #Predicate<Episode> {
            $0.sourceRawValue == "sideLoaded" && $0.metaData?.isInbox == true
        },
        sort: \Episode.publishDate,
        order: .reverse
    ) private var episodes: [Episode]
    @State private var searchText: String = ""
    @State private var isRefreshing = false

    private var visibleEpisodes: [Episode] {
        episodes.filter { episode in
            guard searchText.isEmpty == false else { return true }

            let searchableText = [
                episode.title,
                episode.subtitle,
                episode.desc,
                episode.author,
                episode.displayPodcastTitle
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

            return searchableText.localizedStandardContains(searchText.lowercased())
        }
    }

    var body: some View {
        Group{
            if visibleEpisodes.isEmpty {
                
                   
                  SideLoadedEmptyStateView(modelContainer: modelContainer)
                    
                
            } else {
                List {
                    ForEach(visibleEpisodes) { episode in
                        ZStack {
                            EpisodeRowView(episode: episode)
                            NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                                EmptyView()
                            }
                            .opacity(0)
                        }
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .listRowSpacing(0)
            }
        }
       
        .navigationTitle("Sideloading")
        .task {
            await refreshSideLoadedContent()
        }
        .refreshable {
            await refreshSideLoadedContent()
        }
        .overlay {
            if isRefreshing {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {
                    Task {
                        await refreshSideLoadedContent()
                    }
                }) {
                    if isRefreshing {
                    
                            ProgressView()
                        
                    }else{
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
                .accessibilityLabel(isRefreshing ? "Refreshing sideloading folder" : "Refresh sideloading folder")
                .accessibilityHint("Fetches reloads your sideloading folder")
                .accessibilityInputLabels([Text("Refresh sideloading"), Text("Update sideloading")])
            }
            
  
        }
    }

    private func refreshSideLoadedContent() async {
        guard isRefreshing == false else { return }
        isRefreshing = true

        defer {
            isRefreshing = false
        }

        await SideloadingCoordinator.shared.refreshNow()
    }
}

private struct SideLoadedEmptyStateView: View {
    let modelContainer: ModelContainer
    @AppStorage(SideloadingConfiguration.enabledKey) private var sideloadingEnabled = false

    private var instructionText: String {
        if sideloadingEnabled {
            return "Place audio files directly in the iCloud Drive > Up Next folder. Open this view to refresh the list, or pull down to scan again after adding new files."
        } else {
            return "Turn on Sideloading in Settings to watch the iCloud Drive > Up Next folder for audio files."
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    Text("Your Sideloading Folder is empty")
                        .font(.headline)

                    Divider()

                    Text(instructionText)
/*
                    Text("Supported formats are MP3, AAC, M4A, M4B, WAV, CAF and AIFF")
                        .font(Font.caption.italic())
*/
                    if sideloadingEnabled == false {
                        NavigationLink {
                            PodcastSettingsView(podcast: nil, modelContainer: modelContainer, embedInNavigationStack: true)
                        } label: {
                            Label("Open Settings", systemImage: "gearshape")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
               
                .padding()
                .frame(minHeight: geometry.size.height, alignment: .leading)
            }
        }
    }
}

#Preview {
    SideLoadedEpisodesView(modelContainer: try! ModelContainer(for: Podcast.self, Episode.self))
}
