import SwiftUI
import SwiftData
import UniformTypeIdentifiers

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
        let visiblePodcasts = podcastsInScope

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

            NavigationLink(destination: StatisticsView()) {
                Label("Listening History", systemImage: "waveform")
                    .font(.headline)
            }

            if visiblePodcasts.isEmpty {
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
                ForEach(visiblePodcasts) { podcast in
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
                            await viewModel.deletePodcast(visiblePodcasts[index])
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .animation(.easeInOut, value: visiblePodcasts.map(\.persistentModelID))
        .listStyle(.plain)
        .task {
            _ = Playlist.ensureDefaultQueue(in: modelContext)
            ensurePlaylistPreferencesValid()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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

            ToolbarItem(placement: .primaryAction) {
                NavigationLink(destination: LibrarySearchView()) {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search library")
                .accessibilityHint("Search podcasts, episodes, chapters, and transcripts")
                .accessibilityInputLabels([Text("Search library"), Text("Library search")])
            }

            ToolbarItem(placement: .primaryAction) {
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

    }
}

private struct LibraryPlaylistsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\Playlist.sortIndex, order: .forward), SortDescriptor(\Playlist.title, order: .forward)])
    private var playlists: [Playlist]

    @AppStorage(PlaylistPreferenceKeys.selectedPlaylistID) private var selectedPlaylistID: String = ""
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
            ToolbarItem(placement: .primaryAction) {
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
            LibraryNewPlaylistSheet { draft in
                createPlaylist(from: draft)
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

            for entry in playlist.items ?? [] {
                modelContext.delete(entry)
            }
            StoreSplitPlaylistSyncCoordinator.tombstone(playlistID: playlist.id)
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

    }

    private func createPlaylist(from draft: LibraryPlaylistCreationDraft) {
        let allPlaylists = Playlist.manualVisibleSorted(playlists)
        let title = Playlist.normalizedPlaylistName(draft.name, existing: allPlaylists)

        let playlist = Playlist()
        playlist.title = title
        playlist.deleteable = true
        playlist.hidden = false
        playlist.sortIndex = (allPlaylists.map(\.sortIndex).max() ?? 0) + 1
        playlist.kind = .manual
        playlist.symbolName = Playlist.normalizedSymbolName(draft.symbolName, fallback: Playlist.defaultManualSymbolName)
        playlist.smartFilter = nil

        modelContext.insert(playlist)
        modelContext.saveIfNeeded()
        StoreSplitPlaylistSyncCoordinator.publish(playlist)
    }

    private func playlistRowContent(for playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            Label(
                playlist.displayTitle,
                systemImage: playlist.displaySymbolName
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

    @State private var draft = LibraryPlaylistCreationDraft()

    let onCreate: (LibraryPlaylistCreationDraft) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist") {
                    TextField("Name", text: $draft.name)
                }

                Section("Icon") {
                    LibraryPlaylistSymbolGridPicker(selection: $draft.symbolName)
                }
            }
            .navigationTitle("New Playlist")
            .platformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(draft)
                        dismiss()
                    }
                    .disabled(canCreate == false)
                }
            }
        }
    }

    private var canCreate: Bool {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

private struct LibraryPlaylistCreationDraft {
    var name: String = ""
    var symbolName: String = Playlist.defaultManualSymbolName
}

private struct LibraryPlaylistSymbolGridPicker: View {
    @Binding var selection: String

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 56, maximum: 70), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(Playlist.symbolOptions) { option in
                Button {
                    selection = option.symbolName
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: option.symbolName)
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                        Text(option.title)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selection == option.symbolName ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selection == option.symbolName ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Playlist icon \(option.title)")
                .accessibilityAddTraits(selection == option.symbolName ? .isSelected : [])
            }
        }
    }
}

struct SideLoadedEpisodesView: View {
    let modelContainer: ModelContainer

