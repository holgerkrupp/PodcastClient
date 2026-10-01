import SwiftUI
import SwiftData
import RichText

/// Renders shownotes from the source document and promotes podcast links that
/// were already enriched during a feed refresh. The view never starts network
/// enrichment itself.
struct ShownoteContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let html: String
    @State private var document: ShownoteDocument?
    @State private var enrichmentResults: [URL: ShownoteEnrichmentResult] = [:]

    init(html: String) {
        self.html = html
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document {
                ForEach(document.blocks) { block in
                    switch block {
                    case .html(_, let value):
                        richText(value)
                    case .link(_, let candidate):
                        if let result = enrichmentResults[candidate.normalizedURL] {
                            enrichedLink(candidate: candidate, result: result)
                        } else {
                            richText(linkMarkup(for: candidate))
                        }
                    }
                }
            } else {
                richText(html)
            }
        }
        .onChange(of: html) { _, _ in
            document = nil
            enrichmentResults.removeAll()
        }
        .task(id: html) {
            let parsedDocument = await ShownoteParser.shared.parse(html)
            guard Task.isCancelled == false else { return }
            document = parsedDocument
            guard parsedDocument.candidates.isEmpty == false else { return }
            let results = await ShownoteEnrichmentService.shared.cachedResults(
                for: parsedDocument.candidates
            )
            guard Task.isCancelled == false else { return }
            var cachedResults: [URL: ShownoteEnrichmentResult] = [:]
            for result in results {
                cachedResults[result.normalizedURL] = result
            }
            if reduceMotion {
                enrichmentResults = cachedResults
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    enrichmentResults = cachedResults
                }
            }
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
                richText(linkMarkup(for: candidate))
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
            richText(linkMarkup(for: candidate))
        }
    }

    @ViewBuilder
    private func richText(_ value: String) -> some View {
#if os(iOS)
        RichText(html: value)
            .linkColor(light: Color.secondary, dark: Color.secondary)
            .backgroundColor(.transparent)
#else
        RichText(html: value)
            .backgroundColor(.transparent)
#endif
    }

    private func linkMarkup(for candidate: ShownoteLinkCandidate) -> String {
        if candidate.occurrenceKind == .publisherAnchor {
            return candidate.sourceMarkup
        }
        let href = candidate.originalURL.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return "<a href=\"\(href)\">\(candidate.displayText)</a>"
    }
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
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let handle = metadata?.handle, handle != title {
                    Text(handle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let description = metadata?.description, description.isEmpty == false {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Text(siteLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
        }
    }
}
