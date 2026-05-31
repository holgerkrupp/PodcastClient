//
//  URLextension.swift
//  PodcastClient
//
//  Created by Holger Krupp on 06.01.24.
//

import Foundation

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


extension URL{
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

        addComparisonKeys(from: components, to: &keys)
        addSchemeVariants(from: components, to: &keys)

        if components.queryItems?.isEmpty == false {
            var queryless = components
            queryless.query = nil
            addComparisonKeys(from: queryless, to: &keys)
            addSchemeVariants(from: queryless, to: &keys)
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

    func status() async throws -> URLstatus?{
        
        var status = URLstatus(lastRequest: Date())
        


                    let session = URLSession.shared
                    var request = URLRequest(url: self)
                    request.cachePolicy = .reloadIgnoringLocalCacheData  // Always fetch from server
                    request.timeoutInterval = 8

                    request.httpMethod = "HEAD"
        
        if let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String{
                        request.setValue(appName, forHTTPHeaderField: "User-Agent")
                    }
        
        do{
                        let (_, response) = try await session.data(for: request)
                        
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
            let (data, _) = try await URLSession.shared.data(from: self)
            return data
            
        }catch{
            // print(error)
        }
    return nil
    }
       
    func feedData() async -> Data?{
        // print("loading feedData for \(self.absoluteString)")
        let session = URLSession.shared
        
        let request = URLRequest(url: self)
        /*
        if let appName = Bundle.main.applicationName{
            request.setValue(appName, forHTTPHeaderField: "User-Agent")
        }
         */
        do{
            let (data, response) = try await session.data(for: request)
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
