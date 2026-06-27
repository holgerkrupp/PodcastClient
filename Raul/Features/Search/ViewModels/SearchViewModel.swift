import SwiftUI
import Combine

@MainActor
class PodcastSearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [PodcastFeed] = []
    @Published var isLoading = false
    @Published var hotPodcasts: [PodcastFeed] = []
    @Published var regions: [PodcastRegion] = []
    @Published var singlePodcast: PodcastFeed?
    @Published var searchResults: [PodcastFeed] = []

    @Published var selectedRegion: String? {
        didSet {
            guard selectedRegion != oldValue else { return }
            Task {
                await iTunesActor.setCountry(selectedRegion ?? "us")
                await loadHotPodcasts()
            }
        }
    }

    // Basic auth prompt state
    @Published var shouldPromptForBasicAuth: Bool = false
    @Published var pendingURLForAuth: URL? = nil
    @Published var authErrorMessage: String? = nil

    private var cancellables = Set<AnyCancellable>()
    private let iTunesActor = ITunesSearchActor()

    init() {
        $searchText
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.performSearch()
            }
            .store(in: &cancellables)

        regions = PodcastRegion.all
        selectedRegion = PodcastRegion.defaultRegionCode
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
            let searchedText = searchText
            let fallbackFeed = PodcastFeed(url: url)
            
            Task {
                do {
                    let resolution = try await PodcastFeedResolver.resolve(url: url, allowAuthenticationPrompt: true)

                    guard self.searchText == searchedText else { return }

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
                    guard self.searchText == searchedText else { return }
                    self.singlePodcast = fallbackFeed
                    self.shouldPromptForBasicAuth = false
                    self.pendingURLForAuth = nil
                    self.authErrorMessage = nil
                }

                self.isLoading = false
            }
        } else {
            singlePodcast = nil

            let searchedText = searchText
            Task {
                let iTunesPodcasts = await iTunesActor.search(for: searchedText) ?? []
                guard self.searchText == searchedText else { return }
                self.searchResults = iTunesPodcasts.uniqued(by: [ { AnyHashable($0.url) } ])
                self.results = self.searchResults
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
            guard let comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
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
        let page = try await PodcastParser.fetchPage(from: feedURL)
        
        var podcastDetails: [String:String] = [:]
        podcastDetails["xmlURL"] = feedURL.absoluteString
        podcastDetails["title"] = page.parsedFeed["title"] as? String ?? ""
        podcastDetails["author"]  = page.parsedFeed["itunes:author"] as? String
        podcastDetails["desc"]  = page.parsedFeed["description"] as? String
        podcastDetails["copyright"]  = page.parsedFeed["copyright"] as? String
        podcastDetails["language"]  = page.parsedFeed["language"] as? String
        podcastDetails["link"]  = page.parsedFeed["link"] as? String ?? ""
        podcastDetails["imageURL"] = page.parsedFeed["coverImage"] as? String
        podcastDetails["lastBuildDate"]  = page.parsedFeed["lastBuildDate"] as? String ?? ""
        podcastDetails["episodes"] = page.episodes.count.description
        return podcastDetails
    }
    
    // Fetch the top ("hot") podcasts for the selected region.
    func loadHotPodcasts() async {
        isLoading = true
        hotPodcasts = await iTunesActor.getTopPodcasts(limit: 30)
        isLoading = false
    }
}
