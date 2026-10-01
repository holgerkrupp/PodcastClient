//
//  URLextension.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.01.24.
//

import Foundation

extension URL {
    /// Returns URL user-info in the form required by HTTP Basic auth. URL
    /// parsing may leave percent escapes in the password, so credentials must
    /// be decoded before they are stored or encoded into an Authorization
    /// header.
    var podcastBasicCredential: (username: String, password: String) {
        (
            user?.removingPercentEncoding ?? user ?? "",
            password?.removingPercentEncoding ?? password ?? ""
        )
    }
}

struct URLstatus: Sendable {
    var statusCode: Int?
    var newURL: URL?
    var lastModified:Date?
    var lastRequest:Date
    var doctype:String?

    var isDeadFeedResponse: Bool {
        guard let statusCode else { return false }
        return statusCode == 404 || statusCode == 410 || statusCode == 451 || statusCode >= 500
    }

    var displayMessage: String {
        guard let statusCode else {
            return "Could not check feed"
        }

        switch statusCode {
        case 404:
            return "Feed not found (404)"
        case 410:
            return "Feed gone (410)"
        case 451:
            return "Feed unavailable (451)"
        case 500...599:
            return "Server error (\(statusCode))"
        default:
            return "HTTP \(statusCode)"
        }
    }
}

extension URLRequest {
    private static var podcastFeedUserAgent: String {
        #if os(iOS)
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        #elseif os(macOS)
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        #else
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        #endif
    }

    /// Creates a feed request and carries credentials embedded in the URL as
    /// an HTTP Basic Authorization header. URLSession does not consistently
    /// reuse URL user-info across redirects or subsequent requests, so feed
    /// clients must make this explicit.
    init(podcastFeedURL url: URL) {
        self.init(url: url)
        cachePolicy = .reloadIgnoringLocalCacheData
        setValue(Self.podcastFeedUserAgent, forHTTPHeaderField: "User-Agent")
        setValue(
            "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        guard url.user != nil || url.password != nil else { return }
        let credential = url.podcastBasicCredential
        let credentials = Data("\(credential.username):\(credential.password)".utf8)
            .base64EncodedString()
        setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
    }
}


extension URL{
    /// Private feeds commonly carry their access token in the query, while
    /// HTTP Basic feeds carry it in URL user-info. Keep those components when
    /// a feed publishes a canonical URL without them.
    func preservingFeedAccessComponents(from sourceURL: URL?) -> URL {
        guard let sourceURL,
              hasSameFeedOrigin(as: sourceURL),
              var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let sourceComponents = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        else {
            return self
        }

        if components.user == nil {
            components.user = sourceComponents.user
        }
        if components.password == nil {
            components.password = sourceComponents.password
        }

        let sourceQueryItems = sourceComponents.queryItems ?? []
        if sourceQueryItems.isEmpty == false {
            var queryItems = components.queryItems ?? []
            for sourceItem in sourceQueryItems {
                let alreadyPresent = queryItems.contains {
                    $0.name == sourceItem.name && $0.value == sourceItem.value
                }
                if alreadyPresent == false {
                    queryItems.append(sourceItem)
                }
            }
            components.queryItems = queryItems
        }

        return components.url ?? self
    }

    private func hasSameFeedOrigin(as otherURL: URL) -> Bool {
        let destinationScheme = scheme?.lowercased()
        let sourceScheme = otherURL.scheme?.lowercased()
        guard ["http", "https"].contains(destinationScheme),
              ["http", "https"].contains(sourceScheme),
              host?.lowercased() == otherURL.host?.lowercased() else {
            return false
        }

        if destinationScheme != sourceScheme {
            // Only carry access components across the conventional HTTP to
            // HTTPS upgrade, never across a downgrade or an unrelated port.
            return sourceScheme == "http"
                && destinationScheme == "https"
                && (otherURL.port ?? 80) == 80
                && (port ?? 443) == 443
        }

        let effectivePort: (URL) -> Int? = { url in
            if let port = url.port { return port }
            switch url.scheme?.lowercased() {
            case "http": return 80
            case "https": return 443
            default: return nil
            }
        }

        return effectivePort(self) == effectivePort(otherURL)
    }

