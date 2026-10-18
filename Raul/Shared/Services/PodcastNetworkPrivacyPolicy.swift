import Foundation

/// Conservative request policy shared by the app's controllable URLSession paths.
/// The source URL remains the library identity; this only changes a wire request.
enum PodcastNetworkPrivacyPolicy {
    static let settingKey = "networkTrackingProtection.enabled.v1"
    static let appGroupID = "group.de.holgerkrupp.PodcastClient"
    static let ruleVersion = 1

    enum Purpose: String, Sendable, CaseIterable {
        case feed, audio, artwork, chapter, transcript, shownote, discovery, shareImport, watch
    }

    enum Outcome: String, Sendable, Equatable {
        case unchanged, cleaned, bypassedKnownPrefix, blocked
    }

    struct Decision: Sendable {
        let url: URL
        let outcome: Outcome
        let purpose: Purpose
        let ruleVersion: Int
        let failureMessage: String?
    }

    static var isEnabled: Bool {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        // Missing means enabled, including on existing installs and extensions.
        return defaults.object(forKey: settingKey) as? Bool ?? true
    }

    static func prepare(_ url: URL, purpose: Purpose, enabled: Bool = isEnabled) -> Decision {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else {
            return Decision(url: url, outcome: .blocked, purpose: purpose, ruleVersion: ruleVersion, failureMessage: "This network address is invalid or uses an unsupported scheme.")
        }

        if enabled && (host == "op3.dev" || host == "www.op3.dev") {
            guard let unwrapped = unwrapOP3(url, depth: 0) else {
                return Decision(url: url, outcome: .blocked, purpose: purpose, ruleVersion: ruleVersion, failureMessage: "This OP3 tracking link could not be safely opened. Use the original podcast link.")
            }
            let nested = prepare(unwrapped, purpose: purpose, enabled: enabled)
            guard nested.outcome != .blocked else { return nested }
            return Decision(url: nested.url, outcome: .bypassedKnownPrefix, purpose: purpose, ruleVersion: ruleVersion, failureMessage: nil)
        }

        let path = components.percentEncodedPath.removingPercentEncoding?.lowercased() ?? components.percentEncodedPath.lowercased()
        if enabled,
           ["podtrac.com", "www.podtrac.com", "dts.podtrac.com"].contains(host),
           path.hasPrefix("/redirect.mp3/") || path.hasPrefix("/pts/redirect.mp3/") {
            return Decision(
                url: url,
                outcome: .blocked,
                purpose: purpose,
                ruleVersion: ruleVersion,
                failureMessage: "This Podtrac tracking link hides the original scheme, so Up Next cannot safely open it. Replace it with the publisher's original episode link."
            )
        }

        guard enabled, let query = components.percentEncodedQuery else {
            return Decision(url: url, outcome: .unchanged, purpose: purpose, ruleVersion: ruleVersion, failureMessage: nil)
        }

        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        let names = pairs.map { pair -> String in
            let rawName = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return rawName.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?.lowercased() ?? rawName.lowercased()
        }
        // A query string carrying a recognized signing marker is opaque. Even
        // removing a known click ID could invalidate the publisher's signature.
        let signingNames: Set<String> = ["signature", "sig", "x-amz-signature", "x-goog-signature", "x-goog-credential", "x-amz-credential", "x-amz-algorithm", "key-pair-id", "policy"]
        guard names.contains(where: signingNames.contains) == false else {
            return Decision(url: url, outcome: .unchanged, purpose: purpose, ruleVersion: ruleVersion, failureMessage: nil)
        }

        let retained = zip(pairs, names).filter { !isTrackingParameter($0.1) }.map(\.0)
        guard retained.count != pairs.count else {
            return Decision(url: url, outcome: .unchanged, purpose: purpose, ruleVersion: ruleVersion, failureMessage: nil)
        }
        components.percentEncodedQuery = retained.isEmpty ? nil : retained.joined(separator: "&")
        return Decision(url: components.url ?? url, outcome: .cleaned, purpose: purpose, ruleVersion: ruleVersion, failureMessage: nil)
    }

