import SwiftUI
import SwiftData

struct PodcastListView: View {
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]
    @StateObject private var viewModel: PodcastListViewModel
    @Environment(\.modelContext) private var modelContext
    
    @State private var searchText = ""
    @State private var searchInTitle = true
    @State private var searchInAuthor = false
    @State private var searchInDescription = false

    init(modelContainer: ModelContainer) {
        _viewModel = StateObject(wrappedValue: PodcastListViewModel(modelContainer: modelContainer))
    }

    var filteredPodcasts: [Podcast] {
        if searchText.isEmpty { return podcasts }

        return podcasts.filter { podcast in
            let lowercased = searchText.lowercased()

            var matches = false
            if searchInTitle {
                matches = matches || podcast.title.localizedStandardContains(lowercased)
            }
            if searchInAuthor, let author = podcast.author {
                matches = matches || author.localizedStandardContains(lowercased)
            }
            if searchInDescription, let desc = podcast.desc {
                matches = matches || desc.localizedStandardContains(lowercased)
            }
            return matches
        }
    }

    var body: some View {
        NavigationStack {
            VStack {


                if filteredPodcasts.isEmpty {
                    PodcastsEmptyView()
                } else {
                    List {
                        ForEach(filteredPodcasts) { podcast in
                            
                            ZStack {
                                PodcastRowView(podcast: podcast)
                                    .id(podcast.id)
                                    .padding()
                                NavigationLink(destination: PodcastDetailView(podcast: podcast)) {
                                    EmptyView()
                                }.opacity(0)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 0,
                                                 leading: 0,
                                                 bottom: 2,
                                                 trailing: 0))
                        }
                        .onDelete { indexSet in
                            Task {
                                for index in indexSet {
                                    await viewModel.deletePodcast(filteredPodcasts[index])
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await viewModel.refreshPodcasts()
                    }
                }
            }
            .navigationTitle("Podcasts")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink(destination: AddPodcastView().modelContext(modelContext)) {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await viewModel.refreshPodcasts() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                if let message = viewModel.errorMessage {
                    Text(message)
                }
            }
        }
    }
}

struct PodcastRowView: View {
    let podcast: Podcast
    
    var body: some View {
        
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let imageURL = podcast.imageURL {
                        ImageWithURL(imageURL)
                            .frame(width: 50, height: 50)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading) {
                        Text(podcast.title)
                            .font(.headline)
                        
                        if let author = podcast.author {
                            Text(author)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                if let desc = podcast.desc {
                    Text(desc)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundColor(.secondary)
                }
                HStack{
                    if let lastBuildDate = podcast.lastBuildDate {
                        Text("Last updated: \(lastBuildDate.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if let lastRefreshDate = podcast.metaData?.feedUpdateCheckDate {
                        Text("Last checked: \(lastRefreshDate.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        
        .overlay {
            if podcast.metaData?.isUpdating  == true{
                ProgressView()
                    .frame(width: 100, height: 50)
                                          .scaledToFill()
                                          .background(Material.thin)
            }
        }
    }
}

#Preview {
    PodcastListView(modelContainer: try! ModelContainer(for: Podcast.self, Episode.self))
} 


