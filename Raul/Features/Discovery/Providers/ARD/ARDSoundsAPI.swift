//
//  ARDSoundsAPI.swift
//  Raul
//
//  Networking for ARD Sounds. Every ARD request in the app goes through here.
//
//  This is the web API ARD's own clients use. It is not a documented, stable
//  developer API, which is why the provider is written to fail softly and can be
//  switched off through `PodcastDiscoveryConfiguration` without touching any
//  other part of discovery.
//

import Foundation

struct ARDSoundsAPI: Sendable {
    private static let base = "https://api.ardaudiothek.de"

    let client: PodcastDiscoveryHTTPClient

    init(client: PodcastDiscoveryHTTPClient = .shared) {
        self.client = client
    }

    /// ARD's whole catalogue: organizations -> stations -> shows, in one request.
    func organizations(refresh: Bool) async throws -> [ARDOrganization] {
        guard let url = URL(string: "\(Self.base)/organizations") else {
            throw PodcastDiscoveryError.unavailable
        }

        let response = try await client.json(
            ARDSoundsOrganizationsResponse.self,
            from: url,
            refresh: refresh
        )

        let organizations = response.organizations

        guard organizations.isEmpty == false else {
            throw PodcastDiscoveryError.parsingFailed
        }

        return organizations
    }

    func searchProgramSets(_ query: String, limit: Int = 30) async throws -> [ARDProgramSet] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Self.base)/search/programsets?query=\(encoded)&limit=\(limit)") else {
            throw PodcastDiscoveryError.invalidResponse
        }

        let response = try await client.json(ARDSoundsSearchResponse.self, from: url, refresh: false)
        return response.programSets
    }
}