    var podcastFeedComparisonKeys: Set<String> {
        var keys = Set<String>()
        let absolute = absoluteURL

        keys.insert(absolute.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if let decoded = absolute.absoluteString.removingPercentEncoding {
            keys.insert(decoded.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }

        guard var components = URLComponents(url: absolute, resolvingAgainstBaseURL: false) else {
            return keys
        }

        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        if components.scheme == "http", components.port == 80 {
            components.port = nil
        } else if components.scheme == "https", components.port == 443 {
            components.port = nil
        }

        let path = components.percentEncodedPath
        if path.count > 1, path.hasSuffix("/") {
            components.percentEncodedPath = String(path.dropLast())
        }

        // HTTP Basic credentials are intentionally removed from the stored
        // podcast identity. Include the credential-free form in comparison
        // keys so legacy `user:password@host` records match their migrated
        // safe URL instead of creating a duplicate subscription.
        if components.user != nil || components.password != nil {
            var credentialFree = components
            credentialFree.user = nil
            credentialFree.password = nil
            addComparisonKeys(from: credentialFree, to: &keys)
            addSchemeVariants(from: credentialFree, to: &keys)
        }

        addComparisonKeys(from: components, to: &keys)
        addSchemeVariants(from: components, to: &keys)

        if components.queryItems?.isEmpty == false {
            var queryless = components
            queryless.query = nil
            addComparisonKeys(from: queryless, to: &keys)
            addSchemeVariants(from: queryless, to: &keys)

            if queryless.user != nil || queryless.password != nil {
                queryless.user = nil
                queryless.password = nil
                addComparisonKeys(from: queryless, to: &keys)
                addSchemeVariants(from: queryless, to: &keys)
            }
        }

        if components.host?.hasPrefix("www.") == true {
            var hostlessWWW = components
            hostlessWWW.host = String(components.host?.dropFirst(4) ?? "")
            addComparisonKeys(from: hostlessWWW, to: &keys)
            addSchemeVariants(from: hostlessWWW, to: &keys)
        }

        return keys
    }

    var podcastWebComparisonKeys: Set<String> {
        var keys = Set<String>()
        guard var components = URLComponents(url: absoluteURL, resolvingAgainstBaseURL: false) else {
            return keys
        }

        components.fragment = nil
        components.query = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        if components.scheme == "http", components.port == 80 {
            components.port = nil
        } else if components.scheme == "https", components.port == 443 {
            components.port = nil
        }

        let path = components.percentEncodedPath
        if path.count > 1, path.hasSuffix("/") {
            components.percentEncodedPath = String(path.dropLast())
        }

        addComparisonKeys(from: components, to: &keys)
        addSchemeVariants(from: components, to: &keys)

        if components.host?.hasPrefix("www.") == true {
            var hostlessWWW = components
            hostlessWWW.host = String(components.host?.dropFirst(4) ?? "")
            addComparisonKeys(from: hostlessWWW, to: &keys)
            addSchemeVariants(from: hostlessWWW, to: &keys)
        }

        return keys
    }

    private func addComparisonKeys(from components: URLComponents, to keys: inout Set<String>) {
        guard let string = components.string?.lowercased() else { return }

        keys.insert(string)
        if let decoded = string.removingPercentEncoding {
            keys.insert(decoded)
        }

        if let scheme = components.scheme {
            keys.insert(string.replacingOccurrences(of: "\(scheme)://", with: ""))
        }
    }

    private func addSchemeVariants(from components: URLComponents, to keys: inout Set<String>) {
        guard components.scheme == "http" || components.scheme == "https" else { return }

        var variant = components
        variant.scheme = components.scheme == "http" ? "https" : "http"
        addComparisonKeys(from: variant, to: &keys)
    }

    func matchesPodcastWebURL(_ otherURL: URL?) -> Bool {
        guard let otherURL else { return false }
        return podcastWebComparisonKeys.intersection(otherURL.podcastWebComparisonKeys).isEmpty == false
    }

    func status(profile: PodcastAccessProfile? = nil) async throws -> URLstatus?{
        
        var status = URLstatus(lastRequest: Date())
        


                    var request: URLRequest
                    if let profile {
                        guard let authorizedRequest = try? PodcastAccessResolver().request(
                            for: self,
                            profile: profile
                        ) else {
                            return nil
                        }
                        request = authorizedRequest
                    } else {
                        request = URLRequest(podcastFeedURL: self)
                    }
                    request.cachePolicy = .reloadIgnoringLocalCacheData  // Always fetch from server
                    request.timeoutInterval = 8

                    request.httpMethod = "HEAD"

        do{
                        let (_, response) = try await PodcastHTTPClient.shared.data(for: request, profile: profile)
                        
                        status.statusCode = (response as? HTTPURLResponse)?.statusCode
                        status.doctype = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
                        
                        status.lastModified =  Date.dateFromRFC1123(dateString: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Last-Modified") ?? "")
                        status.newURL = URL(string: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") ?? "")
                        
                    }catch{
                        // print(error)
                        return nil
                    }
       
        return status
        }
    
    
    func downloadData() async -> Data?{
        
        do {
            let request = URLRequest(podcastFeedURL: self)
            let (data, _) = try await PodcastHTTPClient.shared.data(for: request)
            return data
            
        }catch{
            // print(error)
        }
    return nil
    }
       
    func feedData() async -> Data?{
        // print("loading feedData for \(self.absoluteString)")
        let request = URLRequest(podcastFeedURL: self)
        /*
        if let appName = Bundle.main.applicationName{
            request.setValue(appName, forHTTPHeaderField: "User-Agent")
        }
         */
        do{
            let (data, response) = try await PodcastHTTPClient.shared.data(for: request)
            // print("got response for \(self.absoluteString) ")
           
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                return data
            case .none:
                return nil
                
            case .some(_):
                return nil
                
            }
        }catch{
            // print(error)
            return nil
        }
    }
    
}
