import SwiftUI
import SwiftData
import RichText
import ESADesignKit
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Renders shownotes from the source document and promotes podcast links that
/// were already enriched during a feed refresh. The view never starts network
/// enrichment itself.
struct ShownoteContentView: View {
    @Environment(\.esaVisualStyle) private var visualStyle
    @Environment(\.esaThemePalette) private var themePalette
    private let html: String
    @State private var document: ShownoteDocument?
    @State private var enrichmentResults: [URL: ShownoteEnrichmentResult] = [:]

    init(html: String) {
        self.html = html
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document {
                // Without any cached rich cards, one RichText avoids creating
                // a WebKit instance for every extracted standalone link.
                if ShownoteRenderingPolicy.needsEnrichedBlocks(
                    in: document,
                    enrichmentResults: enrichmentResults
                ) {
                    ForEach(document.blocks) { block in
                        switch block {
                        case .html(_, let value):
                            richText(value)
                        case .link(_, let candidate):
                            if let result = enrichmentResults[candidate.normalizedURL] {
                                enrichedLink(candidate: candidate, result: result)
                            } else {
                                plainLink(candidate)
                            }
                        }
                    }
                } else if document.linkifiedHTML.isEmpty == false {
                    richText(document.linkifiedHTML)
                }
            } else if html.isEmpty == false {
                Label("Preparing shownotes", systemImage: "text.alignleft")
                    .font(.caption)
                    .esaForeground(.secondary)
                    .accessibilityLabel("Preparing shownotes")
            }
        }
        .onChange(of: html) { _, _ in
            document = nil
            enrichmentResults.removeAll()
        }
        .task(id: html) {
            guard html.isEmpty == false else {
                document = ShownoteDocument(html: "")
                return
            }
            let parsedDocument = await ShownoteParser.shared.parse(html)
            guard Task.isCancelled == false else { return }
            // Resolve cached cards before showing any HTML. Previously the
            // initial un-enriched fragments launched WebKit processes, then
            // the animated card substitution rebuilt most of them.
            var cachedResults: [URL: ShownoteEnrichmentResult] = [:]
            if parsedDocument.candidates.isEmpty == false {
                let results = await ShownoteEnrichmentService.shared.cachedResults(
                    for: parsedDocument.candidates
                )
                for result in results {
                    cachedResults[result.normalizedURL] = result
                }
            }
            guard Task.isCancelled == false else { return }
            enrichmentResults = cachedResults
            document = parsedDocument
        }
        .onAppear {
            os_signpost(.event, log: ShownoteViewPerformance.log, name: "Shownote visible")
        }
    }

    @ViewBuilder
    private func plainLink(_ candidate: ShownoteLinkCandidate) -> some View {
        Link(destination: candidate.originalURL) {
            Text(candidate.displayText.isEmpty
                 ? candidate.originalURL.absoluteString
                 : candidate.displayText)
                .underline()
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private func enrichedLink(
        candidate: ShownoteLinkCandidate,
        result: ShownoteEnrichmentResult
    ) -> some View {
        switch result.classification {
        case .podcast:
            if let feed = result.podcastFeed {
                SubscribeToPodcastView(newPodcastFeed: feed)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Podcast recommendation: \(feed.title ?? candidate.displayText)")
            } else {
                plainLink(candidate)
            }
        case .web, .mastodon:
            Link(destination: result.finalURL ?? result.preview?.canonicalURL ?? candidate.originalURL) {
                ShownotePreviewCard(
                    metadata: result.preview,
                    destination: result.finalURL ?? candidate.originalURL,
                    fallbackTitle: candidate.publisherAnchorText ?? candidate.displayText,
                    isMastodon: result.classification == .mastodon
                )
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
        case .unknown, .podcastCandidate, .unsupported:
            plainLink(candidate)
        }
    }

    @ViewBuilder
    private func richText(_ value: String) -> some View {
        let richText = RichText(html: value)
            .backgroundColor(.transparent)
            .customCSS("a { text-decoration: underline !important; }")
        if visualStyle == .artwork {
#if os(iOS)
            richText.linkColor(light: .secondary, dark: .secondary)
#else
            richText
#endif
        } else {
            let foreground = themePalette.primaryForeground
            let linkColor = themePalette.accent ?? themePalette.controlForeground
#if canImport(UIKit)
            richText
                .textColor(light: foreground, dark: foreground)
                .linkColor(light: linkColor, dark: linkColor)
                .colorPreference(forceColor: .all)
#elseif canImport(AppKit)
            richText
                .textColor(light: NSColor(foreground), dark: NSColor(foreground))
                .linkColor(light: NSColor(linkColor), dark: NSColor(linkColor))
                .colorPreference(forceColor: .all)
#else
            richText
                .textColor(light: foreground, dark: foreground)
                .colorPreference(forceColor: .all)
#endif
        }
    }
}

enum ShownoteRenderingPolicy {
    /// A full HTML document uses one WebKit view unless the cached enrichment
    /// actually needs an inline native card.
    static func needsEnrichedBlocks(
        in document: ShownoteDocument,
        enrichmentResults: [URL: ShownoteEnrichmentResult]
    ) -> Bool {
        return document.blocks.contains { block in
            guard case .link(_, let candidate) = block,
                  let result = enrichmentResults[candidate.normalizedURL] else {
                return false
            }
            switch result.classification {
            case .web, .mastodon:
                return true
            case .podcast:
                return result.podcastFeed != nil
            case .unknown, .podcastCandidate, .unsupported:
                return false
            }
        }
    }
}

private enum ShownoteViewPerformance {
    static let log = OSLog(subsystem: "de.holgerkrupp.PodcastClient", category: "Shownotes")
}

private struct ShownotePreviewCard: View {
    let metadata: ShownotePreviewMetadata?
    let destination: URL
    let fallbackTitle: String
    let isMastodon: Bool

    private var title: String {
        if let metadataTitle = metadata?.title, metadataTitle.isEmpty == false {
            return metadataTitle
        }
        if fallbackTitle.isEmpty == false,
           fallbackTitle != destination.absoluteString {
            return fallbackTitle
        }
        return destination.host ?? destination.absoluteString
    }

    private var siteLabel: String {
        metadata?.handle
            ?? metadata?.siteName
            ?? destination.host
            ?? destination.absoluteString
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PreviewArtwork(url: metadata?.imageURL, isMastodon: isMastodon)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .esaForeground(.primary)
                    .lineLimit(2)

                if let handle = metadata?.handle, handle != title {
                    Text(handle)
                        .font(.subheadline)
                        .esaForeground(.secondary)
                        .lineLimit(1)
                }

                if let description = metadata?.description, description.isEmpty == false {
                    Text(description)
                        .font(.subheadline)
                        .esaForeground(.secondary)
                        .lineLimit(3)
                }

                Text(siteLabel)
                    .font(.caption)
                    .esaForeground(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .esaForeground(.control)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open \(title)")
        .accessibilityHint("Opens the original web page")
    }
}

private struct PreviewArtwork: View {
    let url: URL?
    let isMastodon: Bool

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: isMastodon ? 32 : 10, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isMastodon ? 32 : 10, style: .continuous)
                .fill(Color.secondary.opacity(0.14))
            Image(systemName: isMastodon ? "mastodon.fill" : "globe")
                .esaForeground(.secondary)
        }
    }
}
