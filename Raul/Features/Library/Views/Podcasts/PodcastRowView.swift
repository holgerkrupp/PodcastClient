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
/// shared value-driven presenter. It intentionally does not inspect episodes
/// or calculate release/abandonment health while SwiftUI renders the row.
struct PodcastRowView: View {
    let podcast: Podcast
    var density: PodcastRowContentView.Density = .comfortable
    var previewArtwork: Image? = nil
    var previewArtworkSource: ESAImageSource? = nil

    var body: some View {
        PodcastRowContentView(
            presentation: presentation,
            density: density,
            previewArtwork: previewArtwork,
            previewArtworkSource: previewArtworkSource
        )
    }

    private var presentation: PodcastRowPresentation {
        let metadata = podcast.metaData
        let diagnostic = rowDiagnostic(from: metadata)
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

    private func rowDiagnostic(from metadata: PodcastMetaData?) -> (badge: String, message: String)? {
        guard let metadata else { return nil }

        switch metadata.credentialState {
        case .missing where metadata.accessKindRawValue != nil
            && metadata.accessKindRawValue != PodcastAccessKind.publicFeed.rawValue:
            return ("AUTHENTICATION MISSING", "This podcast needs saved authentication before it can refresh.")
        case .needsLogin, .expired, .revoked:
            return ("AUTHENTICATION REQUIRED", "This podcast's saved authentication needs attention.")
        case .storageUnavailable:
            return ("AUTHENTICATION UNAVAILABLE", "Saved authentication could not be accessed on this device.")
        case .available, .missing, .unsupported:
            break
        }

        let assessment = metadata.feedAbandonmentAssessment
        if assessment?.kind == .likelyCancelled {
            let detail = assessment?.detail ?? "The feed checks successfully, but expected episodes have not appeared."
            return ("POSSIBLY CANCELLED", detail)
        }
        if assessment?.kind == .unavailableFeed {
            return ("FEED UNAVAILABLE", assessment?.detail ?? "The podcast feed has been unreachable repeatedly.")
        }

        guard metadata.lastFeedFailureDate != nil else { return nil }
        let statusCode = metadata.lastFeedFailureStatusCode
        if statusCode == 401 || statusCode == 403 {
            return ("AUTHENTICATION REQUIRED", feedIssueDescription(from: metadata) ?? "The feed requires authentication.")
        }
        if statusCode == 404 || statusCode == 410 || statusCode == 451 {
            return ("FEED UNAVAILABLE", feedIssueDescription(from: metadata) ?? "The podcast feed is unavailable.")
        }
        return ("FEED ISSUE", feedIssueDescription(from: metadata) ?? "The podcast feed could not be refreshed.")
    }

    private func accessProfile(from metadata: PodcastMetaData?, feedURL: URL?) -> PodcastAccessProfile? {
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
    private func feedIssueDescription(from metadata: PodcastMetaData?) -> String? {
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
