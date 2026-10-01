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
    @Published private(set) var isDirectURLInput = false
    @Published private(set) var urlErrorMessage: String?

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
    @Published var shouldPromptForBearerToken: Bool = false
    @Published var pendingURLForAuth: URL? = nil
    @Published var authErrorMessage: String? = nil

    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    private let iTunesActor = ITunesSearchActor()
    private let treatsDirectURLsAsPrivate: Bool

    init(treatsDirectURLsAsPrivate: Bool = false) {
        self.treatsDirectURLsAsPrivate = treatsDirectURLsAsPrivate
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
        searchTask?.cancel()
        searchTask = nil
        singlePodcast = nil
        searchResults.removeAll()
        results.removeAll()
        shouldPromptForBasicAuth = false
        shouldPromptForBearerToken = false
        pendingURLForAuth = nil
        authErrorMessage = nil
        urlErrorMessage = nil

        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSearchText.isEmpty == false else {
            isDirectURLInput = false
            isLoading = false
            return
        }

        isLoading = true

        if let url = PodcastSearchInputRecognizer.url(from: searchText) {
            isDirectURLInput = true
            let searchedText = searchText
            searchTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let resolution: PodcastFeedResolution
                    if self.treatsDirectURLsAsPrivate {
                        resolution = try await PodcastFeedResolver.resolvePrivateURL(url)
                    } else {
                        resolution = try await PodcastFeedResolver.resolve(
                            url: url,
                            allowAuthenticationPrompt: true
                        )
                    }

                    try Task.checkCancellation()
                    guard self.searchText == searchedText else { return }

                    switch resolution {
                    case .podcast(let podcastFeed):
                        self.singlePodcast = podcastFeed
                    case .requiresBasicAuth(let protectedURL):
                        self.pendingURLForAuth = protectedURL
                        self.shouldPromptForBasicAuth = true
                    case .requiresBearerToken(let protectedURL):
                        self.pendingURLForAuth = protectedURL
                        self.shouldPromptForBearerToken = true
                    }
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch PodcastFeedResolverError.authenticationRequired(let protectedURL) {
                    guard self.searchText == searchedText else { return }
                    self.pendingURLForAuth = protectedURL
                    self.shouldPromptForBasicAuth = true
                    self.isLoading = false
                    return
                } catch PodcastFeedResolverError.bearerAuthenticationRequired(let protectedURL) {
                    guard self.searchText == searchedText else { return }
                    self.pendingURLForAuth = protectedURL
                    self.shouldPromptForBearerToken = true
                    self.isLoading = false
                    return
                } catch {
                    guard self.searchText == searchedText else { return }
                    // Keep the URL in the field for correction or retry. The
                    // error is deliberately URL-free because query parameters
                    // on personal feeds can contain credentials.
                    self.urlErrorMessage = Self.userFacingURLFailure(for: error)
                }

                guard self.searchText == searchedText else { return }
                self.isLoading = false
            }
        } else {
            isDirectURLInput = false
            let searchedText = trimmedSearchText
            searchTask = Task { [weak self] in
                guard let self else { return }
                let iTunesPodcasts = await iTunesActor.search(for: searchedText) ?? []
                guard self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == searchedText else {
                    return
                }
                self.searchResults = iTunesPodcasts.uniqued(by: [ { AnyHashable($0.url) } ])
                self.results = self.searchResults
                self.isLoading = false
            }
        }
    }

    func cancelPendingSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    private static func userFacingURLFailure(for error: Error) -> String {
        if let resolverError = error as? PodcastFeedResolverError {
            return resolverError.localizedDescription
        }
        return "Could not load a podcast from this URL."
    }
    
    /// Accepts credentials, rebuilds URL with user:pass@host, retries, and continues to resolve feed.
    func submitBasicAuth(username: String, password: String) {
        guard let baseURL = pendingURLForAuth else { return }
        let searchedText = searchText
        isLoading = true
        authErrorMessage = nil
        shouldPromptForBasicAuth = false
        shouldPromptForBearerToken = false

        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolution = try await PodcastFeedResolver.resolve(
                    url: baseURL,
                    credential: .httpBasic(username: username, password: password)
                )

                guard self.searchText == searchedText else { return }

                switch resolution {
                case .podcast(let podcastFeed):
                    self.singlePodcast = podcastFeed
                    self.isLoading = false
                    self.pendingURLForAuth = nil
                case .requiresBasicAuth:
                    self.authErrorMessage = "Authentication failed. Please check your credentials."
                    self.isLoading = false
                    self.shouldPromptForBasicAuth = true
                case .requiresBearerToken:
                    self.authErrorMessage = "This server requires a bearer token."
                    self.isLoading = false
                    self.shouldPromptForBearerToken = true
                }
            } catch PodcastFeedResolverError.authenticationRequired {
                guard self.searchText == searchedText else { return }
                self.authErrorMessage = "Authentication failed. Please check your credentials."
                self.isLoading = false
                self.shouldPromptForBasicAuth = true
            } catch {
                guard self.searchText == searchedText else { return }
                self.authErrorMessage = "Failed to reach URL."
                self.isLoading = false
            }
        }
    }

    func submitBearerToken(_ token: String) {
        guard let baseURL = pendingURLForAuth else { return }
        let searchedText = searchText
        isLoading = true
        authErrorMessage = nil
        shouldPromptForBearerToken = false
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolution = try await PodcastFeedResolver.resolve(
                    url: baseURL,
                    credential: .bearerToken(token)
                )
                guard self.searchText == searchedText else { return }
                switch resolution {
                case .podcast(let podcastFeed):
                    self.singlePodcast = podcastFeed
                    self.pendingURLForAuth = nil
                    self.isLoading = false
                case .requiresBasicAuth:
                    self.authErrorMessage = "This feed requires HTTP Basic credentials."
                    self.shouldPromptForBasicAuth = true
                    self.isLoading = false
                case .requiresBearerToken:
                    self.authErrorMessage = "Authentication failed. Please check the token."
                    self.shouldPromptForBearerToken = true
                    self.isLoading = false
                }
            } catch {
                guard self.searchText == searchedText else { return }
                self.authErrorMessage = "Authentication failed. Please check the token."
                self.shouldPromptForBearerToken = true
                self.isLoading = false
            }
        }
    }

    
    func parseURL(feedURL: URL) async throws -> [String:String]{
        let page = try await PodcastParser.fetchPage(from: feedURL)
        
        var podcastDetails: [String:String] = [:]
        podcastDetails["xmlURL"] = feedURL.isLikelyPrivatePodcastURL
            ? feedURL.podcastNonSecretURL.absoluteString
            : feedURL.absoluteString
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
