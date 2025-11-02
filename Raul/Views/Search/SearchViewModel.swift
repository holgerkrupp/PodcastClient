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
            Task {
                await fyydManager.setLanguage(selectedLanguage ?? "")
                await loadHotPodcasts()
            }
        }
    }
    
    // Basic auth prompt state
    @Published var shouldPromptForBasicAuth: Bool = false
    @Published var pendingURLForAuth: URL? = nil
    @Published var authErrorMessage: String? = nil
    
    private var cancellables = Set<AnyCancellable>()
    private let fyydManager = FyydSearchManager()
    private let iTunesActor = ITunesSearchActor()

    init() {
        $searchText
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
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
            urlString = "https://" + urlString
        }
        if urlString.isValidURL, let url = URL(string: urlString) {
            
            Task {
                // Prefer a status-aware check so we can detect 401
                if let status = await urlString.reachabilityStatus(),
                   let code = status.statusCode {
                    print("Status: \(code)")
                    if code == 401 {
                        // Prompt for basic auth
                        self.pendingURLForAuth = url
                        self.shouldPromptForBasicAuth = true
                        self.isLoading = false
                        return
                    } else if (200..<400).contains(code) {
                        self.singlePodcast = PodcastFeed(url: status.finalURL ?? url)
                        self.isLoading = false
                        return
                    } else {
                        // Not reachable or other status code
                        self.isLoading = false
                        return
                    }
                } else if await urlString.isReachableURL() == false {
                    // Fallback check returned false
                    self.isLoading = false
                    return
                }
                
                if let feedURL = await resolvePodcastFeedURL(from: url) {
                    self.singlePodcast = PodcastFeed(url: feedURL)
                } else {
                    self.singlePodcast = PodcastFeed(url: url) // fallback (might be website)
                }
                self.isLoading = false
            }
        } else {
            singlePodcast = nil
            
            // Start fyyd search in its own Task
            Task {
                let podcasts = await fyydManager.searchPodcasts(query: searchText) ?? []
                let fyydPodcasts = podcasts.map(PodcastFeed.init)
                self.searchResults = (self.searchResults + fyydPodcasts).uniqued(by: [ { AnyHashable($0.url) } ])
                self.results = podcasts.map(PodcastFeed.init)
                self.isLoading = false
            }

            // Start iTunes search in its own Task
            Task {
                let iTunesPodcasts = await iTunesActor.search(for: searchText) ?? []
                self.searchResults = (self.searchResults + iTunesPodcasts).uniqued(by: [ { AnyHashable($0.url) } ])
                self.isLoading = false
            }
        }
    }
    
    /// Accepts credentials, rebuilds URL with user:pass@host, retries, and continues to resolve feed.
    func submitBasicAuth(username: String, password: String) {
        guard let baseURL = pendingURLForAuth else { return }
        isLoading = true
        authErrorMessage = nil
        shouldPromptForBasicAuth = false
        
        Task {
            guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                self.authErrorMessage = "Invalid URL"
                self.isLoading = false
                return
            }
            // Build credentialed URL manually (URLComponents lacks user/password properties in Swift)
            let user = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            let pass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
            
            var hostPart = ""
            if let host = comps.host {
                if let port = comps.port {
                    hostPart = "\(host):\(port)"
                } else {
                    hostPart = host
                }
            }
            let credentialAuthority = "\(user):\(pass)@\(hostPart)"
            let path = comps.percentEncodedPath
            let query = comps.percentEncodedQuery.map { "?\($0)" } ?? ""
            let fragment = comps.percentEncodedFragment.map { "#\($0)" } ?? ""
            let scheme = comps.scheme ?? "https"
            let credentialedString = "\(scheme)://\(credentialAuthority)\(path)\(query)\(fragment)"
            
            guard let credentialedURL = URL(string: credentialedString) else {
                self.authErrorMessage = "Could not build credentialed URL"
                self.isLoading = false
                return
            }
            
            // Retry reachability using HEAD
            let status = try? await credentialedURL.status()
            if let code = status?.statusCode, (200..<400).contains(code) {
                if let feedURL = await self.resolvePodcastFeedURL(from: credentialedURL) {
                    self.singlePodcast = PodcastFeed(url: feedURL)
                } else {
                    self.singlePodcast = PodcastFeed(url: credentialedURL)
                }
                self.isLoading = false
                self.pendingURLForAuth = nil
            } else if let code = status?.statusCode, code == 401 {
                self.authErrorMessage = "Authentication failed. Please check your credentials."
                self.isLoading = false
                // Re-open the sheet to allow retry
                self.shouldPromptForBasicAuth = true
            } else {
                self.authErrorMessage = "Failed to reach URL."
                self.isLoading = false
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
                return url
            }
            if let feedURL = extractFeedURL(fromHTML: text, baseURL: url) {
                return feedURL
            }
        } catch {
            print("Error fetching or analyzing URL: \(url) - \(error)")
        }
        return nil
    }
    
    /// Extract feed URL from HTML meta/link tags.
    private func extractFeedURL(fromHTML html: String, baseURL: URL) -> URL? {
        let pattern = #"<link[^>]+rel=["']alternate["'][^>]+type=["']application/(rss|atom)\+xml["'][^>]+href=["']([^"'>]+)["']"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let nsrange = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, options: [], range: nsrange),
                let hrefRange = Range(match.range(at: 2), in: html) {
                let href = String(html[hrefRange])
                if let absURL = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                    return absURL
                }
            }
        }
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
            self.languages = fetchedLanguages
        }
    }

    // Fetch hot podcasts
     func loadHotPodcasts() async {
        isLoading = true
        let hotPodcastsList = await fyydManager.getHotPodcasts(lang: selectedLanguage, count: 30)
        if let hotPodcastsList{
            let fyydpodcasts: [PodcastFeed] = hotPodcastsList.map(PodcastFeed.init)
            hotPodcasts = fyydpodcasts
        }else{
            hotPodcasts = []
        }
        isLoading = false
    }
}
