import SwiftUI
import SwiftData

extension Notification.Name {
    static let inboxDidChange = Notification.Name("inboxDidChange")
}

struct InboxView: View {
 
    @State private var episodes: [Episode] = []
    @State private var isLoading = false
    @State private var isArchiving = false

    @State private var errorMessage: String?
    @Environment(\.modelContext) private var modelContext
    
    init() { }
    
    var body: some View {
        if episodes.isEmpty{
            NavigationStack{
                InboxEmptyView()
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
                            if isLoading {
                                ProgressView()
                            }else{
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(isLoading)
                    }
                }
            }
        }else{
            NavigationStack{
                List {
                    ForEach(episodes) { episode in
                        ZStack {
                            EpisodeRowView(episode: episode)
                                .id(episode.id)
                            NavigationLink(destination: EpisodeDetailView(episode: episode)) {
                                EmptyView()
                            }.opacity(0)
                        }
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
                            if isLoading {
                                ProgressView()
                            }else{
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(isLoading)
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
                    }
                }
            }
            .overlay {
                if isLoading {
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
        await episodeActor.archiveEpisode(episodeID: episode.id)
        // Optional: post here if EpisodeActor doesn’t
        // Task { @MainActor in NotificationCenter.default.post(name: .inboxDidChange, object: nil) }
    }
    
    private func unarchiveEpisode(_ episode: Episode) async {
        let episodeActor = EpisodeActor(modelContainer: modelContext.container)
        await episodeActor.unarchiveEpisode(episodeID: episode.id)
        // Optional: post here if EpisodeActor doesn’t
        // Task { @MainActor in NotificationCenter.default.post(name: .inboxDidChange, object: nil) }
    }
    
    private func archiveAll() async {
        isArchiving = true
        let episodeIDs = episodes.map { $0.id }
        let episodeActor = PodcastModelActor(modelContainer: modelContext.container)
        try? await episodeActor.archiveEpisodes(episodeIDs: episodeIDs)
        isArchiving = false
        // Optional: post here if PodcastModelActor doesn’t
        // Task { @MainActor in NotificationCenter.default.post(name: .inboxDidChange, object: nil) }
    }
    
    private func refreshEpisodes() async {
        await MainActor.run { isLoading = true; errorMessage = nil }
        do {
            let actor = PodcastModelActor(modelContainer: modelContext.container)
            try await actor.refreshAllPodcasts()
        } catch {
            await MainActor.run {
                errorMessage = "Failed to refresh episodes: \(error.localizedDescription)"
            }
        }
        await MainActor.run { isLoading = false }
    }
}



#Preview {
    NavigationView {
        InboxView()
    }
} 
