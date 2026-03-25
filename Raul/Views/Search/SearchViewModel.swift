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
                do {
                    let resolution = try await PodcastFeedResolver.resolve(url: url, allowAuthenticationPrompt: true)

                    switch resolution {
                    case .podcast(let podcastFeed):
                        self.singlePodcast = podcastFeed
                        self.shouldPromptForBasicAuth = false
                        self.pendingURLForAuth = nil
                        self.authErrorMessage = nil
                    case .requiresBasicAuth(let protectedURL):
                        self.pendingURLForAuth = protectedURL
                        self.shouldPromptForBasicAuth = true
                    }
                } catch {
                    self.singlePodcast = nil
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
            
            do {
                let resolution = try await PodcastFeedResolver.resolve(url: credentialedURL)

                switch resolution {
                case .podcast(let podcastFeed):
                    self.singlePodcast = podcastFeed
                    self.isLoading = false
                    self.pendingURLForAuth = nil
                case .requiresBasicAuth:
                    self.authErrorMessage = "Authentication failed. Please check your credentials."
                    self.isLoading = false
                    self.shouldPromptForBasicAuth = true
                }
            } catch PodcastFeedResolverError.authenticationRequired {
                self.authErrorMessage = "Authentication failed. Please check your credentials."
                self.isLoading = false
                self.shouldPromptForBasicAuth = true
            } catch {
                self.authErrorMessage = "Failed to reach URL."
                self.isLoading = false
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
