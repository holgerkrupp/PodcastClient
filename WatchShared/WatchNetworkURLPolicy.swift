import Foundation

/// Foundation-only URL preparation shared by the phone and watch targets.
/// It keeps the signed/source URL elsewhere and returns only the effective URL
/// used for a new network request.
enum WatchNetworkURLPolicy {
    static func prepare(_ url: URL, enabled: Bool = true) -> URL {
        guard let resolved = resolve(url, enabled: enabled) else { return url }
        return resolved
    }

    static func resolve(_ url: URL, enabled: Bool = true) -> URL? {
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return nil }
        if enabled && (host == "op3.dev" || host == "www.op3.dev") {
            guard let target = unwrapOP3(url, depth: 0) else { return nil }
            record("bypassedKnownPrefix")
            return resolve(target, enabled: enabled)
        }
        if enabled, ["podtrac.com", "www.podtrac.com", "dts.podtrac.com"].contains(host),
           let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding?.lowercased(),
           path.hasPrefix("/redirect.mp3/") || path.hasPrefix("/pts/redirect.mp3/") {
            record("blocked")
            return nil
        }
        guard enabled,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery else { return url }
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        let decodedNames = pairs.map { pair -> String in
            let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return name.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?.lowercased() ?? name.lowercased()
        }
        let signed = Set(["signature", "sig", "x-amz-signature", "x-goog-signature", "x-amz-credential", "x-goog-credential", "x-amz-algorithm", "key-pair-id", "policy"])
        guard decodedNames.contains(where: signed.contains) == false else { return url }
        let retained = zip(pairs, decodedNames).filter { !isTracker($0.1) }.map(\.0)
        guard retained.count != pairs.count else { return url }
        components.percentEncodedQuery = retained.isEmpty ? nil : retained.joined(separator: "&")
        record("cleaned")
        return components.url ?? url
    }

    static func data(from url: URL, enabled: Bool = true) async throws -> (Data, URLResponse) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw URLError(.unsupportedURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let delegate = RedirectDelegate(enabled: enabled)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let protectedURL = resolve(url, enabled: enabled) else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: protectedURL)
        request.setValue("UpNext/1.0 (+https://github.com/holgerkrupp/PodcastClient)", forHTTPHeaderField: "User-Agent")
        return try await session.data(for: request)
    }

    private static func unwrapOP3(_ url: URL, depth: Int) -> URL? {
        guard depth < 3,
              let host = url.host?.lowercased(), host == "op3.dev" || host == "www.op3.dev",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding,
              path.hasPrefix("/e/"), path.count > 3,
              let target = URL(string: String(path.dropFirst(3))),
              let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
              target.host != nil, target.user == nil, target.password == nil else { return nil }
        if target.host?.lowercased() == "op3.dev" || target.host?.lowercased() == "www.op3.dev" {
            return unwrapOP3(target, depth: depth + 1)
        }
        return target
    }

    private static func isTracker(_ name: String) -> Bool {
        name.hasPrefix("utm_") || ["fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid"].contains(name)
    }

    private static func record(_ outcome: String) {
        let defaults = UserDefaults(suiteName: "group.de.holgerkrupp.PodcastClient") ?? .standard
        let key = "networkTrackingProtection.count.watch.\(outcome)"
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let enabled: Bool
        init(enabled: Bool) { self.enabled = enabled }

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
            var protected = request
            guard let protectedURL = WatchNetworkURLPolicy.resolve(url, enabled: enabled) else {
                completionHandler(nil)
                return
            }
            protected.url = protectedURL
            protected.setValue(nil, forHTTPHeaderField: "Referer")
            if protected.value(forHTTPHeaderField: "User-Agent") == nil {
                protected.setValue("UpNext/1.0 (+https://github.com/holgerkrupp/PodcastClient)", forHTTPHeaderField: "User-Agent")
            }
            completionHandler(protected)
        }
    }
}