    @Query(
        filter: #Predicate<Episode> {
            $0.sourceRawValue == "sideLoaded"
        },
        sort: \Episode.publishDate,
        order: .reverse
    ) private var sideLoadedEpisodes: [Episode]
    @State private var folderFileURLs: [URL] = []
    @State private var isImportingFile = false
    @State private var isRefreshing = false
    @State private var importErrorMessage: String?

    private var episodeByURL: [URL: Episode] {
        sideLoadedEpisodes.reduce(into: [:]) { result, episode in
            guard let url = episode.url?.standardizedFileURL else { return }
            if result[url] == nil {
                result[url] = episode
            }
        }
    }

    private var newFileURLs: [URL] {
        folderFileURLs
            .filter { episodeByURL[$0.standardizedFileURL] == nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private var importedEpisodes: [Episode] {
        folderFileURLs
            .compactMap { episodeByURL[$0.standardizedFileURL] }
            .sorted { lhs, rhs in
                switch (lhs.publishDate, rhs.publishDate) {
                case let (lhs?, rhs?):
                    return lhs > rhs
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            }
    }

    private var hasAnyFiles: Bool {
        folderFileURLs.isEmpty == false
    }

    var body: some View {
        NavigationStack {
            Group {
                if hasAnyFiles == false {
                    SideLoadedEmptyStateView(modelContainer: modelContainer)
                } else {
                    List {
                        Section("New Files") {
                            if newFileURLs.isEmpty {
                                Text("No new files.")
                                    .foregroundStyle(.secondary)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                            } else {
                                ForEach(newFileURLs, id: \.standardizedFileURL) { fileURL in
                                    SideLoadedFolderFileRow(fileURL: fileURL)
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                        .listRowInsets(.init(top: 0,
                                                             leading: 0,
                                                             bottom: 0,
                                                             trailing: 0))
                                }
                            }
                        }

                        Section("Already Imported") {
                            if importedEpisodes.isEmpty {
                                Text("No imported files yet.")
                                    .foregroundStyle(.secondary)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                            } else {
                                ForEach(importedEpisodes) { episode in
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
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Sideloading")
            .task {
                await reloadFolderSnapshot()
            }
            .onReceive(NotificationCenter.default.publisher(for: .sideLoadedDidChange)) { _ in
                Task {
                    await reloadFolderSnapshot()
                }
            }
            .refreshable {
                await refreshSideLoadedContent()
                await reloadFolderSnapshot()
            }
            .fileImporter(
                isPresented: $isImportingFile,
                allowedContentTypes: [.audio, .movie]
            ) { result in
                Task {
                    switch result {
                    case .success(let fileURL):
                        await importSideLoadedFile(from: fileURL)
                    case .failure(let error):
                        await MainActor.run {
                            importErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .overlay {
                if isRefreshing {
                    ProgressView()
                }
            }
            .alert("Import Error", isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if $0 == false { importErrorMessage = nil } }
            )) {
                Button("OK") {
                    importErrorMessage = nil
                }
            } message: {
                Text(importErrorMessage ?? "The file could not be imported.")
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button(action: {
                        isImportingFile = true
                    }) {
                        Label("Import File", systemImage: "folder.badge.plus")
                    }
                    .accessibilityLabel("Import sideloading file")
                    .accessibilityHint("Opens a file picker and copies the selected audio file into the sideloading folder")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: {
                        Task {
                            await refreshSideLoadedContent()
                            await reloadFolderSnapshot()
                        }
                    }) {
                        if isRefreshing {
                            ProgressView()
                        } else {
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
    }

    private func reloadFolderSnapshot() async {
        guard let folderURL = SideloadingCoordinator.shared.folderURL else {
            await MainActor.run {
                folderFileURLs = []
            }
            return
        }

        let snapshot = await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .isDirectoryKey
            ]
            let standardizedFolderURL = folderURL.standardizedFileURL
            let folderPath = standardizedFolderURL.path.hasSuffix("/")
                ? standardizedFolderURL.path
                : standardizedFolderURL.path + "/"

            var fileURLs: [URL] = []

            if let enumerator = fileManager.enumerator(
                at: standardizedFolderURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                while let url = enumerator.nextObject() as? URL {
                    let standardizedURL = url.standardizedFileURL
                    guard standardizedURL.path.hasPrefix(folderPath) else { continue }
                    guard isSupportedSideLoadedFile(standardizedURL) else { continue }
                    guard let isRegularFile = try? standardizedURL.resourceValues(forKeys: Set(keys)).isRegularFile,
                          isRegularFile == true else {
                        continue
                    }

                    fileURLs.append(standardizedURL)
                }
            }

            return Array(Set(fileURLs))
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }.value

        await MainActor.run {
            folderFileURLs = snapshot
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

    private func importSideLoadedFile(from selectedURL: URL) async {
        guard let folderURL = SideloadingCoordinator.shared.folderURL else {
            await MainActor.run {
                importErrorMessage = "Enable sideloading in Settings before importing files."
            }
            return
        }

        let didStartAccessing = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }

        let destinationURL = uniqueDestinationURL(
            for: selectedURL,
            in: folderURL.standardizedFileURL
        )

        do {
            if selectedURL.standardizedFileURL != destinationURL {
                try FileManager.default.copyItem(at: selectedURL, to: destinationURL)
            }

            await refreshSideLoadedContent()
            await reloadFolderSnapshot()
        } catch {
            await MainActor.run {
                importErrorMessage = error.localizedDescription
            }
        }
    }

    private func uniqueDestinationURL(for sourceURL: URL, in folderURL: URL) -> URL {
        let fileManager = FileManager.default
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension
        var attempt = 0

        while true {
            let candidateName: String
            if attempt == 0 {
                candidateName = sourceURL.lastPathComponent
            } else if fileExtension.isEmpty {
                candidateName = "\(baseName)-\(attempt)"
            } else {
                candidateName = "\(baseName)-\(attempt).\(fileExtension)"
            }

            let candidateURL = folderURL.appendingPathComponent(candidateName)
            if fileManager.fileExists(atPath: candidateURL.path) == false {
                return candidateURL
            }

            if candidateURL.standardizedFileURL == sourceURL.standardizedFileURL {
                return candidateURL
            }

            attempt += 1
        }
    }
}

private struct SideLoadedFolderFileRow: View {
    let fileURL: URL

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(fileURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)

                Text("Waiting to be imported")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private func isSupportedSideLoadedFile(_ url: URL) -> Bool {
    let extensionName = url.pathExtension.lowercased()
    guard extensionName.isEmpty == false else { return false }

    if SideloadingConfiguration.supportedExtensions.contains(extensionName) {
        return true
    }

    return UTType(filenameExtension: extensionName)?.conforms(to: .audio) == true
}

private struct SideLoadedEmptyStateView: View {
    let modelContainer: ModelContainer
    @Environment(\.openPodcastSettings) private var openSettings
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
                        Button {
                            openSettings()
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