    private static func unwrapOP3(_ url: URL, depth: Int) -> URL? {
        guard depth < 3, let host = url.host?.lowercased(), host == "op3.dev" || host == "www.op3.dev",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.percentEncodedPath.removingPercentEncoding,
              path.hasPrefix("/e/"), path.count > 3 else { return nil }
        let rawTarget = String(path.dropFirst(3))
        guard let target = URL(string: rawTarget),
              let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
              target.host != nil, target.user == nil, target.password == nil else { return nil }
        if target.host?.lowercased() == "op3.dev" || target.host?.lowercased() == "www.op3.dev" {
            return unwrapOP3(target, depth: depth + 1)
        }
        return target
    }

    static func record(_ decision: Decision) {
        guard decision.outcome != .unchanged else { return }
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        let key = "networkTrackingProtection.count.\(decision.purpose.rawValue).\(decision.outcome.rawValue)"
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    static func wireURL(for url: URL, purpose: Purpose) throws -> URL {
        let decision = prepare(url, purpose: purpose)
        record(decision)
        guard decision.outcome != .blocked else {
            throw NSError(domain: "PodcastNetworkPrivacyPolicy", code: 1, userInfo: [NSLocalizedDescriptionKey: decision.failureMessage ?? "This network address could not be safely opened."])
        }
        return decision.url
    }

    static func prepare(_ request: URLRequest, purpose: Purpose) throws -> URLRequest {
        var request = request
        if let url = request.url { request.url = try wireURL(for: url, purpose: purpose) }
        request.setValue(nil, forHTTPHeaderField: "Referer")
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("UpNext/1.0 (+https://github.com/holgerkrupp/PodcastClient)", forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    static func session(
        configuration: URLSessionConfiguration = .ephemeral,
        purpose: Purpose
    ) -> URLSession {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration, delegate: RedirectDelegate(purpose: purpose), delegateQueue: nil)
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let purpose: Purpose
        init(purpose: Purpose) { self.purpose = purpose }

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
            let decision = PodcastNetworkPrivacyPolicy.prepare(url, purpose: purpose)
            PodcastNetworkPrivacyPolicy.record(decision)
            guard decision.outcome != .blocked else { completionHandler(nil); return }
            var protected = request
            protected.url = decision.url
            protected.setValue(nil, forHTTPHeaderField: "Referer")
            if protected.value(forHTTPHeaderField: "User-Agent") == nil {
                protected.setValue("UpNext/1.0 (+https://github.com/holgerkrupp/PodcastClient)", forHTTPHeaderField: "User-Agent")
            }
            let previousURL = task.currentRequest?.url ?? response.url
            protected.setValue(nil, forHTTPHeaderField: "Referer")
            if Self.isSameCredentialOrigin(previousURL, url) == false {
                protected.setValue(nil, forHTTPHeaderField: "Authorization")
                protected.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            completionHandler(protected)
        }

        private static func isSameCredentialOrigin(_ source: URL?, _ destination: URL) -> Bool {
            guard let source,
                  let sourceScheme = source.scheme?.lowercased(),
                  let destinationScheme = destination.scheme?.lowercased(),
                  source.host?.lowercased() == destination.host?.lowercased() else { return false }
            let effectivePort: (URL) -> Int? = { url in
                if let port = url.port { return port }
                if url.scheme?.lowercased() == "http" { return 80 }
                if url.scheme?.lowercased() == "https" { return 443 }
                return nil
            }
            if sourceScheme == destinationScheme {
                return effectivePort(source) == effectivePort(destination)
            }
            return sourceScheme == "http" && destinationScheme == "https"
                && effectivePort(source) == 80 && effectivePort(destination) == 443
        }
    }

    static func diagnosticCounts() -> [String: Int] {
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        return Dictionary(uniqueKeysWithValues: Purpose.allCases.flatMap { purpose in
            [Outcome.cleaned, .bypassedKnownPrefix, .blocked].map { outcome in
                let key = "networkTrackingProtection.count.\(purpose.rawValue).\(outcome.rawValue)"
                return ("\(purpose.rawValue).\(outcome.rawValue)", defaults.integer(forKey: key))
            }
        })
    }

    private static func isTrackingParameter(_ name: String) -> Bool {
        name.hasPrefix("utm_") || [
            "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid"
        ].contains(name)
    }
}
