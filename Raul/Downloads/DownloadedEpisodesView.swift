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
                                            await deleteEpisode(episode.id)
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
                    Button(role: .destructive) {
                        Task { await deletePlayedEpisodes() }
                    } label: {
                        Label("Delete Played", systemImage: "trash.fill")
                    }
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
    


    private func deleteEpisode(_ episodeID: UUID) async {
        // Attempt to remove the file for this episode using the files manager
        // Perform heavy work off the main actor to keep UI responsive
       // guard let id = Optional(episode.id) else { return }

        await withTaskCancellationHandler(operation: {
            // Run file deletion in a detached background task
            let _ = await Task.detached(priority: .background) { () -> Void in
                let actor = await EpisodeActor(modelContainer: ModelContainerManager.shared.container)
                await actor.deleteFile(episodeID: episodeID)
            }.value

            // Refresh the snapshot on the main actor so UI updates
            await MainActor.run {
                filesManager.rescanDownloadedEpisodeIDs()
            }
        }, onCancel: {
            // No-op for now; could add cleanup if needed
        })
    }
    
    private func deletePlayedEpisodes() async {
        // Capture IDs on the main actor to avoid sending non-Sendable values into concurrent tasks
        let playedIDs: [UUID] = downloadedEpisodes
            .filter { $0.maxPlayProgress == 1 }
            .map { $0.id }

        guard !playedIDs.isEmpty else { return }

        // Delete concurrently in the background to avoid blocking UI
        await withTaskGroup(of: Void.self) { group in
            for id in playedIDs {
                group.addTask(priority: .background) {
                    await deleteEpisode(id)
                }
            }
            await group.waitForAll()
        }

        // Ensure we refresh once after bulk deletion
        await MainActor.run {
            filesManager.rescanDownloadedEpisodeIDs()
        }
    }
}

#Preview {
    NavigationStack {
        DownloadedEpisodesView()
            .environment(DownloadedFilesManager(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!))
    }
}

