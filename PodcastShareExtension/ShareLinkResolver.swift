import Foundation

struct ShareLinkPodcast: Equatable, Sendable {
    let title: String
    let feedURL: URL
    let artworkURL: URL?
}

struct ShareLinkEpisode: Equatable, Sendable {
    let title: String
    let description: String?
    let mediaURL: URL?
    let pageURL: URL?
    let artworkURL: URL?
    let duration: TimeInterval?
}

struct ShareLinkStandaloneMedia: Equatable, Sendable {
    let title: String
    let description: String?
    let pageURL: URL
    let mediaURL: URL
    let artworkURL: URL?
    let duration: TimeInterval?
}

enum ShareLinkResolution: Equatable, Sendable {
    case podcastEpisode(podcast: ShareLinkPodcast, episode: ShareLinkEpisode)
    case podcast(ShareLinkPodcast)
    case standaloneMedia(ShareLinkStandaloneMedia, podcast: ShareLinkPodcast?)
    case unresolved(sharedURL: URL, suggestedSearch: String?, podcast: ShareLinkPodcast?)

    var podcastFeed: ShareLinkPodcast? {
        switch self {
        case .podcastEpisode(let podcast, _), .podcast(let podcast): return podcast
        case .standaloneMedia(_, let podcast), .unresolved(_, _, let podcast): return podcast
        }
    }
}

struct ShareLinkResolver: Sendable {
    func resolve(
        _ url: URL,
        onPodcastFound: @MainActor @Sendable (ShareLinkPodcast) -> Void = { _ in }
    ) async -> ShareLinkResolution {
        if isPlayable(url) {
            return .standaloneMedia(
                ShareLinkStandaloneMedia(
                    title: fallbackTitle(for: url),
                    description: nil,
                    pageURL: url,
                    mediaURL: url,
                    artworkURL: nil,
                    duration: nil
                ),
                podcast: nil
            )
        }

        if let ard = await resolveARD(url) {
            return ard
        }

        guard let html = await fetchText(from: url) else {
            return .unresolved(sharedURL: url, suggestedSearch: fallbackSearch(for: url), podcast: nil)
        }

        let pageTitle = metadata("og:title", in: html) ?? titleTag(in: html) ?? fallbackTitle(for: url)
        let episodeTitle = articleTitle(in: html) ?? pageTitle
        let description = metadata("og:description", in: html) ?? metadata("description", in: html)
        let artworkURL = metadata("og:image", in: html).flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        let feedURLs = feedURLs(in: html, baseURL: url)

        var discoveredPodcast: ShareLinkPodcast?
        for feedLink in feedURLs {
            if feedLink.isPodcast, discoveredPodcast == nil {
                let podcast = ShareLinkPodcast(title: pageTitle, feedURL: feedLink.url, artworkURL: artworkURL)
                discoveredPodcast = podcast
                await onPodcastFound(podcast)
            }

            guard let feed = await fetchFeed(from: feedLink.url) else { continue }
            let podcast = ShareLinkPodcast(title: feed.title ?? pageTitle, feedURL: feedLink.url, artworkURL: feed.artworkURL ?? artworkURL)
            guard feed.episodes.contains(where: { $0.mediaURL != nil }) else { continue }

            if discoveredPodcast == nil {
                discoveredPodcast = podcast
                await onPodcastFound(podcast)
            }

            if let episode = feed.episodes.first(where: { matches($0, pageURL: url) })
                ?? feed.episodes.first(where: { matches($0, title: episodeTitle) }) {
                return .podcastEpisode(podcast: podcast, episode: episode)
            }
        }

        if let mediaURL = mediaURL(in: html, baseURL: url) {
            return .standaloneMedia(
                ShareLinkStandaloneMedia(
                    title: pageTitle,
                    description: description,
                    pageURL: url,
                    mediaURL: mediaURL,
                    artworkURL: artworkURL,
                    duration: metadata("music:duration", in: html).flatMap(TimeInterval.init)
                ),
                podcast: discoveredPodcast
            )
        }

        if let discoveredPodcast { return .podcast(discoveredPodcast) }

        return .unresolved(sharedURL: url, suggestedSearch: fallbackSearch(for: url, title: episodeTitle), podcast: nil)
    }

