import SwiftUI

struct NamespaceDisplaySection {
    let summaryItems: [NamespaceDisplayItem]
    let detailItems: [NamespaceDisplayItem]

    var hasContent: Bool {
        summaryItems.isEmpty == false || detailItems.isEmpty == false
    }

    var hasDetails: Bool {
        detailItems.isEmpty == false
    }
}

struct NamespaceDisplayItem: Identifiable {
    let id: String
    let key: String
    let title: String
    let iconName: String
    let secondaryText: String?
    let links: [URL]
    let detailCount: Int
    let nodes: [NamespaceNode]

    var displayText: String {
        if let secondaryText = secondaryText?.trimmingCharacters(in: .whitespacesAndNewlines),
           secondaryText.isEmpty == false {
            return secondaryText
        }
        return title
    }

    var accessibilityLabel: String {
        links.isEmpty ? displayText : "\(displayText), opens link"
    }
}

private extension NamespaceNode {
    func childValue(named localName: String) -> String? {
        children.first { NamespaceMetadataMapper.localTagName(from: $0.name) == localName }?.value
    }
}

struct PodcastValueSplitView: View {
    let optionalTags: PodcastNamespaceOptionalTags?
    let funding: [FundingInfo]

    private var blocks: [PodcastValueBlock] {
        PodcastValueBlock.blocks(from: optionalTags)
    }

    var body: some View {
        if blocks.isEmpty == false {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks) { block in
                    PodcastValueBlockView(block: block, funding: funding)
                }
            }
        }
    }
}

private struct PodcastValueBlockView: View {
    let block: PodcastValueBlock
    let funding: [FundingInfo]

    private var subtitle: String {
        let method = [block.type, block.method]
            .compactMap { value -> String? in
                guard let value, value.isEmpty == false else { return nil }
                return NamespaceMetadataMapper.humanizedTagName(from: value)
            }
            .joined(separator: " • ")

        if let suggested = block.suggested, suggested.isEmpty == false {
            return method.isEmpty ? "Suggested \(suggested)" : "\(method) • Suggested \(suggested)"
        }

        return method.isEmpty ? "Streaming value split" : method
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
               
                Spacer(minLength: 8)
                PodcastValuePaymentAction(funding: funding)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            PodcastValueSegmentedBar(recipients: block.recipients)
                .frame(height: 8)
                .clipShape(Capsule())

            FlowRows(spacing: 6) {
                ForEach(block.recipients) { recipient in
                    PodcastValueRecipientLegend(recipient: recipient)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct PodcastValuePaymentAction: View {
    let funding: [FundingInfo]

    var body: some View {
        if funding.count == 1, let fund = funding.first {
            Link(destination: fund.url) {
                Label(fund.label, systemImage: "bolt.heart")
                    .labelStyle(.titleAndIcon)
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.glass(.clear))
        } else if funding.count > 1 {
            Menu {
                ForEach(funding) { fund in
                    Link(destination: fund.url) {
                        Label(fund.label, systemImage: "bolt.heart")
                    }
                }
            } label: {
                Label("Support", systemImage: "bolt.heart")
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.glass(.clear))
        }
    }
}

private struct PodcastValueSegmentedBar: View {
    let recipients: [PodcastValueRecipient]

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(recipients) { recipient in
                    Capsule()
                        .fill(recipient.color)
                        .frame(width: max(proxy.size.width * recipient.percentage, 2))
                }
            }
        }
        .background(.quaternary, in: Capsule())
    }
}

private struct PodcastValueRecipientLegend: View {
    let recipient: PodcastValueRecipient

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(recipient.color)
                .frame(width: 7, height: 7)

            Text(recipient.legendText)
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .accessibilityLabel(recipient.accessibilityText)
    }
}

private struct PodcastValueBlock: Identifiable {
    let id: String
    let type: String?
    let method: String?
    let suggested: String?
    let recipients: [PodcastValueRecipient]

    static func blocks(from optionalTags: PodcastNamespaceOptionalTags?) -> [PodcastValueBlock] {
        guard let nodes = optionalTags?.value else { return [] }
        return blocks(from: nodes)
    }

    static func blocks(from nodes: [NamespaceNode]) -> [PodcastValueBlock] {
        nodes.enumerated().compactMap { index, node in
            block(from: node, index: index)
        }
    }

    static func isRenderable(_ node: NamespaceNode) -> Bool {
        block(from: node, index: 0) != nil
    }

