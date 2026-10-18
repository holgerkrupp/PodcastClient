import Foundation

enum ShareNetworkPrivacy {
    static let settingKey = "networkTrackingProtection.enabled.v1"
    static let appGroupID = "group.de.holgerkrupp.PodcastClient"

    static var enabled: Bool {
        (UserDefaults(suiteName: appGroupID) ?? .standard).object(forKey: settingKey) as? Bool ?? true
    }

    static func prepare(_ url: URL) -> URL {
        resolve(url) ?? url
    }

    static func resolve(_ url: URL) -> URL? {
        resolve(url, depth: 0)
    }

    private static func resolve(_ url: URL, depth: Int) -> URL? {
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return nil }
        if enabled && (host == "op3.dev" || host == "www.op3.dev") {
            guard depth < 3 else { return nil }
            guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding,
                  path.hasPrefix("/e/"), path.count > 3,
                  let target = URL(string: String(path.dropFirst(3))),
                  let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  target.host != nil, target.user == nil, target.password == nil else { return nil }
            record("bypassedKnownPrefix")
            return resolve(target, depth: depth + 1)
        }
        if enabled, ["podtrac.com", "www.podtrac.com", "dts.podtrac.com"].contains(host),
           let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding?.lowercased(),
           path.hasPrefix("/redirect.mp3/") || path.hasPrefix("/pts/redirect.mp3/") {
            record("blocked")
            return nil
        }
        guard enabled, let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        let names = pairs.map { pair -> String in
            let raw = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?.lowercased() ?? raw.lowercased()
        }
        let signed = Set(["signature", "sig", "x-amz-signature", "x-goog-signature", "x-amz-credential", "x-goog-credential", "x-amz-algorithm", "key-pair-id", "policy"])
        guard names.contains(where: signed.contains) == false else { return url }
        let kept = zip(pairs, names).filter { name in
            !name.1.hasPrefix("utm_") && !["fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid"].contains(name.1)
        }.map(\.0)
        guard kept.count != pairs.count else { return url }
        components.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        record("cleaned")
        return components.url ?? url
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        if let url = request.url {
            guard let protectedURL = resolve(url) else { throw URLError(.unsupportedURL) }
            request.url = protectedURL
        }
        request.setValue(nil, forHTTPHeaderField: "Referer")
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("UpNext/1.0 (+https://github.com/holgerkrupp/PodcastClient)", forHTTPHeaderField: "User-Agent")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let delegate = RedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url else {
                completionHandler(nil)
                return
            }
            guard let protectedURL = resolve(url) else {
                completionHandler(nil)
                return
            }
            var protected = request
            protected.url = protectedURL
            if protected.value(forHTTPHeaderField: "User-Agent") == nil {
                protected.setValue("UpNext/1.0 (+https://github.com/holgerkrupp/PodcastClient)", forHTTPHeaderField: "User-Agent")
            }
            protected.setValue(nil, forHTTPHeaderField: "Referer")
            if let previousURL = task.currentRequest?.url,
               previousURL.scheme?.lowercased() != url.scheme?.lowercased()
                || previousURL.host?.lowercased() != url.host?.lowercased()
                || previousURL.port != url.port {
                protected.setValue(nil, forHTTPHeaderField: "Authorization")
                protected.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            completionHandler(protected)
        }
    }

    private static func record(_ outcome: String) {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        let key = "networkTrackingProtection.count.shareImport.\(outcome)"
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }
}
