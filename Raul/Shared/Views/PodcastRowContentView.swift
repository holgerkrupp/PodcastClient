import CryptoKit
import Foundation
import SwiftUI
import ESADesignKit

/// A small, value-only snapshot used by the Library, Search, and broadcaster
/// discovery rows. Callers own navigation and status lookup; this view only
/// presents the supplied values.
struct PodcastRowPresentation {
    enum Status {
        case subscribed
        case notSubscribed
    }

    let identity: String
    let title: String
    let author: String?
    let context: String?
    let summary: String?
    let artworkURL: URL?
    let artworkAccessProfile: PodcastAccessProfile?
    let status: Status?
    let diagnosticBadge: String?
    let diagnosticMessage: String?
    let progressMessage: String?

    init(
        identity: String,
        feedURL: URL? = nil,
        title: String,
        author: String? = nil,
        context: String? = nil,
        summary: String? = nil,
        artworkURL: URL? = nil,
        artworkAccessProfile: PodcastAccessProfile? = nil,
        status: Status? = nil,
        diagnosticBadge: String? = nil,
        diagnosticMessage: String? = nil,
        progressMessage: String? = nil
    ) {
        let safeIdentity = Self.cacheIdentity(for: identity)
        self.identity = safeIdentity
        self.title = Self.safeText(Self.safeTitle(title, feedURL: feedURL), feedURL: feedURL)
            ?? "New Podcast"
        self.author = Self.safeText(author, feedURL: feedURL)
        self.context = Self.safeText(context, feedURL: feedURL)
        self.summary = summary.flatMap {
            Self.safeText(
                PodcastRowDescriptionCache.shared.text(
                    for: $0,
                    identity: safeIdentity,
                    privateFeedURL: feedURL
                ),
                feedURL: feedURL
            )
        }
        self.artworkURL = artworkURL
        self.artworkAccessProfile = artworkAccessProfile
        self.status = status
        self.diagnosticBadge = Self.safeText(diagnosticBadge, feedURL: feedURL)
        self.diagnosticMessage = Self.safeText(diagnosticMessage, feedURL: feedURL)
        self.progressMessage = Self.safeText(progressMessage, feedURL: feedURL)
    }

    private static func safeTitle(_ title: String, feedURL: URL?) -> String {
        let candidate = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty == false else {
            return feedURL.map(Self.safeFeedURLTitle) ?? "New Podcast"
        }

        if let candidateURL = URL(string: candidate), candidateURL.isLikelyPrivatePodcastURL {
            return candidateURL.redactedPodcastURLString
        }
        return candidate
    }

    private static func safeFeedURLTitle(_ url: URL) -> String {
        url.isLikelyPrivatePodcastURL ? url.redactedPodcastURLString : url.absoluteString
    }

    private static func cacheIdentity(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return "podcast-row-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func safeText(_ value: String?, feedURL: URL?) -> String? {
        guard let value = value.nonEmpty else { return nil }
        guard let feedURL, feedURL.isLikelyPrivatePodcastURL else { return value }

        return value
            .replacingOccurrences(of: feedURL.absoluteString, with: feedURL.redactedPodcastURLString)
            .replacingOccurrences(
                of: feedURL.absoluteString.removingPercentEncoding ?? feedURL.absoluteString,
                with: feedURL.redactedPodcastURLString
            )
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self,
              value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class PodcastRowDescriptionCache: @unchecked Sendable {
    static let shared = PodcastRowDescriptionCache()

    private let values: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 512
        cache.totalCostLimit = 1_000_000
        return cache
    }()

    func text(for source: String, identity: String, privateFeedURL: URL?) -> String {
        var hasher = Hasher()
        hasher.combine(identity)
        hasher.combine(source)
        let key = "podcast-row-description-\(hasher.finalize())" as NSString
        if let cached = values.object(forKey: key) {
            return cached as String
        }

        var normalized = source.plainTextFromHTML() ?? source
        if let privateFeedURL, privateFeedURL.isLikelyPrivatePodcastURL {
            normalized = normalized.replacingOccurrences(
                of: privateFeedURL.absoluteString,
                with: privateFeedURL.redactedPodcastURLString
            )
            normalized = normalized.replacingOccurrences(
                of: privateFeedURL.absoluteString.removingPercentEncoding ?? privateFeedURL.absoluteString,
                with: privateFeedURL.redactedPodcastURLString
            )
        }
        values.setObject(normalized as NSString, forKey: key, cost: normalized.utf8.count)
        return normalized
    }
}

struct PodcastRowContentView: View {
    enum Density: Equatable {
        case comfortable
        case compact
    }

    let presentation: PodcastRowPresentation
    var density: Density = .comfortable
    var previewArtwork: Image? = nil
    var previewArtworkSource: ESAImageSource? = nil
    var accessibilityLabel: String? = nil

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.esaVisualStyle) private var visualStyle
    @ScaledMetric(relativeTo: .body) private var comfortableRowHeight: CGFloat = 140
    @ScaledMetric(relativeTo: .body) private var comfortableArtworkSize: CGFloat = 112
    @ScaledMetric(relativeTo: .body) private var compactRowHeight: CGFloat = 72
    @ScaledMetric(relativeTo: .body) private var compactArtworkSize: CGFloat = 56