    private static func block(from node: NamespaceNode, index: Int) -> PodcastValueBlock? {
        let recipientNodes = node.children.filter {
            NamespaceMetadataMapper.localTagName(from: $0.name) == "valueRecipient"
        }

        guard recipientNodes.isEmpty == false else { return nil }

        let parsedRecipients = recipientNodes.enumerated().compactMap { recipientIndex, node -> ParsedPodcastValueRecipient? in
            let rawSplit = node.attributes["split"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let split = rawSplit.flatMap(Double.init)

            if recipientNodes.count == 1, split == nil {
                return ParsedPodcastValueRecipient(node: node, index: recipientIndex, split: 100)
            }

            guard let split, split > 0 else { return nil }
            return ParsedPodcastValueRecipient(node: node, index: recipientIndex, split: split)
        }

        let totalSplit = parsedRecipients.reduce(0) { $0 + $1.split }
        guard totalSplit > 0 else { return nil }

        let recipients = parsedRecipients.map { parsed in
            PodcastValueRecipient(
                index: parsed.index,
                name: parsed.name,
                split: parsed.split,
                percentage: parsed.split / totalSplit,
                isFee: parsed.isFee
            )
        }

        return PodcastValueBlock(
            id: "value-\(index)",
            type: trimmed(node.attributes["type"]),
            method: trimmed(node.attributes["method"]),
            suggested: trimmed(node.attributes["suggested"]),
            recipients: recipients
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private struct ParsedPodcastValueRecipient {
    let node: NamespaceNode
    let index: Int
    let split: Double

    var name: String {
        let trimmed = node.attributes["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false else {
            return "Recipient \(index + 1)"
        }
        return trimmed
    }

    var isFee: Bool {
        switch node.attributes["fee"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1":
            return true
        default:
            return false
        }
    }
}

private struct PodcastValueRecipient: Identifiable {
    let id: Int
    let name: String
    let split: Double
    let percentage: Double
    let isFee: Bool

    init(index: Int, name: String, split: Double, percentage: Double, isFee: Bool) {
        self.id = index
        self.name = name
        self.split = split
        self.percentage = percentage
        self.isFee = isFee
    }

    var color: Color {
        let palette: [Color] = [.accentColor, .green, .orange, .pink, .cyan, .indigo, .teal]
        return palette[id % palette.count]
    }

    var legendText: String {
        let feeText = isFee ? " Fee" : ""
        return "\(name)\(feeText) \(percentageText)"
    }

    var accessibilityText: String {
        let feeText = isFee ? " fee" : ""
        return "\(name)\(feeText), \(percentageText) of value split"
    }

    private var percentageText: String {
        percentage.formatted(.percent.precision(.fractionLength(0...1)))
    }
}

struct PodcastNamespaceMetadataView: View {
    let optionalTags: PodcastNamespaceOptionalTags?
    var title: String = "Metadata"
    var hidesRenderableValueBlocks: Bool = false
    @State private var showDetails = false

    private var section: NamespaceDisplaySection? {
        NamespaceMetadataMapper.makeSection(
            from: optionalTags,
            hidesRenderableValueBlocks: hidesRenderableValueBlocks
        )
    }

    var body: some View {
        if let section, section.hasContent {
            VStack(alignment: .leading, spacing: 10) {
                if section.summaryItems.isEmpty == false {
                    FlowRows(spacing: 8) {
                        ForEach(section.summaryItems) { item in
                            NamespaceInlineItemView(item: item)
                        }
                    }
                }

                if section.hasDetails {
                    Button {
                        showDetails = true
                    } label: {
                        Label("Metadata Details", systemImage: "info.circle")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.glass(.clear))
                    .sheet(isPresented: $showDetails) {
                        NavigationStack {
                            PodcastNamespaceMetadataDetailView(title: title, items: section.detailItems)
                        }
                    }
                }
            }
            .padding()
            
        }
    }
}

private struct PodcastNamespaceMetadataDetailView: View {
    let title: String
    let items: [NamespaceDisplayItem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(items) { item in
                    NamespaceFallbackGroupView(item: item)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NamespaceInlineItemView: View {
    let item: NamespaceDisplayItem

    var body: some View {
        if let destination = item.links.first {
            Link(destination: destination) {
                NamespaceChipContent(item: item, showsLinkIcon: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.accessibilityLabel)
       //     .background(.ultraThinMaterial, in: Capsule())
        } else {
            NamespaceChipContent(item: item, showsLinkIcon: false)
                .accessibilityLabel(item.accessibilityLabel)
        }
    }
}

private struct NamespaceFallbackGroupView: View {
    let item: NamespaceDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.title, systemImage: item.iconName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)

            ForEach(Array(item.nodes.enumerated()), id: \.offset) { index, node in
                NamespaceNodeTreeView(node: node, nodeIDPrefix: "\(item.key)-\(index)")
            }
        }
       
    }
}

private struct NamespaceChipContent: View {
    let item: NamespaceDisplayItem
    let showsLinkIcon: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.iconName)
                .imageScale(.small)
                .foregroundStyle(.secondary)

            Text(item.displayText)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(1)

            if showsLinkIcon {
                Image(systemName: "link")
                    .imageScale(.small)
                    .foregroundStyle(.tint)
            }

            if item.links.count > 1 {
                Text("+\(item.links.count - 1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
      //  .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct NamespaceNodeTreeView: View {
    let node: NamespaceNode
    let nodeIDPrefix: String
    @State private var isExpanded: Bool = false

    private var title: String {
        NamespaceMetadataMapper.compactTitle(for: node.name)
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
        VStack(alignment: .leading, spacing: 4) {
            if title.isEmpty == false {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            NamespaceNodeValueAndAttributesView(node: node)
        }
        
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
                NamespaceMetadataMapper.isLowValueAttribute(key) == false &&
                NamespaceMetadataMapper.url(from: value) == nil
            }
            .sorted { lhs, rhs in
                lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending
            }
    }

    private var links: [URL] {
        NamespaceMetadataMapper.extractURLs(from: node)
    }

    private var linkLabel: String {
        NamespaceMetadataMapper.linkButtonLabel(forTag: node.name)
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
                FlowRows(spacing: 6) {
                    ForEach(Array(nonURLAttributes.enumerated()), id: \.offset) { _, item in
                        NamespaceAttributePill(key: item.0, value: item.1)
                    }
                }
            }

            if links.isEmpty == false {
                NamespaceURLRow(urls: links, baseLabel: linkLabel)
            }
        }
    }
}

private struct NamespaceAttributePill: View {
    let key: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: NamespaceMetadataMapper.iconName(forAttribute: key))
                .imageScale(.small)
            Text(NamespaceMetadataMapper.attributeDisplayText(key: key, value: value))
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .textSelection(.enabled)
    }
}

private struct NamespaceURLRow: View {
    let urls: [URL]
    let baseLabel: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(urls.enumerated()), id: \.element.absoluteString) { index, url in
                    Link(destination: url) {
                        Label {
                            if urls.count > 1 {
                                Text("\(index + 1)")
                            }
                        } icon: {
                            Image(systemName: "link")
                        }
                    }
                    .buttonStyle(.glass(.clear))
                    .accessibilityLabel(url.host(percentEncoded: false) ?? baseLabel)
                }
            }
        }
    }
}

