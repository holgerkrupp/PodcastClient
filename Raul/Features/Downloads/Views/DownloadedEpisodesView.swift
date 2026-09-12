import SwiftUI
import SwiftData

struct DownloadedEpisodesView: View {
    @Environment(DownloadedFilesManager.self) private var filesManager
    @Environment(\.modelContext) private var modelContext

    // Optional: simple sort toggle
    enum Sort: String, CaseIterable, Identifiable { case newestFirst, titleAZ; var id: String { rawValue } }
    @AppStorage("DownloadedEpisodesSort") private var sortRaw: String = Sort.newestFirst.rawValue
    @State private var downloadedEpisodes: [Episode] = []
    @State private var refreshGeneration = 0
    private var sort: Sort { Sort(rawValue: sortRaw) ?? .newestFirst }

    var body: some View {
        List {
            if downloadedEpisodes.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Episodes you download will appear here."))
            } else {
                Section {
                    ForEach(downloadedEpisodes, id: \.persistentModelID) { episode in
                        ZStack{
                            EpisodeRowView(episode: episode)

                            NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                                EmptyView()
                            }.opacity(0)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open episode \(episode.title)")
                        .accessibilityHint("Opens this episode details screen")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task{
                                    await deleteEpisode(episode.url)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                       // .onDelete(perform: delete)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Picker("Sort", selection: Binding(get: { sortRaw }, set: { sortRaw = $0 })) {
                        Text("Newest First").tag(Sort.newestFirst.rawValue)
                        Text("Title A–Z").tag(Sort.titleAZ.rawValue)
                    }
                    Button("Rescan") {
                        filesManager.rescanDownloadedFiles()
                        Task { await refreshDownloadedEpisodes() }
                    }
                    Button(role: .destructive) {
                        Task { await deletePlayedEpisodes() }
                    } label: {
                        Label("Delete Played", systemImage: "trash.fill")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .accessibilityLabel("Download actions and sort")
                .accessibilityHint("Sort downloads, rescan files, or delete played episodes")
                .accessibilityInputLabels([Text("Download actions"), Text("Download sort")])
            }
        }
        .task {
            await refreshDownloadedEpisodes()
        }
        .onChange(of: sortRaw) { _, _ in
            Task { await refreshDownloadedEpisodes() }
        }
        .onChange(of: filesManager.downloadedFiles) { _, _ in
            Task { await refreshDownloadedEpisodes() }
        }
    }
    
    private func refreshDownloadedEpisodes() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let downloadedFiles = filesManager.downloadedFiles
        guard !downloadedFiles.isEmpty else {
            downloadedEpisodes = []
            return
        }

        let querySort: EpisodeListQuerySort = switch sort {
        case .newestFirst: .newestFirst
        case .titleAZ: .titleAZ
        }
        let actor = EpisodeListQueryActor(modelContainer: modelContext.container)

        do {
            let episodeIDs = try await actor.downloadedEpisodeIDs(
                downloadedFiles: downloadedFiles,
                sort: querySort
            )
            guard Task.isCancelled == false, generation == refreshGeneration else {
                return
            }
            let episodesByID: [PersistentIdentifier: Episode] = modelContext.existingModels(
                for: episodeIDs
            )
            downloadedEpisodes = episodeIDs.compactMap { episodesByID[$0] }
        } catch {
            guard generation == refreshGeneration else { return }
            downloadedEpisodes = []
        }
    }


    private func deleteEpisode(_ episodeURL: URL?, refreshSnapshot: Bool = true) async {
        let actor = EpisodeActor(modelContainer: modelContext.container)
        await actor.deleteFile(episodeURL: episodeURL)

        if refreshSnapshot {
            filesManager.rescanDownloadedFiles()
        }
    }
    
    private func deletePlayedEpisodes() async {
        // Capture IDs on the main actor to avoid sending non-Sendable values into concurrent tasks
        let playedURLs: [URL] = downloadedEpisodes
            .filter { $0.maxPlayProgress == 1 }
            .compactMap(\.url)

        guard !playedURLs.isEmpty else { return }

        let modelContainer = modelContext.container
        await withTaskGroup(of: Void.self) { group in
            for url in playedURLs {
                group.addTask(priority: .background) {
                    await EpisodeActor(modelContainer: modelContainer)
                        .deleteFile(episodeURL: url)
                }
            }
            await group.waitForAll()
        }

        filesManager.rescanDownloadedFiles()
    }
}

#Preview {
    NavigationStack {
        DownloadedEpisodesView()
            .environment(DownloadedFilesManager(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!))
    }
}
