import Foundation

struct NamespaceNode: Codable, Hashable, Sendable {
    var name: String
    var value: String?
    var attributes: [String: String]
    var children: [NamespaceNode]

    init(
        name: String,
        value: String? = nil,
        attributes: [String: String] = [:],
        children: [NamespaceNode] = []
    ) {
        self.name = name
        self.value = value
        self.attributes = attributes
        self.children = children
    }
}

struct PodcastTrailer: Hashable, Identifiable {
    let id: String
    let title: String
    let url: URL
    let publishDate: Date?
    let season: String?
    let length: Int?
    let type: String?

    var displayTitle: String {
        if let season {
            return "Season \(season): \(title)"
        }

        return title
    }

    init?(node: NamespaceNode, baseURL: URL?) {
        guard Self.localName(from: node.name) == "trailer",
              let urlString = Self.trimmed(node.attributes["url"]),
              let url = URL(string: urlString, relativeTo: baseURL)?.absoluteURL
        else {
            return nil
        }

        let title = Self.trimmed(node.value) ?? "Podcast Trailer"
        let season = Self.trimmed(node.attributes["season"])
        self.id = [season, url.absoluteString].compactMap { $0 }.joined(separator: "-")
        self.title = title
        self.url = url
        self.publishDate = Self.trimmed(node.attributes["pubdate"]).flatMap {
            Date.dateFromRFC1123(dateString: $0)
        }
        self.season = season
        self.length = Self.trimmed(node.attributes["length"]).flatMap(Int.init)
        self.type = Self.trimmed(node.attributes["type"])
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func localName(from qualifiedName: String) -> String {
        if qualifiedName.hasPrefix("podcast:") {
            return String(qualifiedName.dropFirst("podcast:".count))
        }
        return qualifiedName
    }
}

struct PodcastPodrollItem: Hashable, Identifiable, Sendable {
    let id: String
    let title: String?
    let feedURL: URL?
    let feedGUID: String?
    let itemGUID: String?
    let medium: String?

    var displayTitle: String {
        if let title, title.isEmpty == false {
            return title
        }

        if let feedURL {
            return feedURL.absoluteString.removingPercentEncoding ?? feedURL.absoluteString
        }

        if let feedGUID, feedGUID.isEmpty == false {
            return feedGUID
        }

        return "Recommended Podcast"
    }

    var hasResolvableFeed: Bool {
        feedURL != nil
    }

    init?(node: NamespaceNode, baseURL: URL?) {
        guard Self.localName(from: node.name) == "remoteItem" else {
            return nil
        }

        let title = Self.trimmed(node.attribute(named: "title"))
        let feedGUID = Self.trimmed(node.attribute(named: "feedGuid"))
        let itemGUID = Self.trimmed(node.attribute(named: "itemGuid"))
        let medium = Self.trimmed(node.attribute(named: "medium"))
        let feedURL = Self.trimmed(node.attribute(named: "feedUrl"))
            .flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }

        guard title != nil || feedGUID != nil || feedURL != nil else {
            return nil
        }

        self.id = feedURL?.absoluteString ?? feedGUID ?? title ?? UUID().uuidString
        self.title = title
        self.feedURL = feedURL
        self.feedGUID = feedGUID
        self.itemGUID = itemGUID
        self.medium = medium
    }