private enum NamespaceMetadataMapper {
    static let summaryTagOrder: [String] = [
        "chat",
        "contentLink",
        "season",
        "episode",
        "image",
        "license",
        "liveItem",
        "location",
        "podroll",
        "publisher",
    
        "soundbite",
        
        "trailer"
    ]

    static let detailOnlyTagOrder: [String] = [
        "remoteItem",
        "alternateEnclosure",
        "source",
        "block",
        "medium",
        "images",
        "integrity",
        "podping",
        "txt",
        "updateFrequency",
        "value",
        "valueRecipient",
        "valueTimeSplit"
        
    ]

    static func makeSection(
        from optionalTags: PodcastNamespaceOptionalTags?,
        hidesRenderableValueBlocks: Bool = false
    ) -> NamespaceDisplaySection? {
        guard let optionalTags, optionalTags.isEmpty == false else {
            return nil
        }

        let tagNodes = optionalTags.tagNodesByKey
        var rawSummaryItems: [NamespaceDisplayItem] = []
        var rawDetailItems: [NamespaceDisplayItem] = []

        for key in summaryTagOrder {
            guard let nodes = tagNodes[key], nodes.isEmpty == false else { continue }
            for (index, node) in nodes.enumerated() {
                guard let item = summaryItem(for: node, key: key, index: index) else { continue }
                rawSummaryItems.append(item)
            }
        }

        for key in orderedDetailKeys(from: tagNodes) {
            guard let nodes = tagNodes[key], nodes.isEmpty == false else { continue }
            let item = NamespaceDisplayItem(
                id: "detail-\(key)",
                key: key,
                title: compactTitle(for: key),
                iconName: iconName(forTag: key),
                secondaryText: nil,
                links: [],
                detailCount: nodes.reduce(0) { $0 + descendantCount(of: $1.children) },
                nodes: nodes
            )
            rawDetailItems.append(item)
        }

        let summaryItems = mergedItems(rawSummaryItems, idPrefix: "summary")
        let detailItems = mergedItems(rawDetailItems, idPrefix: "detail")
        let section = NamespaceDisplaySection(summaryItems: summaryItems, detailItems: detailItems)
        return section.hasContent ? section : nil
    }

    private static func summaryItem(for node: NamespaceNode, key: String, index: Int) -> NamespaceDisplayItem? {
        if key == "value", PodcastValueBlock.isRenderable(node) {
            return nil
        }

        let secondaryText = preferredSecondaryText(from: node, key: key)
        let links = extractURLs(from: node)
        let hasText = secondaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard links.isEmpty == false || hasText else {
            return nil
        }

        return NamespaceDisplayItem(
            id: "summary-\(key)-\(index)",
            key: key,
            title: compactTitle(for: key),
            iconName: iconName(forTag: key),
            secondaryText: secondaryText,
            links: links,
            detailCount: descendantCount(of: node.children),
            nodes: [node]
        )
    }

