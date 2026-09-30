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

    func item(id: String) async throws -> ARDSoundsItem {
        guard let url = URL(string: "\(Self.base)/graphql") else {
            throw PodcastDiscoveryError.invalidResponse
        }

        let query = """
        query($id: ID!) {
          item(id: $id) {
            id title description duration startDate episodeNumber
            audioList { href distributionType audioBitrate audioCodec }
            audios { url downloadUrl }
            image { url url1X1 }
            show { title }
            programSet { title publicationService { title organizationName } }
          }
        }
        """
        let body = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": ["id": id]
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let item = try await client.json(ARDSoundsItemResponse.self, request: request).itemValue else {
            throw PodcastDiscoveryError.parsingFailed
        }
        return item
    }

    static func itemURN(in url: URL) -> String? {
        guard let host = url.host()?.lowercased(),
              host == "ardsounds.de" || host.hasSuffix(".ardsounds.de") ||
              host == "ardaudiothek.de" || host.hasSuffix(".ardaudiothek.de") else {
            return nil
        }
        let path = url.path.removingPercentEncoding ?? url.path
        let pattern = #"(?i)urn:ard:(?:episode|section|extra):[a-z0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: path,
                range: NSRange(path.startIndex..<path.endIndex, in: path)
              ),
              let range = Range(match.range, in: path) else {
            return nil
        }
        return String(path[range])
    }
}