    private var rowHeight: CGFloat {
        density == .compact ? compactRowHeight : comfortableRowHeight
    }

    private var artworkSize: CGFloat {
        density == .compact ? compactArtworkSize : comfortableArtworkSize
    }

    private var summaryLineLimit: Int {
        density == .compact ? 1 : 3
    }

    @ViewBuilder
    var body: some View {
        if let accessibilityLabel {
            styledRow
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
        } else {
            styledRow
        }
    }

    private var styledRow: some View {
        let rowContent = content
            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if let diagnosticMessage = presentation.diagnosticMessage,
                   presentation.diagnosticBadge == nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(9)
                        .accessibilityLabel(diagnosticMessage)
                        .help(diagnosticMessage)
                }
            }
            .overlay {
                if let message = presentation.progressMessage {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.clear)
                            .ignoresSafeArea()
                        HStack(alignment: .center) {
                            ProgressView()
                                .frame(width: 100, height: 50)
                            Text(message)
                                .esaForeground(.primary)
                                .font(.title.bold())
                        }
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.background.opacity(0.3))
                    }
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20))
                    .frame(maxWidth: 300, maxHeight: 150, alignment: .center)
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityElement(children: .combine)

        return Group {
            if visualStyle == .artwork {
                artworkStyle(rowContent)
            } else if let previewArtworkSource {
                ESARowView(image: previewArtworkSource, minHeight: rowHeight) {
                    rowContent
                }
            } else {
                rowContent.ESA_RowView(image: presentation.artworkURL, minHeight: rowHeight)
            }
        }
    }

    private var content: some View {
        HStack(spacing: density == .compact ? 12 : 14) {
            Group {
                if let previewArtwork {
                    previewArtwork
                        .resizable()
                        .scaledToFit()
                } else {
                    CoverImageView(
                        imageURL: presentation.artworkURL,
                        accessProfileOverride: presentation.artworkAccessProfile,
                        maxPixelSize: 384,
                        loadDelay: .milliseconds(200)
                    )
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: density == .compact ? 8 : 0, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: density == .compact ? 3 : 8) {
                Text(presentation.title)
                    .font(.headline)
                    .lineLimit(2)
                    .esaForeground(.primary)

                if let author = presentation.author {
                    Text(author)
                        .font(.subheadline)
                        .esaForeground(.secondary)
                        .lineLimit(1)
                }

                if let context = presentation.context {
                    Text(context)
                        .font(.caption)
                        .esaForeground(.secondary)
                        .lineLimit(1)
                }

                if let summary = presentation.summary {
                    Text(summary)
                        .font(.caption)
                        .esaForeground(.secondary)
                        .lineLimit(summaryLineLimit)
                }

                if let status = presentation.status {
                    Label(status.title, systemImage: status.symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.color)
                }

                if let diagnosticBadge = presentation.diagnosticBadge {
                    Label(diagnosticBadge, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .accessibilityLabel(presentation.diagnosticMessage ?? diagnosticBadge)
                        .help(presentation.diagnosticMessage ?? diagnosticBadge)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .background {
            if visualStyle == .artwork && colorSchemeContrast == .standard {
                Rectangle().fill(.thinMaterial)
            }
        }
    }

    @ViewBuilder
    private func artworkStyle<Content: View>(_ content: Content) -> some View {
        if colorSchemeContrast == .increased {
            content.background(Color(white: colorScheme == .dark ? 0 : 1))
        } else {
            // The blurred image is decoration: it must never participate in
            // measuring the Library row's width. Previously scaledToFill()
            // was applied to a ZStack containing *both* image and text,
            // which made the entire row wider than its List cell.
            content
                .background {
                    GeometryReader { geometry in
                        Group {
                            if let previewArtwork {
                                previewArtwork
                                    .resizable()
                                    .scaledToFill()
                                    .blur(radius: 18)
                            } else {
                                BlurredCoverImageView(
                                    imageURL: presentation.artworkURL,
                                    accessProfileOverride: presentation.artworkAccessProfile,
                                    maxPixelSize: 256,
                                    loadDelay: .milliseconds(350)
                                )
                                .scaledToFill()
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                .clipped()
                .accessibilityElement(children: .contain)
        }
    }
}

private extension PodcastRowPresentation.Status {
    var title: String {
        switch self {
        case .subscribed: "Subscribed"
        case .notSubscribed: "Not Subscribed"
        }
    }

    var symbolName: String {
        switch self {
        case .subscribed: "checkmark.circle"
        case .notSubscribed: "pause.circle"
        }
    }

    var color: Color {
        switch self {
        case .subscribed: .green
        case .notSubscribed: .orange
        }
    }
}
