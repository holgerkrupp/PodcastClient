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
            return "iCloud Drive"
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
                    NavigationStack {
                        SideLoadedEpisodesView(modelContainer: ModelContainerManager.shared.container)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct InboxListView: View {
 
    @State private var episodes: [Episode] = []
    @State private var isArchiving = false

    @State private var errorMessage: String?
    @Environment(\.modelContext) private var modelContext
    @StateObject private var refreshViewModel: PodcastListViewModel
    
    init() {
        _refreshViewModel = StateObject(
            wrappedValue: PodcastListViewModel(modelContainer: ModelContainerManager.shared.container)
        )
    }
    
    var body: some View {
        if episodes.isEmpty{
            NavigationStack{
                InboxEmptyView()
                .navigationTitle("Inbox")
                .task {
                    await loadEpisodes()
                }
                .onReceive(NotificationCenter.default.publisher(for: .inboxDidChange)) { _ in
                    Task { await loadEpisodes() }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            Task {
                                await refreshEpisodes()
                                await loadEpisodes()
                            }
                        }) {
                            if refreshViewModel.isLoading {
                                if refreshViewModel.total != 0 {
                                    CircularProgressView(
                                        value: Double(refreshViewModel.completed),
                                        total: Double(refreshViewModel.total)
                                    )
                                } else {
                                    ProgressView()
                                }
                            }else{
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(refreshViewModel.isLoading)
                        .accessibilityLabel(refreshViewModel.isLoading ? "Refreshing inbox" : "Refresh inbox")
                        .accessibilityHint("Fetches new episodes and reloads your inbox")
                        .accessibilityInputLabels([Text("Refresh inbox"), Text("Update inbox")])
                    }
                }
            }
        }else{
            NavigationStack{
                List {
                    ForEach(episodes) { episode in
                        NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                            EpisodeRowView(episode: episode)
                                .id(episode.url)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open episode \(episode.title)")
                        .accessibilityHint("Opens this episode details screen")
                        .swipeActions(edge: .trailing){
                            Button(role: .none) {
                                Task { @MainActor in
                                    await archiveEpisode(episode)
                                    await loadEpisodes()
                                }
                            } label: {
                                Label("Archive Episode", systemImage: "archivebox.fill")
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
                .navigationTitle("Inbox")
                .task {
                    await loadEpisodes()
                }
                .onReceive(NotificationCenter.default.publisher(for: .inboxDidChange)) { _ in
                    Task { await loadEpisodes() }
                }
                .refreshable {
                    await refreshEpisodes()
                    await loadEpisodes()
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            Task {
                                await refreshEpisodes()
                                await loadEpisodes()
                            }
                        }) {
                            if refreshViewModel.isLoading {
                                if refreshViewModel.total != 0 {
                                    CircularProgressView(
                                        value: Double(refreshViewModel.completed),
                                        total: Double(refreshViewModel.total)
                                    )
                                } else {
                                    ProgressView()
                                }
                            }else{
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(refreshViewModel.isLoading)
                        .accessibilityLabel(refreshViewModel.isLoading ? "Refreshing inbox" : "Refresh inbox")
                        .accessibilityHint("Fetches new episodes and reloads your inbox")
                        .accessibilityInputLabels([Text("Refresh inbox"), Text("Update inbox")])
                    }
                    
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            Task {
                                await archiveAll()
                                await loadEpisodes()
                            }
                        }) {
                            if isArchiving {
                                ProgressView()
                            }else{
                                Image(systemName: "archivebox")
                            }
                        }
                        .disabled(isArchiving)
                        .accessibilityLabel(isArchiving ? "Archiving inbox episodes" : "Archive all inbox episodes")
                        .accessibilityHint("Moves every inbox episode to archive")
                        .accessibilityInputLabels([Text("Archive inbox"), Text("Archive all inbox episodes")])
                    }
                }
            }
            .overlay {
                if refreshViewModel.isLoading && refreshViewModel.total == 0 {
                    ProgressView()
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
    }
    
    // MARK: - Data Loading
    
    private func loadEpisodes() async {
        let predicate = #Predicate<Episode> { $0.metaData?.isInbox == true }
        let sortDescriptor = SortDescriptor<Episode>(\.publishDate, order: .reverse)
        let descriptor = FetchDescriptor<Episode>(predicate: predicate, sortBy: [sortDescriptor])
        do {
            let results = try modelContext.fetch(descriptor)
            await MainActor.run {
                self.episodes = results
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to load episodes: \(error.localizedDescription)"
            }
        }
    }
    
    private func archiveEpisode(_ episode: Episode) async {
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        await episodeActor.archiveEpisode(episode.url)
        // Optional: post here if EpisodeActor doesn’t
        // Task { @MainActor in NotificationCenter.default.post(name: .inboxDidChange, object: nil) }
    }
    
    private func unarchiveEpisode(_ episode: Episode) async {
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        await episodeActor.unarchiveEpisode(episode.url)
        // Optional: post here if EpisodeActor doesn’t
        // Task { @MainActor in NotificationCenter.default.post(name: .inboxDidChange, object: nil) }
    }
    
    private func archiveAll() async {
        isArchiving = true
        let episodeURLs = episodes.map { $0.url }
        let episodeActor = PodcastModelActor(modelContainer: modelContext.container)
        try? await episodeActor.archiveEpisodes(episodeURLs: episodeURLs)
        isArchiving = false
        // Optional: post here if PodcastModelActor doesn’t
        // Task { @MainActor in NotificationCenter.default.post(name: .inboxDidChange, object: nil) }
    }
    
    private func refreshEpisodes() async {
        await MainActor.run { errorMessage = nil }
        await refreshViewModel.refreshAllPodcasts()
        await MainActor.run {
            errorMessage = refreshViewModel.errorMessage
        }
    }
}



#Preview {
    NavigationView {
        InboxView()
    }
} 
