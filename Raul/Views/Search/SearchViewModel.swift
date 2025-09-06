import SwiftUI
import Combine
import fyyd_swift

@MainActor
class PodcastSearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [PodcastFeed] = []
    @Published var isLoading = false
    @Published var hotPodcasts: [PodcastFeed] = []
    @Published var languages: [String] = [] {
        didSet {
            setLanguage()
        }
    }
    @Published var singlePodcast: PodcastFeed?
    @Published var searchResults: [PodcastFeed] = []
    
    @Published var selectedLanguage: String? {
        didSet {
            // print("did set language: \(String(describing: selectedLanguage))")
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
        
        var urlString = searchText
        if !urlString.lowercased().hasPrefix("http://") && !urlString.lowercased().hasPrefix("https://") {
            print("No scheme found in URL. Prepending https://")
            urlString = "https://" + urlString
        }
        if urlString.isValidURL, let url = URL(string: urlString) {
            print("Attempting to resolve podcast/feed URL: \(url)")
            Task {
                if await urlString.isReachableURL() {
                    
                    
                    if let feedURL = await resolvePodcastFeedURL(from: url) {
                        print("Feed detected: \(feedURL)")
                        await MainActor.run {
                            self.singlePodcast = PodcastFeed(url: feedURL)
                        }
                    } else {
                        print("No explicit podcast feed found in response. Using entered URL: \(url)")
                        await MainActor.run {
                            self.singlePodcast = PodcastFeed(url: url) // fallback (might be website)
                        }
                    }
                    await MainActor.run { self.isLoading = false }
                }else{
                    print("URL not reachable: \(url)")
                }
                return
            }
            
        } else {
            singlePodcast = nil
            
           // var fyydFinished = false
          //  var iTunesFinished = false
            
            // Start fyyd search in its own Task
            Task {
                let podcasts = await fyydManager.searchPodcasts(query: searchText) ?? []
                let fyydPodcasts = podcasts.map(PodcastFeed.init)
                await MainActor.run {
                    self.searchResults = (self.searchResults + fyydPodcasts).uniqued(by: [ { AnyHashable($0.url) } ])
                    self.results = podcasts.map(PodcastFeed.init)
                //    fyydFinished = true
                     self.isLoading = false
                }
            }

            // Start iTunes search in its own Task
            Task {
                let iTunesPodcasts = await iTunesActor.search(for: searchText) ?? []
                await MainActor.run {
                    self.searchResults = (self.searchResults + iTunesPodcasts).uniqued(by: [ { AnyHashable($0.url) } ])
               //     iTunesFinished = true
                     self.isLoading = false 
                }
            }
        }
        
        
        
    }
    
    /// Try to determine if a URL is an XML podcast feed. If not, try extracting a feed URL from HTML.
    private func resolvePodcastFeedURL(from url: URL) async -> URL? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResp = response as? HTTPURLResponse {
                print("Fetched URL: \(url) [status: \(httpResp.statusCode)]")
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            // Quick heuristic: check if it's XML with <rss> or <feed>
            if text.contains("<rss") || text.contains("<feed") {
                print("XML feed signature detected in body (<rss> or <feed>)")
                return url
            }
            print("No XML root found, attempting to extract feed link from HTML...")
            if let feedURL = extractFeedURL(fromHTML: text, baseURL: url) {
                print("Extracted feed URL from HTML: \(feedURL)")
                return feedURL
            }
            print("No feed link found in HTML.")
        } catch {
            print("Error fetching or analyzing URL: \(url) - \(error)")
        }
        return nil
    }
    
    /// Extract feed URL from HTML meta/link tags.
    private func extractFeedURL(fromHTML html: String, baseURL: URL) -> URL? {
        // Simple regex for <link rel="alternate" type="application/rss+xml" href="...">
        let pattern = #"<link[^>]+rel=["']alternate["'][^>]+type=["']application/(rss|atom)\+xml["'][^>]+href=["']([^"'>]+)["']"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let nsrange = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, options: [], range: nsrange),
                let hrefRange = Range(match.range(at: 2), in: html) {
                let href = String(html[hrefRange])
                if let absURL = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                    print("Found alternate feed in HTML: \(absURL)")
                    return absURL
                }
            }
        }
        print("No alternate feed link found in HTML body.")
        return nil
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
         // print("loading hot for language \(String(describing: selectedLanguage))")
        isLoading = true
        let hotPodcastsList = await fyydManager.getHotPodcasts(lang: selectedLanguage, count: 30)
        await MainActor.run {
            if let hotPodcastsList{
                let fyydpodcasts: [PodcastFeed] = hotPodcastsList.map(PodcastFeed.init)
                hotPodcasts = fyydpodcasts
                
            }else{
                hotPodcasts = []
            }
            isLoading = false
        }
    }
}
