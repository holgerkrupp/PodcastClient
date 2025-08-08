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
    @Published var selectedLanguage: String = "en" {
        didSet {
            Task {
                await fyydManager.setLanguage(selectedLanguage)
                await loadHotPodcasts()
            }
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    private let fyydManager = FyydSearchManager()

    init() {
        $searchText
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] text in
                self?.performSearch()
            }
            .store(in: &cancellables)
        
        Task {
            await loadHotPodcasts()
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
        guard !searchText.isEmpty else {
            results = []
            return
        }
        isLoading = true
        
        
        if searchText.isValidURL {
            print("valid URL found")
            
            singlePodcast = PodcastFeed(url: URL(string: searchText)!)
            results = []
            isLoading = false
            return
        }else{
            singlePodcast = nil
            Task {
                let podcasts = await fyydManager.searchPodcasts(query: searchText) ?? []
                await MainActor.run {
                    results = podcasts
                    isLoading = false
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
    private func loadHotPodcasts() async {
     
        isLoading = true
        let hotPodcastsList = await fyydManager.getHotPodcasts(lang: selectedLanguage, count: 30)
        await MainActor.run {
            hotPodcasts = hotPodcastsList ?? []
            isLoading = false
        }
    }
}
