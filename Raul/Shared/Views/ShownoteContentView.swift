import SwiftUI
import SwiftData
import RichText

/// Renders shownotes immediately from the source document and enriches link
/// occurrences in the background. The source HTML is never rewritten in the
/// model or persisted as presentation state.
struct ShownoteContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let html: String
    @State private var document: ShownoteDocument?
    @State private var podcastFeeds: [URL: PodcastFeed] = [:]

    init(html: String) {
        self.html = html
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let document {
                ForEach(document.blocks) { block in
                    switch block {
                    case .html(_, let value):
                        richText(value)
                    case .link(_, let candidate):
                        if let feed = podcastFeeds[candidate.normalizedURL] {
                            SubscribeToPodcastView(newPodcastFeed: feed)
                                .padding(.vertical, 4)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel("Podcast recommendation: \(feed.title ?? candidate.displayText)")
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
            podcastFeeds.removeAll()
        }
        .task(id: html) {
            let parsedDocument = await ShownoteParser.shared.parse(html)
            guard Task.isCancelled == false else { return }
            document = parsedDocument
            guard parsedDocument.candidates.isEmpty == false else { return }
            let results = await ShownoteEnrichmentService.shared.enrich(parsedDocument.candidates)
            guard Task.isCancelled == false else { return }
            var feeds: [URL: PodcastFeed] = [:]
            for result in results {
                if let feed = result.podcastFeed {
                    feeds[result.normalizedURL] = feed
                }
            }
            if reduceMotion {
                podcastFeeds = feeds
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    podcastFeeds = feeds
                }
            }
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
