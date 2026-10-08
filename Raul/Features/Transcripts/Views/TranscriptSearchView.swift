import SwiftUI
import SwiftData

struct TranscriptSearchView: View {
    let scope: TranscriptSearchScope
    let title: String
    let emptyDescription: String

    @Environment(\.modelContext) private var modelContext
    @State private var query = ""
    @State private var snapshot: TranscriptSearchSnapshot?
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var expandedEpisodeIDs: Set<String> = []

    init(
        scope: TranscriptSearchScope = .library,
        title: String = "Transcript Search",
        emptyDescription: String = "Search every transcript available on this device."
    ) {
        self.scope = scope
        self.title = title
        self.emptyDescription = emptyDescription
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if trimmedQuery.isEmpty {
                ContentUnavailableView {
                    Label(title, systemImage: "text.magnifyingglass")
                } description: {
                    Text(emptyDescription)
                } actions: {
                    Text("Search stays on this device and opens exact playback timestamps.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if let snapshot, snapshot.groups.isEmpty == false {
                resultsList(snapshot)
            } else if isSearching {
                ProgressView("Searching transcripts…")
            } else if let errorMessage {
                ContentUnavailableView(
                    "Transcript Search Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ContentUnavailableView(
                    "No Transcript Matches",
                    systemImage: "text.magnifyingglass",
                    description: Text("No transcript matches for \"\(trimmedQuery)\".")
                )
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "Search transcripts")
        .onChange(of: query) { _, _ in
            scheduleSearch()
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    @ViewBuilder
    private func resultsList(_ snapshot: TranscriptSearchSnapshot) -> some View {
        List {
            ForEach(snapshot.groups) { podcast in
                Section {
                    ForEach(podcast.episodes) { episode in
                        DisclosureGroup(
                            isExpanded: episodeBinding(for: episode.id),
                            content: {
                                ForEach(episode.passages) { passage in
                                    TranscriptSearchPassageRow(
                                        passage: passage,
                                        query: trimmedQuery
                                    )
                                }
                            },
                            label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(episode.episodeTitle)
                                        .font(.headline)
                                        .lineLimit(2)
                                    HStack(spacing: 8) {
                                        if let publishDate = episode.publishDate {
                                            Text(publishDate.formatted(date: .abbreviated, time: .omitted))
                                        }
                                        Text(episode.passages.count == 1 ? "1 match" : "\(episode.passages.count) matches")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(episode.episodeTitle), \(episode.passages.count) transcript matches")
                            }
                        )
                    }
                } header: {
                    HStack(spacing: 10) {
                        CoverImageView(imageURL: podcast.podcastImageURL)
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(podcast.podcastTitle)
                                .font(.headline)
                            Text("\(podcast.episodes.count) episodes · \(podcast.passageCount) matches")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay(alignment: .bottom) {
            if isSearching {
                ProgressView()
                    .padding(10)
                    .background(.thinMaterial, in: Capsule())
                    .padding()
            }
        }
    }

    private func episodeBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedEpisodeIDs.contains(id) },
            set: { expanded in
                if expanded { expandedEpisodeIDs.insert(id) }
                else { expandedEpisodeIDs.remove(id) }
            }
        )
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let requestedQuery = trimmedQuery
        guard requestedQuery.isEmpty == false else {
            snapshot = nil
            isSearching = false
            errorMessage = nil
            return
        }
        isSearching = true
        let modelContainer = modelContext.container
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard Task.isCancelled == false else { return }
            do {
                let result = try await TranscriptSearchActor(modelContainer: modelContainer).search(
                    TranscriptSearchQuery(text: requestedQuery, scope: scope)
                )
                guard Task.isCancelled == false else { return }
                await MainActor.run {
                    snapshot = result
                    errorMessage = nil
                    isSearching = false
                    expandedEpisodeIDs = Set(result.groups.flatMap { $0.episodes.map(\.id) })
                }
            } catch {
                guard Task.isCancelled == false else { return }
                await MainActor.run {
                    snapshot = nil
                    errorMessage = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }

}

private struct TranscriptSearchPassageRow: View {
    let passage: TranscriptSearchPassage
    let query: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NavigationLink(
                destination: TranscriptSearchEpisodeDestinationView(
                    passage: passage,
                    query: query
                )
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(Duration.seconds(passage.startTime).formatted(.units(width: .abbreviated)))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.accent)
                        if let speaker = passage.speaker, speaker.isEmpty == false {
                            Text(speaker)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    highlightedSnippet
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if let episodeURL = passage.episodeURL {
                Button {
                    let audioTime = TranscriptSynchronizationStore.shared.audioTime(
                        forTranscriptTime: passage.startTime,
                        episodeURL: passage.episodeURL
                    ) ?? passage.startTime
                    Task {
                        await Player.shared.playEpisode(
                            episodeURL,
                            playDirectly: true,
                            startingAt: audioTime
                        )
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: Circle())
                .accessibilityLabel("Play from \(Duration.seconds(passage.startTime).formatted(.units(width: .abbreviated)))")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var highlightedSnippet: Text {
        let parts = passage.snippet.split(separator: "[", omittingEmptySubsequences: false)
        var result = Text("")
        for part in parts {
            let pieces = part.split(separator: "]", maxSplits: 1, omittingEmptySubsequences: false)
            if pieces.count == 2 {
                result = result + Text(String(pieces[0])).bold().underline()
                result = result + Text(String(pieces[1]))
            } else {
                result = result + Text(String(part))
            }
        }
        return result
    }
}

private struct TranscriptSearchEpisodeDestinationView: View {
    let passage: TranscriptSearchPassage
    let query: String
    @Environment(\.modelContext) private var modelContext
    @State private var episode: Episode?

    var body: some View {
        Group {
            if let episode {
                EpisodeDetailView(
                    episode: episode,
                    transcriptSearchNavigation: TranscriptSearchNavigation(
                        episodeID: passage.episodeID,
                        timestamp: passage.startTime,
                        query: query
                    )
                )
            } else {
                ContentUnavailableView(
                    "Episode Unavailable",
                    systemImage: "quote.bubble",
                    description: Text("This transcript is available, but the episode is no longer available in the local library.")
                )
            }
        }
        .task {
            guard let episodeURL = passage.episodeURL else { return }
            episode = try? modelContext.fetch(
                FetchDescriptor<Episode>(predicate: #Predicate { $0.url == episodeURL })
            ).first
        }
    }
}
