//
//  PodcastDiscoveryCategory.swift
//  Raul
//
//  A browsable grouping inside one provider (an SRG topic, an ORF station, …).
//

import Foundation

struct PodcastDiscoveryCategory: Identifiable, Sendable, Hashable {
    /// Provider-scoped identifier, opaque to the UI.
    let id: String
    let title: String
    let providerID: String
    let artworkURL: URL?
    let podcastCount: Int?

    init(
        id: String,
        title: String,
        providerID: String,
        artworkURL: URL? = nil,
        podcastCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.providerID = providerID
        self.artworkURL = artworkURL
        self.podcastCount = podcastCount
    }
}
