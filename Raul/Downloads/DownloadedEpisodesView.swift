import SwiftUI
import SwiftData

struct DownloadedEpisodesView: View {
    @Environment(DownloadedFilesManager.self) private var filesManager
    @Environment(\.modelContext) private var modelContext

    // Optional: simple sort toggle
    enum Sort: String, CaseIterable, Identifiable { case newestFirst, titleAZ; var id: String { rawValue } }
    @AppStorage("DownloadedEpisodesSort") private var sortRaw: String = Sort.newestFirst.rawValue
    @State private var downloadedEpisodes: [Episode] = []
    private var sort: Sort { Sort(rawValue: sortRaw) ?? .newestFirst }

    var body: some View {
        List {
            if downloadedEpisodes.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Episodes you download will appear here."))
            } else {
                Section {
                    ForEach(downloadedEpisodes, id: \.id) { episode in
                        NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                            EpisodeRowView(episode: episode)
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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: Binding(get: { sortRaw }, set: { sortRaw = $0 })) {
                        Text("Newest First").tag(Sort.newestFirst.rawValue)
                        Text("Title A–Z").tag(Sort.titleAZ.rawValue)
                    }
                    Button("Rescan") {
                        filesManager.rescanDownloadedFiles()
                        refreshDownloadedEpisodes()
                    }
                    Button(role: .destructive) {
                        Task { await deletePlayedEpisodes() }
                    } label: {
                        Label("Delete Played", systemImage: "trash.fill")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Download actions and sort")
                .accessibilityHint("Sort downloads, rescan files, or delete played episodes")
                .accessibilityInputLabels([Text("Download actions"), Text("Download sort")])
            }
        }
        .task {
            refreshDownloadedEpisodes()
        }
        .onChange(of: sortRaw) { _, _ in
            refreshDownloadedEpisodes()
        }
        .onChange(of: filesManager.downloadedFiles) { _, _ in
            refreshDownloadedEpisodes()
        }
    }
    
    private func refreshDownloadedEpisodes() {
        let downloadedFiles = filesManager.downloadedFiles
        guard !downloadedFiles.isEmpty else {
            downloadedEpisodes = []
            return
        }

        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.metaData?.isAvailableLocally == true }
        )

        do {
            var episodes = try modelContext.fetch(descriptor).filter { episode in
                guard let localFile = episode.localFile?.standardizedFileURL else { return false }
                return downloadedFiles.contains(localFile)
            }

            switch sort {
            case .newestFirst:
                episodes.sort { ($0.publishDate ?? .distantPast) > ($1.publishDate ?? .distantPast) }
            case .titleAZ:
                episodes.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            }

            downloadedEpisodes = episodes
        } catch {
            downloadedEpisodes = []
        }
    }


    private func deleteEpisode(_ episodeURL: URL?, refreshSnapshot: Bool = true) async {
        // Attempt to remove the file for this episode using the files manager
        // Perform heavy work off the main actor to keep UI responsive
       // guard let url = episode.url else { return }

        await withTaskCancellationHandler(operation: {
            // Run file deletion in a detached background task
            let _ = await Task.detached(priority: .background) { () -> Void in
                let actor = await EpisodeActor(modelContainer: ModelContainerManager.shared.container)
                await actor.deleteFile(episodeURL: episodeURL)
            }.value

            // Refresh the snapshot on the main actor so UI updates
            if refreshSnapshot {
                await MainActor.run {
                    filesManager.rescanDownloadedFiles()
                }
            }
        }, onCancel: {
            // No-op for now; could add cleanup if needed
        })
    }
    
    private func deletePlayedEpisodes() async {
        // Capture IDs on the main actor to avoid sending non-Sendable values into concurrent tasks
        let playedURLs: [URL] = downloadedEpisodes
            .filter { $0.maxPlayProgress == 1 }
            .compactMap(\.url)

        guard !playedURLs.isEmpty else { return }

        // Delete concurrently in the background to avoid blocking UI
        await withTaskGroup(of: Void.self) { group in
            for url in playedURLs {
                group.addTask(priority: .background) {
                    await deleteEpisode(url, refreshSnapshot: false)
                }
            }
            await group.waitForAll()
        }

        // Ensure we refresh once after bulk deletion
        await MainActor.run {
            filesManager.rescanDownloadedFiles()
        }
    }
}

#Preview {
    NavigationStack {
        DownloadedEpisodesView()
            .environment(DownloadedFilesManager(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!))
    }
}