    private func resolveARD(_ url: URL) async -> ShareLinkResolution? {
        guard let host = url.host()?.lowercased(),
              host == "ardsounds.de" || host.hasSuffix(".ardsounds.de") ||
              host == "ardaudiothek.de" || host.hasSuffix(".ardaudiothek.de") else { return nil }
        let path = url.path.removingPercentEncoding ?? url.path
        guard let regex = try? NSRegularExpression(pattern: #"(?i)urn:ard:(?:episode|section|extra):[a-z0-9]+"#),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..<path.endIndex, in: path)),
              let range = Range(match.range, in: path) else { return nil }
        let urn = String(path[range])

        guard let endpoint = URL(string: "https://api.ardaudiothek.de/graphql") else { return nil }
        let query = """
        query($id: ID!) { item(id: $id) { title description duration audioList { href } audios { url } image { url url1X1 } show { title } programSet { title } } }
        """
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": ["id": urn]]) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = ((root["data"] as? [String: Any])?["item"] as? [String: Any]),
              let title = item["title"] as? String,
              let mediaURLString = firstMediaURL(in: item),
              let mediaURL = URL(string: mediaURLString) else { return nil }

        let image = item["image"] as? [String: Any]
        let imageURL = (image?["url1X1"] as? String ?? image?["url"] as? String).flatMap {
            URL(string: $0.replacingOccurrences(of: "{width}", with: "448"))
        }
        return .standaloneMedia(
            ShareLinkStandaloneMedia(
                title: title,
                description: item["description"] as? String,
                pageURL: url,
                mediaURL: mediaURL,
                artworkURL: imageURL,
                duration: (item["duration"] as? NSNumber)?.doubleValue
            ),
            podcast: nil
        )
    }

    private func firstMediaURL(in item: [String: Any]) -> String? {
        let lists = [item["audioList"] as? [[String: Any]], item["audios"] as? [[String: Any]]]
        for list in lists.compactMap({ $0 }) {
            for audio in list {
                if let value = (audio["href"] as? String) ?? (audio["url"] as? String), URL(string: value) != nil { return value }
            }
        }
        return nil
    }

    private func fetchText(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private func fetchFeed(from url: URL) async -> LightweightFeedParser.Feed? {
        guard let text = await fetchText(from: url), let data = text.data(using: .utf8) else { return nil }
        let parser = LightweightFeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { return nil }
        return parser.result
    }

    private func feedURLs(in html: String, baseURL: URL) -> [(url: URL, isPodcast: Bool)] {
        let tags = matches(#"<link\b[^>]*>"#, in: html)
        let candidates = tags.compactMap { tag -> (url: URL, isPodcast: Bool)? in
            let rel = attribute("rel", in: tag)?.lowercased() ?? ""
            let type = attribute("type", in: tag)?.lowercased() ?? ""
            guard rel.contains("alternate"), type.contains("rss") || type.contains("atom") || type.contains("xml"), let href = attribute("href", in: tag) else { return nil }
            let title = attribute("title", in: tag)?.lowercased() ?? ""
            guard title.contains("comment") == false,
                  href.lowercased().contains("comment") == false,
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else { return nil }
            return (url, title.contains("podcast") || title.contains("audio"))
        }
        return candidates.sorted { $0.isPodcast && !$1.isPodcast }
    }

    private func mediaURL(in html: String, baseURL: URL) -> URL? {
        let keys = ["og:audio", "og:audio:url", "og:video", "og:video:url", "twitter:player:stream"]
        for key in keys {
            if let value = metadata(key, in: html), let url = URL(string: value, relativeTo: baseURL)?.absoluteURL, isPlayable(url) { return url }
        }
        let values = captures(#"(?:src|href)=[\"']([^\"']+\.(?:mp3|m4a|aac|flac|wav|mp4|m4v|mov|m3u8)(?:\?[^\"']*)?)[\"']"#, in: html)
        return values.compactMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }.first(where: isPlayable)
    }

    private func matches(_ episode: ShareLinkEpisode, pageURL: URL) -> Bool {
        episode.pageURL.map { normalizedPageURL($0) == normalizedPageURL(pageURL) } == true
            || episode.mediaURL.map { normalizedPageURL($0) == normalizedPageURL(pageURL) } == true
    }

    private func matches(_ episode: ShareLinkEpisode, title: String) -> Bool {
        let candidate = normalized(title)
        return candidate.isEmpty == false && normalized(episode.title) == candidate
    }

    private func normalizedPageURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? url.absoluteString
    }

    private func articleTitle(in html: String) -> String? {
        guard let article = matches(#"<article\b[^>]*>.*?</article>"#, in: html).first,
              let heading = matches(#"<h[1-3]\b[^>]*class=[\"'][^\"']*\bentry-title\b[^\"']*[\"'][^>]*>.*?</h[1-3]>"#, in: article).first else {
            return nil
        }
        let plainText = heading.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        let title = decode(plainText).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func isPlayable(_ url: URL) -> Bool {
        ["aac", "aif", "aiff", "flac", "m4a", "m4v", "m3u8", "mov", "mp3", "mp4", "opus", "wav"].contains(url.pathExtension.lowercased())
    }

    private func metadata(_ name: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = [#"<meta\b[^>]*(?:property|name)=[\"']\#(escaped)[\"'][^>]*content=[\"']([^\"']+)[\"'][^>]*>"#, #"<meta\b[^>]*content=[\"']([^\"']+)[\"'][^>]*(?:property|name)=[\"']\#(escaped)[\"'][^>]*>"#]
        guard let value = patterns.lazy.compactMap({ firstCapture($0, in: html) }).first else {
            return nil
        }
        return decode(value)
    }

    private func titleTag(in html: String) -> String? {
        guard let value = firstCapture(#"<title[^>]*>(.*?)</title>"#, in: html) else { return nil }
        return decode(value)
    }

    private func attribute(_ name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\#(escapedName)\s*=\s*[\"']([^\"']+)[\"']"#
        guard let value = firstCapture(pattern, in: tag) else { return nil }
        return decode(value)
    }
    private func fallbackTitle(for url: URL) -> String { (url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? "").isEmpty ? (url.host() ?? url.absoluteString) : (url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent) }
    private func fallbackSearch(for url: URL, title: String? = nil) -> String? { title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title!.trimmingCharacters(in: .whitespacesAndNewlines) : url.host() }
    private func normalized(_ value: String) -> String { value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.reduce(into: "") { $0.unicodeScalars.append($1) } }
    private func decode(_ value: String) -> String { value.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&#8217;", with: "’").replacingOccurrences(of: "&nbsp;", with: " ") }
    private func matches(_ pattern: String, in value: String) -> [String] { guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }; let range = NSRange(value.startIndex..<value.endIndex, in: value); return regex.matches(in: value, range: range).compactMap { Range($0.range, in: value).map { String(value[$0]) } } }
    private func captures(_ pattern: String, in value: String) -> [String] { guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }; let range = NSRange(value.startIndex..<value.endIndex, in: value); return regex.matches(in: value, range: range).compactMap { Range($0.range(at: 1), in: value).map { String(value[$0]) } } }
    private func firstCapture(_ pattern: String, in value: String) -> String? { guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }; let range = NSRange(value.startIndex..<value.endIndex, in: value); guard let match = regex.firstMatch(in: value, range: range), let capture = Range(match.range(at: 1), in: value) else { return nil }; return String(value[capture]) }
}

private final class LightweightFeedParser: NSObject, XMLParserDelegate {
    struct Feed { var title: String?; var artworkURL: URL?; var episodes: [ShareLinkEpisode] = [] }
    var result: Feed?
    private var current = ""
    private var text = ""
    private var feedTitle: String?
    private var artwork: URL?
    private var currentEpisode: [String: String] = [:]
    private var episodes: [ShareLinkEpisode] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        current = name.lowercased(); text = ""
        if current == "item" || current == "entry" { currentEpisode = [:] }
        if current == "enclosure" { currentEpisode["media"] = attributeDict["url"] ?? attributeDict["href"] }
        if current == "image",
           let imageString = attributeDict["href"] ?? attributeDict["url"] {
            artwork = URL(string: imageString)
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name.lowercased() {
        case "title": if currentEpisode.isEmpty { feedTitle = value } else { currentEpisode["title"] = value }
        case "description", "summary": if currentEpisode.isEmpty == false { currentEpisode["description"] = value }
        case "link": if currentEpisode.isEmpty == false { currentEpisode["link"] = value }
        case "guid", "id": if currentEpisode.isEmpty == false { currentEpisode["guid"] = value }
        case "url": if artwork == nil { artwork = URL(string: value) }
        case "item", "entry":
            if let title = currentEpisode["title"] { episodes.append(ShareLinkEpisode(title: title, description: currentEpisode["description"], mediaURL: currentEpisode["media"].flatMap(URL.init(string:)), pageURL: currentEpisode["link"].flatMap(URL.init(string:)), artworkURL: nil, duration: nil)) }
        default: break
        }
    }
    func parserDidEndDocument(_ parser: XMLParser) { result = Feed(title: feedTitle, artworkURL: artwork, episodes: episodes) }
}