    private static func orderedDetailKeys(from tagNodes: [String: [NamespaceNode]]) -> [String] {
        let preferredOrder = summaryTagOrder + detailOnlyTagOrder
        var orderedKeys: [String] = []
        var seen = Set<String>()

        for key in preferredOrder where tagNodes[key]?.isEmpty == false {
            if seen.insert(key).inserted {
                orderedKeys.append(key)
            }
        }

        let unknownKeys = tagNodes.keys
            .filter { seen.contains($0) == false }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return orderedKeys + unknownKeys
    }

    static func preferredSecondaryText(from node: NamespaceNode, key: String? = nil) -> String? {
        let localKey = key.map(localTagName) ?? localTagName(from: node.name)

        switch localKey {
        case "episode":
            return joinedValues([
                labeledValue("Episode", node.attributes["number"] ?? node.value),
                labeledValue("Season", node.attributes["season"])
                
                ,
                humanizedValue(node.attributes["display"] ?? node.attributes["type"])
                 
            ])
        case "season":
            return joinedValues([
                labeledValue("Season", node.value ?? node.attributes["number"]),
                node.attributes["name"]
            ])
        case "license":
            return node.value ?? node.attributes["name"] ?? node.attributes["type"]
        case "location":
            return node.value ?? node.attributes["name"] ?? node.attributes["geo"]
        case "medium":
            return humanizedValue(node.value ?? node.attributes["type"])
        case "block":
            return booleanText(node.value)
        case "liveItem":
            return joinedValues([
                humanizedValue(node.attributes["status"]),
                node.childValue(named: "start").flatMap(shortDateText),
                node.childValue(named: "end").flatMap(shortDateText)
            ])
        case "trailer":
            return joinedValues([
                node.value,
                labeledValue("Season", node.attributes["season"]),
                node.attributes["pubdate"].flatMap(shortDateText)
            ])
        case "soundbite":
            return joinedValues([
                secondsText(node.attributes["startTime"]),
                durationText(node.attributes["duration"])
            ])
        case "alternateEnclosure":
            return joinedValues([
                mediaTypeText(node.attributes["type"]),
                byteCountText(node.attributes["length"]),
                node.attributes["bitrate"].flatMap { "\($0) bps" }
            ])
        case "publisher":
            return node.value ?? node.attributes["name"] ?? node.attributes["guid"]
        case "remoteItem":
            return joinedValues([
                node.attributes["title"],
                humanizedValue(node.attributes["medium"]),
                shortenedIdentifier(node.attributes["feedGuid"]),
                shortenedIdentifier(node.attributes["itemGuid"])
            ])
        case "chat":
            return joinedValues([
                humanizedValue(node.attributes["protocol"]),
                node.attributes["accountId"]
            ])
        case "contentLink", "source":
            return joinedValues([
                humanizedValue(node.attributes["rel"]),
                mediaTypeText(node.attributes["type"] ?? node.attributes["contentType"])
            ])
        case "image", "images":
            return mediaTypeText(node.attributes["type"]) ?? "Artwork"
        case "podroll":
            let count = max(node.children.count, 1)
            return count == 1 ? "Recommended show" : "\(count) recommended shows"
        default:
            break
        }

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

    static func compactTitle(for qualifiedTag: String) -> String {
        switch localTagName(from: qualifiedTag) {
        case "episode":
            return "Episode"
        case "season":
            return "Season"
        case "chat":
            return "Chat"
        case "contentLink":
            return "Notes"
        case "source":
            return "Source"
        case "remoteItem":
            return "Related"
        case "podroll":
            return "Podroll"
        case "alternateEnclosure":
            return "Alternate Audio"
        case "soundbite":
            return "Soundbite"
        case "trailer":
            return "Trailer"
        case "liveItem":
            return "Live"
        case "image", "images":
            return "Artwork"
        case "value":
            return "Value"
        case "valueRecipient":
            return "Recipient"
        case "valueTimeSplit":
            return "Split"
        case "block", "podping", "updateFrequency":
            return "Feed"
        case "medium":
            return "Medium"
        case "license", "integrity", "txt":
            return "Policy"
        case "location":
            return "Location"
        case "publisher":
            return "Publisher"
        default:
            return humanizedTagName(from: qualifiedTag)
        }
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

    static func linkButtonLabel(forTag qualifiedTag: String) -> String {
        "\(compactTitle(for: qualifiedTag))"
    }

    static func iconName(forTag qualifiedTag: String) -> String {
        switch localTagName(from: qualifiedTag) {
        case "alternateEnclosure", "source":
            return "waveform"
        case "block":
            return "eye.slash"
        case "chat":
            return "bubble.left.and.bubble.right"
        case "contentLink":
            return "doc.text"
        case "episode":
            return "number"
        case "image", "images":
            return "photo"
        case "integrity":
            return "checkmark.shield"
        case "license":
            return "doc.badge.gearshape"
        case "liveItem":
            return "dot.radiowaves.left.and.right"
        case "location":
            return "mappin.and.ellipse"
        case "medium":
            return "rectangle.stack"
        case "podping", "updateFrequency":
            return "arrow.triangle.2.circlepath"
        case "podroll", "remoteItem":
            return "rectangle.connected.to.line.below"
        case "publisher":
            return "building.2"
        case "season":
            return "square.stack.3d.up"
        case "soundbite":
            return "waveform.badge.magnifyingglass"
        case "trailer":
            return "play.rectangle"
        case "txt":
            return "text.badge.checkmark"
        case "value", "valueRecipient", "valueTimeSplit":
            return "bolt.circle"
        default:
            return "info.circle"
        }
    }

    static func shortAttributeLabel(for key: String) -> String {
        switch key.lowercased() {
        case "href", "url", "uri":
            return ""
        case "feedguid":
            return "Feed"
        case "itemguid":
            return "Item"
        case "accountid":
            return "Account"
        case "starttime":
            return "Start"
        case "endtime":
            return "End"
        case "remotepercentage":
            return "Split"
        default:
            return humanizedTagName(from: key)
        }
    }

    static func iconName(forAttribute key: String) -> String {
        switch key.lowercased() {
        case "type", "contenttype", "medium", "protocol", "method":
            return "tag"
        case "length", "duration", "starttime", "endtime":
            return "timer"
        case "season", "number":
            return "number"
        case "owner", "accountid", "name":
            return "person"
        case "split", "remotepercentage", "suggested":
            return "percent"
        case "feedguid", "itemguid", "guid", "address":
            return "number.square"
        case "status", "default", "complete", "usespodping":
            return "checkmark.circle"
        default:
            return "info.circle"
        }
    }

    static func attributeDisplayText(key: String, value: String) -> String {
        switch key.lowercased() {
        case "type", "contenttype":
            return mediaTypeText(value) ?? value
        case "duration":
            return durationText(value) ?? value
        case "starttime":
            return secondsText(value) ?? value
        case "length":
            return byteCountText(value) ?? value
        case "feedguid", "itemguid", "guid", "address":
            return shortenedIdentifier(value) ?? value
        case "default", "complete", "usespodping":
            return "\(humanizedTagName(from: key)): \(booleanText(value) ?? value)"
        default:
            let label = shortAttributeLabel(for: key)
            return label.isEmpty ? value : "\(label): \(value)"
        }
    }

    static func isLowValueAttribute(_ key: String) -> Bool {
        switch key.lowercased() {
        case "href", "url", "uri", "feedurl", "accounturl":
            return true
        default:
            return false
        }
    }

    static func joinedValues(_ values: [String?]) -> String? {
        let compacted = values.compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        return compacted.isEmpty ? nil : compacted.joined(separator: " • ")
    }

    static func labeledValue(_ label: String, _ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else {
            return nil
        }
        return "\(label) \(value)"
    }

    static func humanizedValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else {
            return nil
        }
        return humanizedTagName(from: value)
    }

    static func booleanText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), value.isEmpty == false else {
            return nil
        }
        switch value {
        case "yes", "true", "1":
            return "Yes"
        case "no", "false", "0":
            return "No"
        default:
            return nil
        }
    }

    static func mediaTypeText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else {
            return nil
        }
        if value.contains("/") {
            return value
                .split(separator: "/")
                .last
                .map(String.init)?
                .uppercased()
        }
        return humanizedTagName(from: value)
    }

    static func byteCountText(_ value: String?) -> String? {
        guard let value, let bytes = Int64(value) else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func secondsText(_ value: String?) -> String? {
        guard let value, let seconds = Double(value) else { return nil }
        return Duration.seconds(seconds).formatted(.units(width: .narrow))
    }

    static func durationText(_ value: String?) -> String? {
        secondsText(value)
    }

    static func shortDateText(_ value: String?) -> String? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return value
    }

    static func shortenedIdentifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else {
            return nil
        }
        guard value.count > 14 else { return value }
        return "\(value.prefix(6))...\(value.suffix(4))"
    }

    private static func mergedItems(_ items: [NamespaceDisplayItem], idPrefix: String) -> [NamespaceDisplayItem] {
        guard items.isEmpty == false else { return [] }

        var order: [String] = []
        var grouped: [String: [NamespaceDisplayItem]] = [:]

        for item in items {
            if grouped[item.title] == nil {
                order.append(item.title)
            }
            grouped[item.title, default: []].append(item)
        }

        return order.compactMap { title in
            guard let bucket = grouped[title], bucket.isEmpty == false else { return nil }
            return NamespaceDisplayItem(
                id: "\(idPrefix)-\(slug(from: title))",
                key: bucket.map(\.key).joined(separator: ","),
                title: title,
                iconName: bucket.first?.iconName ?? "info.circle",
                secondaryText: mergedSecondaryText(from: bucket),
                links: uniqueURLs(from: bucket.flatMap(\.links)),
                detailCount: bucket.reduce(0) { $0 + $1.detailCount },
                nodes: bucket.flatMap(\.nodes)
            )
        }
    }

    private static func mergedSecondaryText(from items: [NamespaceDisplayItem]) -> String? {
        var values: [String] = []
        var seen = Set<String>()

        for item in items {
            guard let secondaryText = item.secondaryText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  secondaryText.isEmpty == false else { continue }
            if seen.insert(secondaryText).inserted {
                values.append(secondaryText)
            }
        }

        guard values.isEmpty == false else { return nil }
        if values.count <= 2 {
            return values.joined(separator: " • ")
        }
        let visible = values.prefix(2).joined(separator: " • ")
        return "\(visible) +\(values.count - 2)"
    }

    private static func uniqueURLs(from urls: [URL]) -> [URL] {
        var unique: [URL] = []
        var seen = Set<String>()
        for url in urls {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                unique.append(url)
            }
        }
        return unique
    }

    private static func slug(from text: String) -> String {
        let lowercased = text.lowercased()
        return lowercased.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
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
    NavigationStack {
        ScrollView {
            PodcastNamespaceMetadataView(optionalTags: NamespacePreviewData.inlineOnly)
                .padding()
        }
    }
}

