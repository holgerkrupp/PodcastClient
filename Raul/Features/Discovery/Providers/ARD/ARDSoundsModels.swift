//
//  ARDSoundsModels.swift
//  Raul
//
//  Response shapes of the ARD Sounds / ARD Audiothek web API.
//
//  These types are deliberately confined to the ARD provider. They are NOT a
//  public developer API and may change without notice, so nothing outside
//  `ARDSoundsDiscoveryProvider` is allowed to depend on them — responses are
//  converted to `DiscoveredPodcast` immediately.
//

import Foundation

struct ARDSoundsSearchResponse: Decodable, Sendable {
    struct DataContainer: Decodable, Sendable {
        let search: SearchContainer?
    }

    struct SearchContainer: Decodable, Sendable {
        let programSets: ProgramSetContainer?
    }

    struct ProgramSetContainer: Decodable, Sendable {
        let numberOfElements: Int?
        let nodes: [ARDProgramSet]?
    }

    let data: DataContainer?

    var programSets: [ARDProgramSet] { data?.search?.programSets?.nodes ?? [] }
}

struct ARDProgramSet: Decodable, Sendable {
    struct Image: Decodable, Sendable {
        let url: String?
        let url1X1: String?

        /// ARD serves templated image URLs (`…?w={width}`); fill the placeholder in.
        func url(width: Int) -> URL? {
            let template = url1X1 ?? url
            guard let template else { return nil }
            return URL(string: template.replacingOccurrences(of: "{width}", with: String(width)))
        }
    }

    struct PublicationService: Decodable, Sendable {
        let title: String?
        let organizationName: String?
    }

    let id: String
    let title: String
    let synopsis: String?
    let numberOfElements: Int?
    let sharingUrl: String?
    let image: Image?
    let publicationService: PublicationService?

    var author: String? {
        publicationService?.title ?? publicationService?.organizationName
    }

    var webpageURL: URL? {
        sharingUrl.flatMap(URL.init(string:))
    }
}

// MARK: - Catalogue

/// `/organizations` returns ARD's whole catalogue in one document: every
/// organization (BR, WDR, NDR, …), its publication services (the individual
/// stations) and the program sets each station publishes.
struct ARDSoundsOrganizationsResponse: Decodable, Sendable {
    struct DataContainer: Decodable, Sendable {
        let organizations: OrganizationContainer?
    }

    struct OrganizationContainer: Decodable, Sendable {
        let nodes: [ARDOrganization]?
    }

    let data: DataContainer?

    var organizations: [ARDOrganization] { data?.organizations?.nodes ?? [] }
}

struct ARDOrganization: Decodable, Sendable {
    struct PublicationServiceContainer: Decodable, Sendable {
        let nodes: [ARDPublicationService]?
    }

    let id: String
    let name: String
    let publicationServices: PublicationServiceContainer?

    var services: [ARDPublicationService] { publicationServices?.nodes ?? [] }
}

struct ARDPublicationService: Decodable, Sendable {
    struct ProgramSetContainer: Decodable, Sendable {
        let nodes: [ARDProgramSet]?
    }

    let id: String
    let title: String?
    let organizationName: String?
    let programSets: ProgramSetContainer?

    var shows: [ARDProgramSet] { programSets?.nodes ?? [] }
}
