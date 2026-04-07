import Foundation

struct NamespaceNode: Codable, Hashable {
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

    private static func localName(from qualifiedName: String) -> String {
        if qualifiedName.hasPrefix("podcast:") {
            return String(qualifiedName.dropFirst("podcast:".count))
        }
        return qualifiedName
    }
}
