import SwiftUI
import Combine
import fyyd_swift

@MainActor
class PodcastSearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [FyydPodcast] = []
    @Published var isLoading = false
    @Published var hotPodcasts: [FyydPodcast] = []
    @Published var languages: [String] = [] {
        didSet {
            setLanguage()
        }
    }
    @Published var singlePodcast: PodcastFeed?
    @Published var searchResults: [PodcastFeed] = []
    
    @Published var selectedLanguage: String? {
        didSet {
            print("did set language: \(selectedLanguage)")
            Task {
                await fyydManager.setLanguage(selectedLanguage ?? "")
                await loadHotPodcasts()
            }
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    private let fyydManager = FyydSearchManager()
    private let iTunesActor = ITunesSearchActor()

    init() {
        $searchText
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] text in
                self?.performSearch()
            }
            .store(in: &cancellables)
        
        Task {
           // await loadHotPodcasts()
            await loadLanguages()
            
        }
    }
    
    func setLanguage(){
        let identifier = Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
        if languages.contains(identifier){
            selectedLanguage = identifier
        }
    }

    func performSearch() {
        singlePodcast = nil
        searchResults.removeAll()
        results.removeAll()
        
        guard !searchText.isEmpty else {
            return
        }
        isLoading = true
        
        
        if searchText.isValidURL, let url = URL(string: searchText) {
            print("valid URL found")
            
            singlePodcast = PodcastFeed(url: url)
     
            isLoading = false
            return
        } else {
            singlePodcast = nil
            
            var fyydFinished = false
            var iTunesFinished = false
            
            // Start fyyd search in its own Task
            Task {
                let podcasts = await fyydManager.searchPodcasts(query: searchText) ?? []
                let fyydPodcasts = podcasts.map(PodcastFeed.init)
                await MainActor.run {
                    self.searchResults = (self.searchResults + fyydPodcasts).uniqued(by: [ { AnyHashable($0.url) } ])
                    self.results = podcasts
                    fyydFinished = true
                     self.isLoading = false
                }
            }

            // Start iTunes search in its own Task
            Task {
                let iTunesPodcasts = await iTunesActor.search(for: searchText) ?? []
                await MainActor.run {
                    self.searchResults = (self.searchResults + iTunesPodcasts).uniqued(by: [ { AnyHashable($0.url) } ])
                    iTunesFinished = true
                     self.isLoading = false 
                }
            }
        }
        
        

    }
    
  
    
    func parseURL(feedURL: URL) async throws -> [String:String]{
        let (data, _) = try await URLSession.shared.data(from: feedURL)
        
        let parser = XMLParser(data: data)
        let podcastParser = PodcastParser()
        parser.delegate = podcastParser
        
        let fullPodcast = try await PodcastParser.fetchAllPages(from: feedURL)
        
        var podcastDetails: [String:String] = [:]
        podcastDetails["xmlURL"] = feedURL.absoluteString
        podcastDetails["title"] = fullPodcast["title"] as? String ?? ""
        podcastDetails["author"]  = fullPodcast["itunes:author"] as? String
        podcastDetails["desc"]  = fullPodcast["description"] as? String
        podcastDetails["copyright"]  = fullPodcast["copyright"] as? String
        podcastDetails["language"]  = fullPodcast["language"] as? String
        podcastDetails["link"]  = fullPodcast["link"] as? String ?? ""
        podcastDetails["imageURL"] = fullPodcast["coverImage"] as? String
        podcastDetails["lastBuildDate"]  = fullPodcast["lastBuildDate"] as? String ?? ""
        podcastDetails["episodes"] = (fullPodcast["episodes"] as? [[String: Any]])?.count.description ?? ""
        return podcastDetails
    }
    
    func loadLanguages() async {
        if let fetchedLanguages = await fyydManager.getLanguages() {
            await MainActor.run {
                self.languages = fetchedLanguages
            }
        }
    }

    // Fetch hot podcasts
     func loadHotPodcasts() async {
         print("loading hot for language \(selectedLanguage)")
        isLoading = true
        let hotPodcastsList = await fyydManager.getHotPodcasts(lang: selectedLanguage, count: 30)
        await MainActor.run {
            hotPodcasts = hotPodcastsList ?? []
            isLoading = false
        }
    }
}