    func podcastFeed(fetchMetadataIfNeeded: Bool) -> PodcastFeed {
        PodcastFeed(
            url: feedURL,
            title: displayTitle,
            source: nil,
            fetchMetadataIfNeeded: fetchMetadataIfNeeded
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func localName(from qualifiedName: String) -> String {
        if qualifiedName.hasPrefix("podcast:") {
            return String(qualifiedName.dropFirst("podcast:".count))
        }
        return qualifiedName
    }
}

struct PodcastNamespaceOptionalTags: Codable, Hashable {
    var alternateEnclosure: [NamespaceNode]?
    var block: [NamespaceNode]?
    var chat: [NamespaceNode]?
    var contentLink: [NamespaceNode]?
    var episode: [NamespaceNode]?
    var image: [NamespaceNode]?
    var images: [NamespaceNode]? // deprecated
    var integrity: [NamespaceNode]?
    var license: [NamespaceNode]?
    var liveItem: [NamespaceNode]?
    var location: [NamespaceNode]?
    var locked: [NamespaceNode]?
    var medium: [NamespaceNode]?
    var podping: [NamespaceNode]?
    var podroll: [NamespaceNode]?
    var publisher: [NamespaceNode]?
    var remoteItem: [NamespaceNode]?
    var season: [NamespaceNode]?
    var soundbite: [NamespaceNode]?
    var source: [NamespaceNode]?
    var trailer: [NamespaceNode]?
    var txt: [NamespaceNode]?
    var updateFrequency: [NamespaceNode]?
    var value: [NamespaceNode]?
    var valueRecipient: [NamespaceNode]?
    var valueTimeSplit: [NamespaceNode]?

    var isEmpty: Bool {
        alternateEnclosure == nil &&
        block == nil &&
        chat == nil &&
        contentLink == nil &&
        episode == nil &&
        image == nil &&
        images == nil &&
        integrity == nil &&
        license == nil &&
        liveItem == nil &&
        location == nil &&
        locked == nil &&
        medium == nil &&
        podping == nil &&
        podroll == nil &&
        publisher == nil &&
        remoteItem == nil &&
        season == nil &&
        soundbite == nil &&
        source == nil &&
        trailer == nil &&
        txt == nil &&
        updateFrequency == nil &&
        value == nil &&
        valueRecipient == nil &&
        valueTimeSplit == nil
    }

    var allNodes: [NamespaceNode] {
        [
            alternateEnclosure, block, chat, contentLink, episode, image,
            images, integrity, license, liveItem, location, locked, medium,
            podping, podroll, publisher, remoteItem, season, soundbite,
            source, trailer, txt, updateFrequency, value, valueRecipient,
            valueTimeSplit
        ].compactMap { $0 }.flatMap { $0 }
    }

    mutating func append(_ node: NamespaceNode) {
        switch Self.localName(from: node.name) {
        case "alternateEnclosure":
            if alternateEnclosure == nil { alternateEnclosure = [] }
            alternateEnclosure?.append(node)
        case "block":
            if block == nil { block = [] }
            block?.append(node)
        case "chat":
            if chat == nil { chat = [] }
            chat?.append(node)
        case "contentLink":
            if contentLink == nil { contentLink = [] }
            contentLink?.append(node)
        case "episode":
            if episode == nil { episode = [] }
            episode?.append(node)
        case "image":
            if image == nil { image = [] }
            image?.append(node)
        case "images":
            if images == nil { images = [] }
            images?.append(node)
        case "integrity":
            if integrity == nil { integrity = [] }
            integrity?.append(node)
        case "license":
            if license == nil { license = [] }
            license?.append(node)
        case "liveItem":
            if liveItem == nil { liveItem = [] }
            liveItem?.append(node)
        case "location":
            if location == nil { location = [] }
            location?.append(node)
        case "locked":
            if locked == nil { locked = [] }
            locked?.append(node)
        case "medium":
            if medium == nil { medium = [] }
            medium?.append(node)
        case "podping":
            if podping == nil { podping = [] }
            podping?.append(node)
        case "podroll":
            if podroll == nil { podroll = [] }
            podroll?.append(node)
        case "publisher":
            if publisher == nil { publisher = [] }
            publisher?.append(node)
        case "remoteItem":
            if remoteItem == nil { remoteItem = [] }
            remoteItem?.append(node)
        case "season":
            if season == nil { season = [] }
            season?.append(node)
        case "soundbite":
            if soundbite == nil { soundbite = [] }
            soundbite?.append(node)
        case "source":
            if source == nil { source = [] }
            source?.append(node)
        case "trailer":
            if trailer == nil { trailer = [] }
            trailer?.append(node)
        case "txt":
            if txt == nil { txt = [] }
            txt?.append(node)
        case "updateFrequency":
            if updateFrequency == nil { updateFrequency = [] }
            updateFrequency?.append(node)
        case "value":
            if value == nil { value = [] }
            value?.append(node)
        case "valueRecipient":
            if valueRecipient == nil { valueRecipient = [] }
            valueRecipient?.append(node)
        case "valueTimeSplit":
            if valueTimeSplit == nil { valueTimeSplit = [] }
            valueTimeSplit?.append(node)
        default:
            break
        }
    }

    func podcastTrailers(baseURL: URL?) -> [PodcastTrailer] {
        (trailer ?? [])
            .compactMap { PodcastTrailer(node: $0, baseURL: baseURL) }
            .sorted { lhs, rhs in
                switch (lhs.publishDate, rhs.publishDate) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate > rhsDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
                }
            }
    }

    func podcastPodrollItems(baseURL: URL?) -> [PodcastPodrollItem] {
        return (podroll ?? [])
            .flatMap { podrollNode in
                podrollNode.children.filter { Self.localName(from: $0.name) == "remoteItem" }
            }
            .compactMap { PodcastPodrollItem(node: $0, baseURL: baseURL) }
    }

    private static func localName(from qualifiedName: String) -> String {
        if qualifiedName.hasPrefix("podcast:") {
            return String(qualifiedName.dropFirst("podcast:".count))
        }
        return qualifiedName
    }

    /// Typed live broadcasts retained by this feed.
    ///
    /// The parser intentionally keeps the original namespace tree as the
    /// durable representation. This projection is derived on demand so a
    /// newer Podcasting 2.0 field can be retained without making an older
    /// app reject the complete feed.
    func podcastLiveItems(baseURL: URL?) -> [PodcastLiveItem] {
        (liveItem ?? []).compactMap { PodcastLiveItem(node: $0, baseURL: baseURL) }
    }
}

private extension NamespaceNode {
    func attribute(named requestedName: String) -> String? {
        attributes.first { key, _ in
            key.caseInsensitiveCompare(requestedName) == .orderedSame
        }?.value
    }
}

struct PodcastLiveItem: Hashable, Identifiable, Sendable {
    enum Status: Hashable, Sendable {
        case pending
        case live
        case ended
        case unknown(String)

