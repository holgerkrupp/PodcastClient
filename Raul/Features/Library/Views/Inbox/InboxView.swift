import SwiftUI
import SwiftData

extension Notification.Name {
    static let inboxDidChange = Notification.Name("inboxDidChange")
}

enum InboxSection: String, CaseIterable, Identifiable {
    case inbox
    case iCloudDrive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox:
            return "Inbox"
        case .iCloudDrive:
            return "Sideloading"
        }
    }
}

struct InboxView: View {
    @State private var selectedSection: InboxSection = .inbox

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inbox section", selection: $selectedSection) {
                ForEach(InboxSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            Group {
                switch selectedSection {
                case .inbox:
                    InboxListView()
                case .iCloudDrive:
                    SideLoadedEpisodesView(modelContainer: ModelContainerManager.shared.container)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct InboxListView: View {

    @State private var episodes: [Episode] = []
    @State private var isClearingInbox = false
    @State private var hasLoaded = false
    @State private var loadGeneration = 0

    @State private var errorMessage: String?
    @Environment(\.modelContext) private var modelContext
    @State private var refreshProgress = PodcastRefreshCoordinator.shared.progress

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if episodes.isEmpty {
                if refreshProgress.isRefreshing {
                    InboxRefreshPlaceholderView(
                        completed: refreshProgress.completed,
                        total: refreshProgress.total
                    )
                } else {
                    InboxEmptyView()
                }
            } else {
                List {
                    ForEach(episodes, id: \.persistentModelID) { episode in
                        ZStack{
                            EpisodeRowView(
                                episode: episode,
                                showsRemoveFromInboxAction: true
                            )
                            NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                                EmptyView()
                            }.opacity(0)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open episode \(episode.title)")
                        .accessibilityHint("Opens this episode details screen")
                        .swipeActions(edge: .trailing){
                            Button(role: .none) {
                                Task { @MainActor in
                                    await removeFromInbox(episode)
                                    await loadEpisodes()
                                }
                            } label: {
                                Label("Remove from Inbox", systemImage: "tray.and.arrow.up.fill")
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await refreshEpisodes()
                    await loadEpisodes()
                }
            }
        }
        .navigationTitle("Inbox")
        .task {
            if !hasLoaded {
                await loadEpisodes()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inboxDidChange)) { _ in
            Task { await loadEpisodes() }
        }
        .onReceive(PodcastRefreshCoordinator.shared.progressPublisher) { progress in
            refreshProgress = progress
        }
        // A screen that was off-screen while the run started may have missed the
        // announcement, so re-read the snapshot every time it comes back.
        .onAppear {
            refreshProgress = PodcastRefreshCoordinator.shared.progress
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    Task {
                        await refreshEpisodes()
                        await loadEpisodes()
                    }
                }) {
                    if refreshProgress.isRefreshing {
                        if refreshProgress.total != 0 {
                            CircularProgressView(
                                value: Double(refreshProgress.completed),
                                total: Double(refreshProgress.total)
                            )
                        } else {
                            ProgressView()
                        }
                    }else{
                        Label("Refresh Inbox", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(refreshProgress.isRefreshing)
                .accessibilityLabel(refreshProgress.isRefreshing ? "Refreshing inbox" : "Refresh inbox")
                .accessibilityHint("Fetches new episodes and reloads your inbox")
                .accessibilityInputLabels([Text("Refresh inbox"), Text("Update inbox")])
            }

            if !episodes.isEmpty {
                ToolbarItem(placement: .secondaryAction) {
                    Button(action: {
                        Task {
                            await clearInbox()
                            await loadEpisodes()
                        }
                    }) {
                        if isClearingInbox {
                            ProgressView()
                        }else{
                            Label("Clear inbox", systemImage: "tray.and.arrow.up")
                        }
                    }
                    .disabled(isClearingInbox)
                    .accessibilityLabel(isClearingInbox ? "Clearing inbox" : "Clear inbox")
                    .accessibilityHint("Removes every episode from the inbox without changing playlists or archive state")
                    .accessibilityInputLabels([Text("Clear inbox"), Text("Remove all inbox episodes")])
                }
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            if let errorMessage = errorMessage {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Data Loading

    private func loadEpisodes() async {
        loadGeneration += 1
        let generation = loadGeneration
        let actor = EpisodeListQueryActor(modelContainer: modelContext.container)

        do {
            let episodeIDs = try await actor.inboxEpisodeIDs()
            guard Task.isCancelled == false, generation == loadGeneration else {
                return
            }
            // A refresh publishes new episodes every second or so. Reassigning an
            // unchanged list would reset the rows the user is currently swiping.
            if episodeIDs != episodes.map(\.persistentModelID) {
                let episodesByID: [PersistentIdentifier: Episode] = modelContext.existingModels(
                    for: episodeIDs
                )
                episodes = episodeIDs.compactMap { episodesByID[$0] }
            }
            hasLoaded = true
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = "Failed to load episodes: \(error.localizedDescription)"
            hasLoaded = true
        }
    }
    
    private func removeFromInbox(_ episode: Episode) async {
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        await episodeActor.removeFromInbox(episode.url)
    }
    
    private func clearInbox() async {
        isClearingInbox = true
        let episodeURLs = episodes.map { $0.url }
        let episodeActor = PodcastModelActor(modelContainer: modelContext.container)
        await episodeActor.removeEpisodesFromInbox(episodeURLs: episodeURLs)
        isClearingInbox = false
    }
    
    private func refreshEpisodes() async {
        errorMessage = nil
        await PodcastRefreshCoordinator.shared.refreshAllPodcasts(
            modelContainer: modelContext.container
        )
        errorMessage = PodcastRefreshCoordinator.shared.progress.errorMessage
    }
}



#Preview {
    NavigationView {
        InboxView()
    }
} 
