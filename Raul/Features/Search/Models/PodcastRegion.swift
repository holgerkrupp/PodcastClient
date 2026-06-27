//
//  PodcastRegion.swift
//  Raul
//
//  Apple Podcasts storefront regions used for browsing categories and
//  top-chart ("hot") podcasts.
//

import Foundation

/// An Apple Podcasts storefront, identified by an ISO 3166-1 alpha-2 country code.
struct PodcastRegion: Identifiable, Hashable {
    /// Lowercased country code, e.g. "us", "de".
    let code: String

    var id: String { code }

    /// Localized country name for display, e.g. "United States".
    var displayName: String {
        Locale.autoupdatingCurrent.localizedString(forRegionCode: code.uppercased())
            ?? code.uppercased()
    }

    /// Common Apple Podcasts storefronts offered in the region picker.
    static let all: [PodcastRegion] = [
        "us", "gb", "ca", "au", "ie", "nz",
        "de", "at", "ch", "fr", "es", "it", "nl", "be",
        "se", "no", "dk", "fi", "pt", "pl",
        "br", "mx", "ar",
        "jp", "in", "cn", "kr",
        "ru", "tr", "za"
    ]
    .map(PodcastRegion.init(code:))
    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

    /// The device's region if Apple has a storefront for it, otherwise the US.
    static var defaultRegionCode: String {
        let deviceCode = Locale.autoupdatingCurrent.region?.identifier.lowercased()
        if let deviceCode, all.contains(where: { $0.code == deviceCode }) {
            return deviceCode
        }
        return "us"
    }
}
