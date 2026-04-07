import SwiftUI

struct NamespaceDisplaySection {
    let inlineItems: [NamespaceDisplayItem]
    let fallbackItems: [NamespaceDisplayItem]

    var hasContent: Bool {
        inlineItems.isEmpty == false || fallbackItems.isEmpty == false
    }
}

struct NamespaceDisplayItem: Identifiable {
    let id: String
    let key: String
    let title: String
    let secondaryText: String?
    let links: [URL]
    let detailCount: Int
    let nodes: [NamespaceNode]
}

struct PodcastNamespaceMetadataView: View {
    let optionalTags: PodcastNamespaceOptionalTags?
    @State private var showMoreMetadata: Bool = false

    private var section: NamespaceDisplaySection? {
        NamespaceMetadataMapper.makeSection(from: optionalTags)
    }

    var body: some View {
        if let section, section.hasContent {
            VStack(alignment: .leading, spacing: 12) {
                Text("Podcasting 2.0")
                    .font(.headline)

                if section.inlineItems.isEmpty == false {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(section.inlineItems) { item in
                            NamespaceInlineItemView(item: item)
                        }
                    }
                }

                if section.fallbackItems.isEmpty == false {
                    DisclosureGroup(isExpanded: $showMoreMetadata) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(section.fallbackItems) { item in
                                NamespaceFallbackGroupView(item: item)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("More Metadata")
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(.primary)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
    }
}

private struct NamespaceInlineItemView: View {
    let item: NamespaceDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if item.detailCount > 0 {
                    Text("\(item.detailCount) details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let secondaryText = item.secondaryText, secondaryText.isEmpty == false {
                Text(secondaryText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if item.links.isEmpty == false {
                NamespaceURLRow(urls: item.links)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct NamespaceFallbackGroupView: View {
    let item: NamespaceDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            ForEach(Array(item.nodes.enumerated()), id: \.offset) { index, node in
                NamespaceNodeTreeView(node: node, nodeIDPrefix: "\(item.key)-\(index)")
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct NamespaceNodeTreeView: View {
    let node: NamespaceNode
    let nodeIDPrefix: String
    @State private var isExpanded: Bool = false

    private var title: String {
        NamespaceMetadataMapper.humanizedTagName(from: node.name)
    }

    private var childDetailsCount: Int {
        NamespaceMetadataMapper.descendantCount(of: node.children)
    }

    var body: some View {
        if node.children.isEmpty {
            NamespaceNodeContentView(node: node, title: title)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    NamespaceNodeValueAndAttributesView(node: node)

                    ForEach(Array(node.children.enumerated()), id: \.offset) { index, child in
                        NamespaceNodeTreeView(node: child, nodeIDPrefix: "\(nodeIDPrefix)-\(index)")
                            .padding(.leading, 8)
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text("\(childDetailsCount) details")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.primary)
        }
    }
}

private struct NamespaceNodeContentView: View {
    let node: NamespaceNode
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)

            NamespaceNodeValueAndAttributesView(node: node)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct NamespaceNodeValueAndAttributesView: View {
    let node: NamespaceNode

    private var valueText: String? {
        let trimmedValue = node.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedValue, trimmedValue.isEmpty == false else { return nil }
        return trimmedValue
    }

    private var nonURLAttributes: [(String, String)] {
        node.attributes
            .map { ($0.key, $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { key, value in
                key.isEmpty == false &&
                value.isEmpty == false &&
                NamespaceMetadataMapper.url(from: value) == nil
            }
            .sorted { lhs, rhs in
                lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending
            }
    }

    private var links: [URL] {
        NamespaceMetadataMapper.extractURLs(from: node)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let valueText {
                Text(valueText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if nonURLAttributes.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(nonURLAttributes, id: \.0) { key, value in
                        Text("\(key): \(value)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if links.isEmpty == false {
                NamespaceURLRow(urls: links)
            }
        }
    }
}

private struct NamespaceURLRow: View {
    let urls: [URL]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(urls, id: \.absoluteString) { url in
                    Link(destination: url) {
                        Label(NamespaceMetadataMapper.urlLabel(for: url), systemImage: "link")
                    }
                    .buttonStyle(.glass(.clear))
                }
            }
        }
    }
}

private enum NamespaceMetadataMapper {
    static let integratedTagOrder: [String] = [
        "alternateEnclosure",
        "block",
        "chat",
        "contentLink",
        "episode",
        "image",
        "license",
        "liveItem",
        "location",
        "locked",
        "medium",
        "podroll",
        "publisher",
        "remoteItem",
        "season",
        "soundbite",
        "source",
        "trailer"
    ]

    static let fallbackOnlyTagOrder: [String] = [
        "images",
        "integrity",
        "podping",
        "txt",
        "updateFrequency",
        "value",
        "valueRecipient",
        "valueTimeSplit"
    ]

    static func makeSection(from optionalTags: PodcastNamespaceOptionalTags?) -> NamespaceDisplaySection? {
        guard let optionalTags, optionalTags.isEmpty == false else {
            return nil
        }

        let tagNodes = optionalTags.tagNodesByKey
        var inlineItems: [NamespaceDisplayItem] = []
        var fallbackItems: [NamespaceDisplayItem] = []

        for key in integratedTagOrder {
            guard let nodes = tagNodes[key], nodes.isEmpty == false else { continue }
            for (index, node) in nodes.enumerated() {
                let item = NamespaceDisplayItem(
                    id: "inline-\(key)-\(index)",
                    key: key,
                    title: humanizedTagName(from: key),
                    secondaryText: preferredSecondaryText(from: node),
                    links: extractURLs(from: node),
                    detailCount: descendantCount(of: node.children),
                    nodes: [node]
                )
                inlineItems.append(item)
            }
        }

        for key in fallbackOnlyTagOrder {
            guard let nodes = tagNodes[key], nodes.isEmpty == false else { continue }
            let item = NamespaceDisplayItem(
                id: "fallback-\(key)",
                key: key,
                title: humanizedTagName(from: key),
                secondaryText: nil,
                links: [],
                detailCount: nodes.reduce(0) { $0 + descendantCount(of: $1.children) },
                nodes: nodes
            )
            fallbackItems.append(item)
        }

        // Future-proofing: if parser starts storing new keys, expose them in fallback.
        let knownKeys = Set(integratedTagOrder + fallbackOnlyTagOrder)
        let unknownKeys = tagNodes.keys
            .filter { knownKeys.contains($0) == false }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        for key in unknownKeys {
            guard let nodes = tagNodes[key], nodes.isEmpty == false else { continue }
            let item = NamespaceDisplayItem(
                id: "fallback-unknown-\(key)",
                key: key,
                title: humanizedTagName(from: key),
                secondaryText: nil,
                links: [],
                detailCount: nodes.reduce(0) { $0 + descendantCount(of: $1.children) },
                nodes: nodes
            )
            fallbackItems.append(item)
        }

        let section = NamespaceDisplaySection(inlineItems: inlineItems, fallbackItems: fallbackItems)
        return section.hasContent ? section : nil
    }

    static func preferredSecondaryText(from node: NamespaceNode) -> String? {
        let trimmedValue = node.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedValue, trimmedValue.isEmpty == false {
            return trimmedValue
        }

        let nonURLAttributeValue = node.attributes
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { value in
                value.isEmpty == false && url(from: value) == nil
            }
        return nonURLAttributeValue
    }

    static func extractURLs(from node: NamespaceNode) -> [URL] {
        var candidates: [String] = []
        if let value = node.value {
            candidates.append(value)
        }
        candidates.append(contentsOf: node.attributes.values)

        var uniqueURLs: [URL] = []
        var seen = Set<String>()

        for candidate in candidates {
            guard let url = url(from: candidate) else { continue }
            let key = url.absoluteString
            if seen.insert(key).inserted {
                uniqueURLs.append(url)
            }
        }
        return uniqueURLs
    }

    static func url(from text: String) -> URL? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty == false, let url = URL(string: candidate), let scheme = url.scheme else {
            return nil
        }

        let lowerScheme = scheme.lowercased()
        if lowerScheme == "http" || lowerScheme == "https" {
            return url.host?.isEmpty == false ? url : nil
        }

        // Accept well-formed custom scheme URLs with an endpoint-like part.
        if url.host?.isEmpty == false {
            return url
        }

        if lowerScheme == "mailto" || lowerScheme == "tel" {
            return url
        }

        return url.path.isEmpty == false ? url : nil
    }

    static func humanizedTagName(from qualifiedTag: String) -> String {
        let localName = localTagName(from: qualifiedTag)
        let withSpaces = localName
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        guard withSpaces.isEmpty == false else { return "Metadata" }
        return withSpaces.prefix(1).uppercased() + withSpaces.dropFirst()
    }

    static func localTagName(from qualifiedTag: String) -> String {
        if qualifiedTag.hasPrefix("podcast:") {
            return String(qualifiedTag.dropFirst("podcast:".count))
        }
        return qualifiedTag
    }

    static func descendantCount(of nodes: [NamespaceNode]) -> Int {
        nodes.reduce(0) { partialResult, node in
            partialResult + 1 + descendantCount(of: node.children)
        }
    }

    static func urlLabel(for url: URL) -> String {
        if let host = url.host, host.isEmpty == false {
            return host
        }
        return url.absoluteString
    }
}

private extension PodcastNamespaceOptionalTags {
    var tagNodesByKey: [String: [NamespaceNode]] {
        var values: [String: [NamespaceNode]] = [:]

        func assign(_ key: String, _ nodes: [NamespaceNode]?) {
            guard let nodes, nodes.isEmpty == false else { return }
            values[key] = nodes
        }

        assign("alternateEnclosure", alternateEnclosure)
        assign("block", block)
        assign("chat", chat)
        assign("contentLink", contentLink)
        assign("episode", episode)
        assign("image", image)
        assign("images", images)
        assign("integrity", integrity)
        assign("license", license)
        assign("liveItem", liveItem)
        assign("location", location)
        assign("locked", locked)
        assign("medium", medium)
        assign("podping", podping)
        assign("podroll", podroll)
        assign("publisher", publisher)
        assign("remoteItem", remoteItem)
        assign("season", season)
        assign("soundbite", soundbite)
        assign("source", source)
        assign("trailer", trailer)
        assign("txt", txt)
        assign("updateFrequency", updateFrequency)
        assign("value", value)
        assign("valueRecipient", valueRecipient)
        assign("valueTimeSplit", valueTimeSplit)

        return values
    }
}

#Preview("Namespace Inline Only") {
    ScrollView {
        PodcastNamespaceMetadataView(optionalTags: NamespacePreviewData.inlineOnly)
            .padding()
    }
}

#Preview("Namespace Fallback Only") {
    ScrollView {
        PodcastNamespaceMetadataView(optionalTags: NamespacePreviewData.fallbackOnly)
            .padding()
    }
}

#Preview("Namespace Mixed + Nested") {
    ScrollView {
        PodcastNamespaceMetadataView(optionalTags: NamespacePreviewData.mixedNested)
            .padding()
    }
}

private enum NamespacePreviewData {
    static var inlineOnly: PodcastNamespaceOptionalTags {
        var tags = PodcastNamespaceOptionalTags.empty
        tags.alternateEnclosure = [NamespaceNode(name: "podcast:alternateEnclosure", attributes: ["type": "audio/mpeg", "length": "123456", "default": "true"])]
        tags.block = [NamespaceNode(name: "podcast:block", value: "yes")]
        tags.medium = [NamespaceNode(name: "podcast:medium", value: "music")]
        tags.trailer = [NamespaceNode(name: "podcast:trailer", attributes: ["url": "https://example.com/trailer.mp3"])]
        return tags
    }

    static var fallbackOnly: PodcastNamespaceOptionalTags {
        var tags = PodcastNamespaceOptionalTags.empty
        tags.value = [
            NamespaceNode(
                name: "podcast:value",
                attributes: ["type": "lightning", "method": "keysend"],
                children: [
                    NamespaceNode(
                        name: "podcast:valueRecipient",
                        attributes: ["name": "Host", "address": "03abc", "split": "95"]
                    ),
                    NamespaceNode(
                        name: "podcast:valueRecipient",
                        attributes: ["name": "Producer", "address": "03def", "split": "5"]
                    )
                ]
            )
        ]
        tags.updateFrequency = [NamespaceNode(name: "podcast:updateFrequency", value: "weekly")]
        tags.txt = [NamespaceNode(name: "podcast:txt", value: "verify=abcd-1234")]
        return tags
    }

    static var mixedNested: PodcastNamespaceOptionalTags {
        var tags = PodcastNamespaceOptionalTags.empty
        tags.chat = [NamespaceNode(name: "podcast:chat", attributes: ["url": "https://chat.example.com", "protocol": "irc"])]
        tags.license = [NamespaceNode(name: "podcast:license", value: "CC-BY-4.0")]
        tags.liveItem = [
            NamespaceNode(
                name: "podcast:liveItem",
                attributes: ["status": "pending"],
                children: [
                    NamespaceNode(name: "podcast:start", value: "2026-04-07T20:00:00Z"),
                    NamespaceNode(name: "podcast:end", value: "2026-04-07T22:00:00Z"),
                    NamespaceNode(name: "podcast:contentLink", attributes: ["href": "https://example.com/live"])
                ]
            )
        ]
        tags.valueTimeSplit = [NamespaceNode(name: "podcast:valueTimeSplit", attributes: ["startTime": "600", "remotePercentage": "10"])]
        tags.integrity = [NamespaceNode(name: "podcast:integrity", attributes: ["type": "sha256", "value": "abcdef123456"])]
        return tags
    }
}

private extension PodcastNamespaceOptionalTags {
    static var empty: PodcastNamespaceOptionalTags {
        PodcastNamespaceOptionalTags(
            alternateEnclosure: nil,
            block: nil,
            chat: nil,
            contentLink: nil,
            episode: nil,
            image: nil,
            images: nil,
            integrity: nil,
            license: nil,
            liveItem: nil,
            location: nil,
            locked: nil,
            medium: nil,
            podping: nil,
            podroll: nil,
            publisher: nil,
            remoteItem: nil,
            season: nil,
            soundbite: nil,
            source: nil,
            trailer: nil,
            txt: nil,
            updateFrequency: nil,
            value: nil,
            valueRecipient: nil,
            valueTimeSplit: nil
        )
    }
}
