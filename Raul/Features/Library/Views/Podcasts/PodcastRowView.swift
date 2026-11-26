//
//  PodcastRowView.swift
//  Raul
//
//  Created by Holger Krupp on 11.07.25.
//

import SwiftUI
import SwiftData
import ESADesignKit

/// Library adapter that snapshots the podcast's existing row fields into the
/// shared value-driven presenter. It never inspects episodes or runs release
/// prediction while SwiftUI builds the row: stored failure fields are scalar
/// checks, and the release-pattern "possibly cancelled" verdict comes from
/// `PodcastFeedHealthCache`, which the Library evaluates off the main actor.
struct PodcastRowView: View {
    let podcast: Podcast
    var density: PodcastRowContentView.Density = .comfortable
    var groupPosition: GroupedListRowPosition = .single
    var previewArtwork: Image? = nil
    var previewArtworkSource: ESAImageSource? = nil
    private let presentation: PodcastRowPresentation

    init(
        podcast: Podcast,
        density: PodcastRowContentView.Density = .comfortable,
        groupPosition: GroupedListRowPosition = .single,
        previewArtwork: Image? = nil,
        previewArtworkSource: ESAImageSource? = nil,
        likelyCancelledAssessment: PodcastFeedAbandonmentAssessment? = nil
    ) {
        self.podcast = podcast
        self.density = density
        self.groupPosition = groupPosition
        self.previewArtwork = previewArtwork
        self.previewArtworkSource = previewArtworkSource
        self.presentation = Self.makePresentation(
            from: podcast,
            likelyCancelledAssessment: likelyCancelledAssessment
        )
    }

    var body: some View {
        PodcastRowContentView(
            presentation: presentation,
            density: density,
            groupPosition: groupPosition,
            previewArtwork: previewArtwork,
            previewArtworkSource: previewArtworkSource
        )
    }

    /// Capture SwiftData-backed display values when the row is created. SwiftUI
    /// can keep a row alive while a background context deletes its model; its
    /// body must not call generated model accessors during that interval.
    private static func makePresentation(
        from podcast: Podcast,
        likelyCancelledAssessment: PodcastFeedAbandonmentAssessment?
    ) -> PodcastRowPresentation {
        let metadata = podcast.metaData
        let diagnostic = rowDiagnostic(
            from: metadata,
            likelyCancelled: likelyCancelledAssessment
                ?? PodcastFeedHealthCache.shared.likelyCancelledAssessment(for: podcast.persistentModelID)
        )
        return PodcastRowPresentation(
            identity: podcast.stablePodcastIdentityKey,
            feedURL: podcast.feed,
            title: podcast.title,
            author: podcast.author,
            summary: podcast.desc,
            artworkURL: podcast.imageURL,
            artworkAccessProfile: accessProfile(from: metadata, feedURL: podcast.feed),
            status: podcast.isSubscribed ? .subscribed : .notSubscribed,
            diagnosticBadge: diagnostic?.badge,
            diagnosticMessage: diagnostic?.message,
            progressMessage: metadata?.message
        )
    }

    static func rowDiagnostic(
        from metadata: PodcastMetaData?,
        likelyCancelled: PodcastFeedAbandonmentAssessment?,
        now: Date = Date()
    ) -> (badge: String, message: String)? {
        guard let metadata else { return nil }

        if let attention = PodcastAuthenticationAttention.resolve(
            credentialState: metadata.credentialState,
            accessProfileID: metadata.accessProfileID,
            accessKindRawValue: metadata.accessKindRawValue
        ) {
            return (attention.badge, attention.message)
        }

        // Scalar stored-failure check first, matching the full assessment's
        // precedence. Never call `feedAbandonmentAssessment` here: it fetches
        // episodes for the release pattern.
        if let unavailable = PodcastFeedAbandonmentAssessment.unavailableFeedAssessment(
            metadata: metadata,
            now: now
        ) {
            return ("FEED UNAVAILABLE", unavailable.detail)
        }
        if metadata.isSubscribed, let likelyCancelled, likelyCancelled.kind == .likelyCancelled {
            return ("POSSIBLY CANCELLED", likelyCancelled.detail)
        }

        guard metadata.lastFeedFailureDate != nil else { return nil }
        let statusCode = metadata.lastFeedFailureStatusCode
        if statusCode == 404 || statusCode == 410 || statusCode == 451 {
            return ("FEED UNAVAILABLE", feedIssueDescription(from: metadata) ?? "The podcast feed is unavailable.")
        }
        return ("FEED ISSUE", feedIssueDescription(from: metadata) ?? "The podcast feed could not be refreshed.")
    }

    private static func accessProfile(from metadata: PodcastMetaData?, feedURL: URL?) -> PodcastAccessProfile? {
        guard let metadata,
              let id = metadata.accessProfileID,
              let rawKind = metadata.accessKindRawValue,
              let kind = PodcastAccessKind(rawValue: rawKind),
              let feedURL else {
            return nil
        }
        return PodcastAccessProfile(
            id: id,
            kind: kind,
            resourceURL: feedURL,
            providerID: metadata.accessProviderID.flatMap(PremiumPodcastProviderID.init(rawValue:))
        )
    }

    /// Only reads already stored failure fields; release-pattern prediction is
    /// deliberately kept out of row rendering to avoid episode relationship
    /// faults in large lists.
    private static func feedIssueDescription(from metadata: PodcastMetaData?) -> String? {
        guard let metadata, metadata.lastFeedFailureDate != nil else { return nil }
        let reason = metadata.feedFailureStatusDescription
            ?? metadata.lastFeedFailureMessage
            ?? "The podcast feed could not be refreshed."
        return "Podcast feed issue: \(reason)"
    }
}

#Preview {
    let metaData: PodcastMetaData = {
        let metaData = PodcastMetaData()
        metaData.feedUpdateCheckDate = Date().addingTimeInterval(-3600)
        metaData.consecutiveFeedFailureCount = 4
        metaData.firstConsecutiveFeedFailureDate = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        metaData.lastFeedFailureDate = Date().addingTimeInterval(-3600)
        metaData.lastFeedFailureStatusCode = 404
        metaData.isUpdating = false
        return metaData
    }()

    let podcast: Podcast = {
        let podcast = Podcast(feed: URL(string: "https://example.com/feed.xml")!)
        podcast.title = "Swift Over Coffee"
        podcast.author = "Paul Hudson & Sean Allen"
        podcast.desc = "A show about Swift, iOS development, and general Apple nerdery."
        podcast.lastBuildDate = Date().addingTimeInterval(-7200)
        podcast.imageURL = nil
        podcast.metaData = metaData
        return podcast
    }()

    PodcastRowView(podcast: podcast)
        .padding()
}
