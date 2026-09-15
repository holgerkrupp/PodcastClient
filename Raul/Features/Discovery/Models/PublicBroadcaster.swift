//
//  PublicBroadcaster.swift
//  Raul
//
//  Catalog model for public-service broadcasters offered in podcast discovery.
//

import Foundation

/// Coarse geographic grouping used to section the broadcaster list.
enum PublicBroadcasterRegion: String, Sendable, Hashable, CaseIterable, Identifiable {
    case europe
    case americas
    case asiaPacific
    case africa
    case middleEast

    var id: String { rawValue }

    /// Sort order of the sections on the Public Broadcasters screen.
    var sortIndex: Int {
        switch self {
        case .europe: return 0
        case .americas: return 1
        case .asiaPacific: return 2
        case .africa: return 3
        case .middleEast: return 4
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .europe: return LocalizedStringResource("Europe")
        case .americas: return LocalizedStringResource("Americas")
        case .asiaPacific: return LocalizedStringResource("Asia-Pacific")
        case .africa: return LocalizedStringResource("Africa")
        case .middleEast: return LocalizedStringResource("Middle East")
        }
    }
}

/// A public-service broadcaster that can be offered in podcast discovery.
///
/// Broadcasters are pure data: the discovery UI never branches on a specific
/// broadcaster. Whether a broadcaster can actually be browsed is decided by the
/// registry, which pairs it with a `PodcastDiscoveryProvider`.
struct PublicBroadcaster: Identifiable, Sendable {
    /// Stable identifier, also used as the identifier of the matching provider.
    let id: String
    let name: String
    /// ISO 3166-1 alpha-2 region code, used for the localized country name and the flag.
    let countryCode: String
    let region: PublicBroadcasterRegion
    let summary: LocalizedStringResource
    let website: URL?
    /// Logo shown in the broadcaster list, when one can be obtained reliably.
    let logoURL: URL?

    init(
        id: String,
        name: String,
        countryCode: String,
        region: PublicBroadcasterRegion,
        summary: LocalizedStringResource,
        website: URL? = nil,
        logoURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.countryCode = countryCode
        self.region = region
        self.summary = summary
        self.website = website
        self.logoURL = logoURL
    }

    /// Localized country name. Never rely on the flag alone to convey the country.
    var countryName: String {
        Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode
    }

    /// Regional indicator flag for the country code, or `nil` for codes that have none.
    var flag: String? {
        let code = countryCode.uppercased()
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }

        var flag = ""
        for scalar in code.unicodeScalars {
            guard let indicator = UnicodeScalar(scalar.value + 127_397) else { return nil }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }
}

extension PublicBroadcaster: Hashable {
    static func == (lhs: PublicBroadcaster, rhs: PublicBroadcaster) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