        init(rawValue: String?) {
            switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "pending": self = .pending
            case "live": self = .live
            case "ended": self = .ended
            case let value?: self = .unknown(value)
            default: self = .unknown("")
            }
        }

        var rawValue: String {
            switch self {
            case .pending: "pending"
            case .live: "live"
            case .ended: "ended"
            case .unknown(let value): value
            }
        }

        var isVisible: Bool {
            self == .pending || self == .live
        }
    }

    struct StreamSource: Hashable, Identifiable, Sendable {
        let id: URL
        let url: URL
        let mimeType: String?
        let codec: String?
        let bitrate: Double?
        let language: String?
        let isDefault: Bool
        let title: String?

        var isHLS: Bool {
            let value = (mimeType ?? "").lowercased()
            return value.contains("mpegurl") || value.contains("m3u8") || value.contains("hls")
        }

        init(
            url: URL,
            mimeType: String? = nil,
            codec: String? = nil,
            bitrate: Double? = nil,
            language: String? = nil,
            isDefault: Bool = false,
            title: String? = nil
        ) {
            self.id = url
            self.url = url
            self.mimeType = mimeType
            self.codec = codec
            self.bitrate = bitrate
            self.language = language
            self.isDefault = isDefault
            self.title = title
        }
    }

    struct Chat: Hashable, Identifiable, Sendable {
        let id: URL
        let url: URL
        let `protocol`: String?
        let label: String
    }

    struct ContentLink: Hashable, Identifiable, Sendable {
        let id: URL
        let url: URL
        let label: String
        let type: String?
    }

    let id: String
    let guid: String?
    let title: String
    let status: Status
    let start: Date?
    let end: Date?
    let summary: String?
    let artworkURL: URL?
    let link: URL?
    let streamSources: [StreamSource]
    let chat: [Chat]
    let contentLinks: [ContentLink]

