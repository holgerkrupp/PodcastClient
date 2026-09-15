//
//  SRGSSRAPI.swift
//  Raul
//
//  Thin client for SRG SSR's public Integration Layer.
//
//  The endpoints used here are the documented public read endpoints behind
//  https://il.srgssr.ch/integrationlayer/2.0 and currently need no credential.
//  Should SRG start requiring one, add "srgssr" to
//  `PodcastDiscoveryProviderKeys.providersRequiringAPIKeys` and pass the key from
//  `PodcastDiscoveryConfiguration`; no key is ever committed to source.
//

import Foundation

struct SRGSSRAPI: Sendable {
    private static let base = "https://il.srgssr.ch/integrationlayer/2.0"
    /// Shows are returned page by page; SRF's radio catalogue is under 200 shows,
    /// and the cap keeps a runaway `next` chain from paging forever.
    private static let maximumPages = 8
    private static let pageSize = 100

    let businessUnit: SRGSSRBusinessUnit
    let client: PodcastDiscoveryHTTPClient

    init(businessUnit: SRGSSRBusinessUnit, client: PodcastDiscoveryHTTPClient = .shared) {
        self.businessUnit = businessUnit
        self.client = client
    }

    /// The complete radio show catalogue, in alphabetical order.
    func alphabeticalShows(refresh: Bool) async throws -> [SRGSSRShow] {
        guard var nextURL = URL(
            string: "\(Self.base)/\(businessUnit.rawValue)/showList/radio/alphabetical?pageSize=\(Self.pageSize)"
        ) else {
            throw PodcastDiscoveryError.unavailable
        }

        var shows: [SRGSSRShow] = []
        var page = 0

        while page < Self.maximumPages {
            try Task.checkCancellation()

            let response = try await client.json(SRGSSRShowListResponse.self, from: nextURL, refresh: refresh)
            shows.append(contentsOf: response.showList ?? [])
            page += 1

            guard let following = response.next else { break }
            nextURL = following
        }

        guard shows.isEmpty == false else {
            throw PodcastDiscoveryError.parsingFailed
        }

        return shows
    }

    func searchShows(_ query: String) async throws -> [SRGSSRShow] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "\(Self.base)/\(businessUnit.rawValue)/searchResultShowList?q=\(encoded)&pageSize=20"
              ) else {
            throw PodcastDiscoveryError.invalidResponse
        }

        let response = try await client.json(SRGSSRSearchResponse.self, from: url, refresh: false)
        return response.searchResultShowList ?? []
    }

    /// Full metadata for a single show, including its podcast feed. Search
    /// results omit the feed, so resolution needs this second call.
    func show(id: String) async throws -> SRGSSRShow {
        let allowed = CharacterSet.urlPathAllowed
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(Self.base)/\(businessUnit.rawValue)/show/radio/\(encoded)") else {
            throw PodcastDiscoveryError.invalidResponse
        }

        return try await client.json(SRGSSRShow.self, from: url, refresh: false)
    }
}