#Preview("Namespace Technical Details Only") {
    NavigationStack {
        ScrollView {
            PodcastNamespaceMetadataView(optionalTags: NamespacePreviewData.technicalOnly)
                .padding()
        }
    }
}

#Preview("Namespace Mixed + Nested") {
    NavigationStack {
        ScrollView {
            PodcastNamespaceMetadataView(optionalTags: NamespacePreviewData.mixedNested)
                .padding()
        }
    }
}

#Preview("Namespace Everything (All Tags)") {
    NavigationStack {
        ScrollView {
            PodcastNamespaceMetadataView(optionalTags: NamespacePreviewData.allInOne)
                .padding()
        }
    }
}

#Preview("Value Split With Metadata Details") {
    NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PodcastValueSplitView(optionalTags: NamespacePreviewData.fallbackOnly, funding: NamespacePreviewData.previewFunding)
                PodcastNamespaceMetadataView(
                    optionalTags: NamespacePreviewData.fallbackOnly,
                    title: "Podcast Metadata",
                    hidesRenderableValueBlocks: true
                )
            }
            .padding()
        }
    }
}

#Preview("Value Split Single") {
    PodcastValueSplitView(optionalTags: NamespacePreviewData.valueSplitSingle, funding: NamespacePreviewData.previewFunding)
        .padding()
}