    /// The best candidate for AVPlayer, while preserving every publisher
    /// supplied candidate in `streamSources` for fallback and diagnostics.
    var preferredStream: StreamSource? {
        let supported = streamSources.filter { $0.url.scheme?.lowercased() == "http" || $0.url.scheme?.lowercased() == "https" }
        return supported.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            if lhs.isHLS != rhs.isHLS { return lhs.isHLS }
            return (lhs.bitrate ?? 0) > (rhs.bitrate ?? 0)
        }.first
    }

    var isUpcoming: Bool {
        status == .pending && (start == nil || start! > Date())
    }

    init(
        id: String,
        guid: String?,
        title: String,
        status: Status,
        start: Date?,
        end: Date?,
        summary: String?,
        artworkURL: URL?,
        link: URL?,
        streamSources: [StreamSource],
        chat: [Chat],
        contentLinks: [ContentLink]
    ) {
        self.id = id
        self.guid = guid
        self.title = title
        self.status = status
        self.start = start
        self.end = end
        self.summary = summary
        self.artworkURL = artworkURL
        self.link = link
        self.streamSources = streamSources
        self.chat = chat
        self.contentLinks = contentLinks
    }

    init?(node: NamespaceNode, baseURL: URL?) {
        guard Self.localName(node.name) == "liveItem" else { return nil }

        let guid = Self.trimmed(node.firstChild(named: "guid")?.value)
        let title = Self.trimmed(node.firstChild(named: "title")?.value) ?? "Live Event"
        let link = Self.url(
            Self.trimmed(node.firstChild(named: "link")?.value)
                ?? node.attributes["link"],
            relativeTo: baseURL,
            requireHTTP: true
        )
        let start = Self.date(node.attributes["start"])
        let end = Self.date(node.attributes["end"])
        let summary = Self.trimmed(
            node.firstChild(named: "description")?.value
                ?? node.firstChild(named: "summary")?.value
        )
        let artworkURL = Self.url(
            node.firstChild(named: "image")?.attributes["href"]
                ?? node.firstChild(named: "image")?.attributes["url"],
            relativeTo: baseURL,
            requireHTTP: true
        )

        var sources = node.children(named: "alternateEnclosure").flatMap { enclosure in
            let enclosureDefault = Self.bool(enclosure.attributes["default"])
            let enclosureType = Self.trimmed(enclosure.attributes["type"])
            let enclosureBitrate = Self.number(enclosure.attributes["bitrate"])
            let enclosureLanguage = Self.trimmed(enclosure.attributes["lang"] ?? enclosure.attributes["language"])
            let enclosureCodec = Self.trimmed(enclosure.attributes["codecs"] ?? enclosure.attributes["codec"])
            let enclosureTitle = Self.trimmed(enclosure.attributes["title"])
            return enclosure.children(named: "source").compactMap { source -> StreamSource? in
                Self.makeSource(
                    from: source,
                    baseURL: baseURL,
                    fallbackMimeType: enclosureType,
                    fallbackBitrate: enclosureBitrate,
                    fallbackLanguage: enclosureLanguage,
                    fallbackCodec: enclosureCodec,
                    fallbackTitle: enclosureTitle,
                    fallbackDefault: enclosureDefault
                )
            }
        }

        if let enclosure = node.firstChild(named: "enclosure"),
           let source = Self.makeSource(from: enclosure, baseURL: baseURL) {
            sources.append(source)
        }

        // A few publishers put the stream URL directly on alternateEnclosure
        // instead of using the nested source element. Preserve that form too.
        for enclosure in node.children(named: "alternateEnclosure") {
            if let source = Self.makeSource(from: enclosure, baseURL: baseURL),
               sources.contains(where: { $0.url == source.url }) == false {
                sources.append(source)
            }
        }

        let chat = node.children(named: "chat").compactMap { child -> Chat? in
            guard let url = Self.url(
                child.attributes["url"] ?? child.attributes["href"],
                relativeTo: baseURL,
                requireHTTP: true
            ) else { return nil }
            return Chat(
                id: url,
                url: url,
                protocol: Self.trimmed(child.attributes["protocol"]),
                label: Self.trimmed(child.value) ?? "Chat"
            )
        }

        let contentLinks = node.children(named: "contentLink").compactMap { child -> ContentLink? in
            guard let url = Self.url(
                child.attributes["href"] ?? child.attributes["url"],
                relativeTo: baseURL,
                requireHTTP: true
            ) else { return nil }
            return ContentLink(
                id: url,
                url: url,
                label: Self.trimmed(child.value) ?? Self.trimmed(child.attributes["title"]) ?? "Open Live Page",
                type: Self.trimmed(child.attributes["type"])
            )
        }

        let stableID = guid
            ?? link?.absoluteString
            ?? sources.first?.url.absoluteString
            ?? [title, node.attributes["start"] ?? ""].joined(separator: "|")

        self.id = stableID
        self.guid = guid
        self.title = title
        self.status = Status(rawValue: node.attributes["status"])
        self.start = start
        self.end = end
        self.summary = summary
        self.artworkURL = artworkURL
        self.link = link
        self.streamSources = Self.deduplicated(sources)
        self.chat = chat
        self.contentLinks = contentLinks
    }

    private static func makeSource(
        from node: NamespaceNode,
        baseURL: URL?,
        fallbackMimeType: String? = nil,
        fallbackBitrate: Double? = nil,
        fallbackLanguage: String? = nil,
        fallbackCodec: String? = nil,
        fallbackTitle: String? = nil,
        fallbackDefault: Bool = false
    ) -> StreamSource? {
        guard let url = url(
            node.attributes["uri"] ?? node.attributes["url"] ?? node.attributes["href"],
            relativeTo: baseURL,
            requireHTTP: false
        ) else { return nil }

        return StreamSource(
            url: url,
            mimeType: trimmed(
                node.attributes["contentType"]
                    ?? node.attributes["type"]
                    ?? fallbackMimeType
            ),
            codec: trimmed(node.attributes["codecs"] ?? node.attributes["codec"]) ?? fallbackCodec,
            bitrate: number(node.attributes["bitrate"]) ?? fallbackBitrate,
            language: trimmed(node.attributes["lang"] ?? node.attributes["language"]) ?? fallbackLanguage,
            isDefault: bool(node.attributes["default"]) || fallbackDefault,
            title: trimmed(node.attributes["title"]) ?? fallbackTitle
        )
    }

    private static func deduplicated(_ sources: [StreamSource]) -> [StreamSource] {
        var seen = Set<URL>()
        return sources.filter { seen.insert($0.url).inserted }
    }

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    private static func trimmed(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func bool(_ value: String?) -> Bool {
        ["true", "yes", "1"].contains(value?.lowercased())
    }

    private static func number(_ value: String?) -> Double? {
        guard let value = trimmed(value) else { return nil }
        return Double(value)
    }

    private static func url(_ value: String?, relativeTo baseURL: URL?, requireHTTP: Bool) -> URL? {
        guard let value = trimmed(value), let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        if requireHTTP {
            guard resolved.scheme?.lowercased() == "http" || resolved.scheme?.lowercased() == "https" else {
                return nil
            }
        }
        return resolved
    }

    private static func date(_ value: String?) -> Date? {
        guard let value = trimmed(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) { return date }

        let compactTimeZone = DateFormatter()
        compactTimeZone.locale = Locale(identifier: "en_US_POSIX")
        compactTimeZone.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        if let date = compactTimeZone.date(from: value) { return date }
        compactTimeZone.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return compactTimeZone.date(from: value)
    }
}

private extension NamespaceNode {
    func firstChild(named name: String) -> NamespaceNode? {
        children.first { child in
            child.name.split(separator: ":").last.map(String.init) == name
        }
    }

    func children(named name: String) -> [NamespaceNode] {
        children.filter { child in
            child.name.split(separator: ":").last.map(String.init) == name
        }
    }
}
