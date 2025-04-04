import SwiftUI
import SwiftData

struct PodcastListView: View {
    @StateObject private var viewModel: PodcastListViewModel
    @Environment(\.modelContext) private var modelContext
    
    init(modelContainer: ModelContainer) {
        _viewModel = StateObject(wrappedValue: PodcastListViewModel(modelContainer: modelContainer))
    }
    
    var body: some View {
        NavigationView {
            List {
                ForEach(viewModel.podcasts) { podcast in
                    PodcastRowView(podcast: podcast)
                }
                .onDelete { indexSet in
                    Task {
                        for index in indexSet {
                            await viewModel.deletePodcast(viewModel.podcasts[index])
                        }
                    }
                }
            }
            .navigationTitle("Podcasts")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        Task {
                            await viewModel.refreshPodcasts()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoading)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink(destination: AddPodcastView()) {
                        Image(systemName: "plus")
                                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView()
                }
            }
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") {
                    viewModel.errorMessage = nil
                }
            } message: {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                }
            }
        }
        .onAppear {
            viewModel.loadPodcasts()
        }
    }
}

struct PodcastRowView: View {
    let podcast: Podcast
    
    var body: some View {
        NavigationLink(destination: EpisodeListView(podcast: podcast)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let imageURL = podcast.coverImageURL {
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
                
                if let lastBuildDate = podcast.lastBuildDate {
                    Text("Last updated: \(lastBuildDate.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

#Preview {
    PodcastListView(modelContainer: try! ModelContainer(for: Podcast.self, Episode.self))
} 
