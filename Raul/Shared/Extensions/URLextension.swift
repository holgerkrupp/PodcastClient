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

enum PodcastFeedAvailability: Sendable, Equatable {
    case reachable
    case authenticationRequired
    case temporarilyUnavailable
    case definitivelyAbsent
    case headUnsupported
    case unknown
}

struct URLstatus: Sendable {
    var statusCode: Int?
    var newURL: URL?
    var lastModified:Date?
    var lastRequest:Date
    var doctype:String?
    var requestMethod: String = "HEAD"
    var retryAfter: Date?

    var availability: PodcastFeedAvailability {
        guard let statusCode else { return .unknown }
        switch statusCode {
        case 200..<400:
            return .reachable
        case 401, 403:
            return .authenticationRequired
        case 404, 410, 451:
            return .definitivelyAbsent
        case 405 where requestMethod.uppercased() == "HEAD",
             501 where requestMethod.uppercased() == "HEAD":
            return .headUnsupported
        case 429, 500...599:
            return .temporarilyUnavailable
        default:
            return .unknown
        }
    }

    var isDeadFeedResponse: Bool {
        // HEAD is advisory. Even a 404 from HEAD cannot prove that a GET
        // endpoint is absent; only feed validation may make that decision.
        requestMethod.uppercased() != "HEAD" && availability == .definitivelyAbsent
    }

    var displayMessage: String {
        guard let statusCode else {
            return "Could not check feed"
        }

        switch availability {
        case .authenticationRequired:
            return "Feed requires authentication (\(statusCode))"
        case .definitivelyAbsent where statusCode == 404:
            return "Feed not found (404)"
        case .definitivelyAbsent where statusCode == 410:
            return "Feed gone (410)"
        case .definitivelyAbsent where statusCode == 451:
            return "Feed unavailable (451)"
        case .temporarilyUnavailable:
            return statusCode == 429 ? "Feed is rate limited (429)" : "Server error (\(statusCode))"
        case .headUnsupported:
            return "Feed server does not support HEAD"
        case .reachable, .definitivelyAbsent, .unknown:
            return "HTTP \(statusCode)"
        }
    }
}

extension URLRequest {
    private static var podcastFeedUserAgent: String {
        // Some feed hosts serve an HTML reader page to browser user agents.
        // Identify this request as a podcast client so the raw RSS/Atom
        // representation is returned, including after redirects.
        "UpNext/1.0 (+https://github.com/holgerkrupp/PodcastClient)"
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
                let alreadyPresent = queryItems.contains { $0.name == sourceItem.name }
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

    /// Page traversal must retain the query: feeds often publish `?page=2`
    /// on the same path. Subscription identity deliberately has a queryless
    /// alias, which would incorrectly make every continuation look cyclic.
    var podcastPageTraversalKey: String {
        guard var components = URLComponents(url: absoluteURL, resolvingAgainstBaseURL: false) else {
            return absoluteString
        }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.scheme == "http", components.port == 80 {
            components.port = nil
        } else if components.scheme == "https", components.port == 443 {
            components.port = nil
        }
        return components.string ?? absoluteString
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
                        
                        status.statusCode = response.statusCode
                        status.doctype = response.value(forHTTPHeaderField: "Content-Type")
                        
                        status.lastModified =  Date.dateFromRFC1123(dateString: response.value(forHTTPHeaderField: "Last-Modified") ?? "")
                        status.newURL = URL(string: response.value(forHTTPHeaderField: "Location") ?? "")
                        
                    } catch let error as PodcastHTTPError {
                        status.statusCode = error.statusCode
                        status.doctype = nil
                        return status
                    } catch {
                        // A failed HEAD is unknown, not evidence that a feed
                        // which may serve GET is dead.
                        return status
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
           
            switch response.statusCode {
            case 200:
                return data
            default:
                return nil
            }
        }catch{
            // print(error)
            return nil
        }
    }
    
}
