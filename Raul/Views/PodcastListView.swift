import SwiftUI
import SwiftData

struct PodcastListView: View {
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]
    @StateObject private var viewModel: PodcastListViewModel
    @Environment(\.modelContext) private var modelContext
    
    init(modelContainer: ModelContainer) {
        _viewModel = StateObject(wrappedValue: PodcastListViewModel(modelContainer: modelContainer))
    }
    
    var body: some View {
        NavigationView {
            if podcasts.isEmpty {
                PodcastsEmptyView()
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
                            NavigationLink(destination: AddPodcastView().modelContext(modelContext)) {
                                Image(systemName: "plus")
                            }
                        
                        }
                    }
            }else{
                List {
                    ForEach(podcasts) { podcast in
                        PodcastRowView(podcast: podcast)
                    }
                    .onDelete { indexSet in
                        Task {
                            for index in indexSet {
                                await viewModel.deletePodcast(podcasts[index])
                            }
                        }
                    }
                }
                .refreshable {
                    Task{
                        await viewModel.refreshPodcasts()
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
                            if viewModel.isLoading {
                                ProgressView()
                            }else{
                                Image(systemName: "arrow.clockwise")
                            }
                            
                        }
                        .disabled(viewModel.isLoading)
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        NavigationLink(destination: AddPodcastView().modelContext(modelContext)) {
                            Image(systemName: "plus")
                        }
                    
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
        }

    }
}

struct PodcastRowView: View {
    let podcast: Podcast
    
    var body: some View {
        NavigationLink(destination: InboxView(podcast: podcast)) {
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
                    if let lastRefreshDate = podcast.metaData?.lastRefresh {
                        Text("Last refresh: \(lastRefreshDate.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
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