#Preview("Value Split 80/20") {
    PodcastValueSplitView(optionalTags: NamespacePreviewData.valueSplitEightyTwenty, funding: NamespacePreviewData.previewFunding)
        .padding()
}

#Preview("Value Split Shares") {
    PodcastValueSplitView(optionalTags: NamespacePreviewData.valueSplitWeightedShares, funding: NamespacePreviewData.previewFunding)
        .padding()
}

#Preview("Value Split Fee") {
    PodcastValueSplitView(optionalTags: NamespacePreviewData.valueSplitWithFee, funding: NamespacePreviewData.previewFunding)
        .padding()
}

#Preview("Value Split No Funding") {
    PodcastValueSplitView(optionalTags: NamespacePreviewData.valueSplitEightyTwenty, funding: [])
        .padding()
}

private enum NamespacePreviewData {
    static var previewFunding: [FundingInfo] {
        [
            FundingInfo(url: URL(string: "https://example.com/support")!, label: "Support"),
            FundingInfo(url: URL(string: "https://example.com/membership")!, label: "Membership")
        ]
    }

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

    static var technicalOnly: PodcastNamespaceOptionalTags {
        var tags = PodcastNamespaceOptionalTags.empty
        tags.block = [NamespaceNode(name: "podcast:block", value: "yes")]
        tags.medium = [NamespaceNode(name: "podcast:medium", value: "podcast")]
        tags.integrity = [
            NamespaceNode(
                name: "podcast:integrity",
                attributes: ["type": "sri", "value": "sha384-preview"]
            )
        ]
        tags.podping = [NamespaceNode(name: "podcast:podping", attributes: ["usesPodping": "true"])]
        tags.txt = [NamespaceNode(name: "podcast:txt", value: "verify=abcd-1234")]
        tags.updateFrequency = [NamespaceNode(name: "podcast:updateFrequency", value: "weekly")]
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

    static var allInOne: PodcastNamespaceOptionalTags {
        var tags = PodcastNamespaceOptionalTags.empty

        tags.alternateEnclosure = [
            NamespaceNode(
                name: "podcast:alternateEnclosure",
                attributes: [
                    "type": "audio/flac",
                    "length": "7340032",
                    "default": "true",
                    "bitrate": "320000"
                ],
                children: [
                    NamespaceNode(
                        name: "podcast:source",
                        attributes: ["uri": "https://cdn.example.com/episodes/42.flac"]
                    ),
                    NamespaceNode(
                        name: "podcast:integrity",
                        attributes: ["type": "sha256", "value": "c0ffee0123456789"]
                    )
                ]
            )
        ]
        tags.block = [NamespaceNode(name: "podcast:block", value: "no")]
        tags.chat = [
            NamespaceNode(
                name: "podcast:chat",
                attributes: [
                    "url": "https://chat.example.com/rooms/preview",
                    "protocol": "irc",
                    "accountId": "@previewshow"
                ]
            )
        ]
        tags.contentLink = [
            NamespaceNode(
                name: "podcast:contentLink",
                attributes: [
                    "href": "https://example.com/episodes/42/shownotes",
                    "type": "text/html",
                    "rel": "shownotes"
                ]
            )
        ]
        tags.episode = [
            NamespaceNode(
                name: "podcast:episode",
                attributes: [
                    "number": "42",
                    "season": "4",
                    "display": "full"
                ]
            )
        ]
        tags.image = [
            NamespaceNode(
                name: "podcast:image",
                attributes: [
                    "href": "https://picsum.photos/id/1025/1200/1200",
                    "type": "image/jpeg"
                ]
            )
        ]
        tags.images = [
            NamespaceNode(
                name: "podcast:images",
                children: [
                    NamespaceNode(
                        name: "podcast:image",
                        attributes: ["href": "https://picsum.photos/id/1062/2000/2000"]
                    ),
                    NamespaceNode(
                        name: "podcast:image",
                        attributes: ["href": "https://picsum.photos/id/1062/1000/1000"]
                    )
                ]
            )
        ]
        tags.integrity = [
            NamespaceNode(
                name: "podcast:integrity",
                attributes: ["type": "sha256", "value": "abcdef1234567890abcdef1234567890"]
            )
        ]
        tags.license = [
            NamespaceNode(
                name: "podcast:license",
                value: "CC-BY-4.0",
                attributes: ["url": "https://creativecommons.org/licenses/by/4.0/"]
            )
        ]
        tags.liveItem = [
            NamespaceNode(
                name: "podcast:liveItem",
                attributes: ["status": "live"],
                children: [
                    NamespaceNode(name: "podcast:start", value: "2026-04-07T20:00:00Z"),
                    NamespaceNode(name: "podcast:end", value: "2026-04-07T22:00:00Z"),
                    NamespaceNode(
                        name: "podcast:contentLink",
                        attributes: ["href": "https://example.com/live/42"]
                    )
                ]
            )
        ]
        tags.location = [
            NamespaceNode(
                name: "podcast:location",
                value: "Berlin, Germany",
                attributes: [
                    "geo": "geo:52.5200,13.4050",
                    "osm": "https://www.openstreetmap.org/?mlat=52.5200&mlon=13.4050"
                ]
            )
        ]
        tags.locked = [
            NamespaceNode(
                name: "podcast:locked",
                value: "yes",
                attributes: ["owner": "admin@example.com"]
            )
        ]
        tags.medium = [NamespaceNode(name: "podcast:medium", value: "podcast")]
        tags.podping = [
            NamespaceNode(
                name: "podcast:podping",
                attributes: ["usesPodping": "true", "reason": "new-episode"]
            )
        ]
        tags.podroll = [
            NamespaceNode(
                name: "podcast:podroll",
                children: [
                    NamespaceNode(
                        name: "podcast:remoteItem",
                        attributes: [
                            "feedGuid": "feed-guid-1",
                            "feedUrl": "https://example.com/recommended-a.xml"
                        ]
                    ),
                    NamespaceNode(
                        name: "podcast:remoteItem",
                        attributes: [
                            "feedGuid": "feed-guid-2",
                            "feedUrl": "https://example.com/recommended-b.xml"
                        ]
                    )
                ]
            )
        ]
        tags.publisher = [
            NamespaceNode(
                name: "podcast:publisher",
                value: "Preview Network",
                attributes: ["guid": "publisher-guid-123", "url": "https://example.com/network"]
            )
        ]
        tags.remoteItem = [
            NamespaceNode(
                name: "podcast:remoteItem",
                attributes: [
                    "feedGuid": "feed-guid-main",
                    "feedUrl": "https://example.com/main.xml",
                    "itemGuid": "ep-guid-42",
                    "medium": "podcast"
                ]
            )
        ]
        tags.season = [
            NamespaceNode(
                name: "podcast:season",
                value: "4",
                attributes: ["name": "Scaling SwiftUI"]
            )
        ]
        tags.soundbite = [
            NamespaceNode(
                name: "podcast:soundbite",
                value: "https://example.com/audio/soundbite-42.mp3",
                attributes: ["startTime": "123", "duration": "45"]
            )
        ]
        tags.source = [
            NamespaceNode(
                name: "podcast:source",
                attributes: [
                    "uri": "https://origin.example.com/feed.xml",
                    "contentType": "application/rss+xml"
                ]
            )
        ]
        tags.trailer = [
            NamespaceNode(
                name: "podcast:trailer",
                attributes: ["url": "https://example.com/audio/trailer.mp3", "season": "4"]
            )
        ]
        tags.txt = [
            NamespaceNode(name: "podcast:txt", value: "verify=abcd-1234"),
            NamespaceNode(name: "podcast:txt", value: "host=preview.example.com")
        ]
        tags.updateFrequency = [
            NamespaceNode(
                name: "podcast:updateFrequency",
                value: "daily",
                attributes: ["complete": "false"]
            )
        ]
        tags.value = [
            NamespaceNode(
                name: "podcast:value",
                attributes: ["type": "lightning", "method": "keysend", "suggested": "10000"],
                children: [
                    NamespaceNode(
                        name: "podcast:valueRecipient",
                        attributes: ["name": "Host", "address": "03abc", "split": "80"]
                    ),
                    NamespaceNode(
                        name: "podcast:valueRecipient",
                        attributes: ["name": "Editor", "address": "03def", "split": "20"]
                    )
                ]
            )
        ]
        tags.valueRecipient = [
            NamespaceNode(
                name: "podcast:valueRecipient",
                attributes: [
                    "name": "Standalone Recipient",
                    "address": "03aaa",
                    "split": "5",
                    "customKey": "818818",
                    "customValue": "preview"
                ]
            )
        ]
        tags.valueTimeSplit = [
            NamespaceNode(
                name: "podcast:valueTimeSplit",
                attributes: [
                    "startTime": "600",
                    "duration": "120",
                    "remotePercentage": "10"
                ],
                children: [
                    NamespaceNode(
                        name: "podcast:remoteItem",
                        attributes: [
                            "feedGuid": "split-feed-guid",
                            "itemGuid": "split-item-guid",
                            "medium": "video"
                        ]
                    )
                ]
            )
        ]

        return tags
    }

    static var valueSplitSingle: PodcastNamespaceOptionalTags {
        valueTags([
            NamespaceNode(
                name: "podcast:valueRecipient",
                attributes: ["name": "Host", "address": "03abc"]
            )
        ])
    }

    static var valueSplitEightyTwenty: PodcastNamespaceOptionalTags {
        valueTags([
            NamespaceNode(
                name: "podcast:valueRecipient",
                attributes: ["name": "Host", "address": "03abc", "split": "80"]
            ),
            NamespaceNode(
                name: "podcast:valueRecipient",
                attributes: ["name": "Producer", "address": "03def", "split": "20"]
            )
        ])
    }

    static var valueSplitWeightedShares: PodcastNamespaceOptionalTags {
        valueTags([
            NamespaceNode(
                name: "podcast:valueRecipient",
                attributes: ["name": "Host", "address": "03abc", "split": "190"]
            ),
            NamespaceNode(
                name: "podcast:valueRecipient",
                attributes: ["name": "Co-Host", "address": "03def", "split": "152"]
            ),
            NamespaceNode(
                name: "podcast:valueRecipient",
                attributes: ["name": "Producer", "address": "03ghi", "split": "38"]
            )
        ])
    }

    static var valueSplitWithFee: PodcastNamespaceOptionalTags {
        valueTags([
            NamespaceNode(
                name: "podcast:valueRecipient",
                attributes: ["name": "Host", "address": "03abc", "split": "90"]
            ),
            NamespaceNode(
                name: "podcast:valueRecipient",
                attributes: ["name": "Hosting", "address": "03def", "split": "10", "fee": "true"]
            )
        ])
    }

    private static func valueTags(_ recipients: [NamespaceNode]) -> PodcastNamespaceOptionalTags {
        var tags = PodcastNamespaceOptionalTags.empty
        tags.value = [
            NamespaceNode(
                name: "podcast:value",
                attributes: ["type": "lightning", "method": "keysend", "suggested": "0.00000005000"],
                children: recipients
            )
        ]
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
