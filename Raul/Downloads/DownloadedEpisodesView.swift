import SwiftUI
import SwiftData

struct DownloadedEpisodesView: View {
    @Environment(DownloadedFilesManager.self) private var filesManager
    @Environment(\.modelContext) private var modelContext

    // Optional: simple sort toggle
    enum Sort: String, CaseIterable, Identifiable { case newestFirst, titleAZ; var id: String { rawValue } }
    @AppStorage("DownloadedEpisodesSort") private var sortRaw: String = Sort.newestFirst.rawValue
    private var sort: Sort { Sort(rawValue: sortRaw) ?? .newestFirst }

    @Query private var allEpisodes: [Episode]

    private var downloadedEpisodes: [Episode] {
        let ids = Set(filesManager.currentDownloadedEpisodeIDs())
        let filtered = allEpisodes.filter { ids.contains($0.id) }
        switch sort {
        case .newestFirst:
            return filtered.sorted { ($0.publishDate ?? .distantPast) > ($1.publishDate ?? .distantPast) }
        case .titleAZ:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        List {
            if downloadedEpisodes.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Episodes you download will appear here."))
            } else {
                Section {
                    ForEach(downloadedEpisodes, id: \.id) { episode in
                        ZStack {
                            EpisodeRowView(episode: episode)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task{
                                            await deleteEpisode(episode)
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            NavigationLink(destination: EpisodeDetailView(episode: episode)) { EmptyView() }
                                .opacity(0)
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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: Binding(get: { sortRaw }, set: { sortRaw = $0 })) {
                        Text("Newest First").tag(Sort.newestFirst.rawValue)
                        Text("Title A–Z").tag(Sort.titleAZ.rawValue)
                    }
                    Button("Rescan") { filesManager.rescanDownloadedEpisodeIDs() }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .onAppear {
            // Ensure we have the latest snapshot when opening
            filesManager.rescanDownloadedEpisodeIDs()
        }
    }
    


    private func deleteEpisode(_ episode: Episode) async {
        // Attempt to remove the file for this episode using the files manager
        // Adjust the API below to match your DownloadedFilesManager
        if let id = Optional(episode.id) {
            // Try common APIs by convention; comment/uncomment based on availability
            // filesManager.deleteDownloadedEpisodeID(id)
            // filesManager.removeDownloadedEpisode(id: id)
            // filesManager.deleteFile(forEpisodeID: id)
            // If your manager exposes a generic remove by ID, call it here. Otherwise, implement as needed.
           // filesManager.removeDownloadedEpisodeID(id)
            
            let actor = EpisodeActor(modelContainer: modelContext.container)
            await actor.deleteFile(episodeID: id)
            
        }
        // Refresh the snapshot so UI updates
        filesManager.rescanDownloadedEpisodeIDs()
    }
}

#Preview {
    NavigationStack {
        DownloadedEpisodesView()
            .environment(DownloadedFilesManager(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!))
    }
}
