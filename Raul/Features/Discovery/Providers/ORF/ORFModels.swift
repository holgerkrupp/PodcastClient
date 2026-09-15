//
//  ORFModels.swift
//  Raul
//
//  Response shapes of ORF Sound's public audio API. Private to the ORF provider.
//

import Foundation

struct ORFPodcastListResponse: Decodable, Sendable {
    /// Podcasts keyed by station code ("oe1", "fm4", "noe", …).
    let payload: [String: [ORFPodcast]]
}

struct ORFPodcast: Decodable, Sendable {
    struct URLs: Decodable, Sendable {
        let feed: URL?
    }

    struct Link: Decodable, Sendable {
        let url: URL?
    }

    struct Image: Decodable, Sendable {
        struct Version: Decodable, Sendable {
            let path: URL?
        }

        let versions: Versions?

        struct Versions: Decodable, Sendable {
            let standard: Version?
            let premium: Version?
            let id3art: Version?
            let thumbnail: Version?
        }

        /// Prefers a square cover around 1400px, then the other sizes.
        var bestURL: URL? {
            versions?.standard?.path
                ?? versions?.id3art?.path
                ?? versions?.premium?.path
                ?? versions?.thumbnail?.path
        }
    }

    let id: Int
    let station: String?
    let slug: String?
    let isOnline: Bool?
    let urls: URLs?
    let title: String
    let link: Link?
    let description: String?
    let language: String?
    let author: String?
    let image: Image?
    let episodeCount: Int?

    var feedURL: URL? { urls?.feed }
}

/// Display names for ORF's station codes. Unknown codes fall back to the
/// uppercased code, so a new station still shows up rather than disappearing.
enum ORFStation {
    static func displayName(for code: String) -> String {
        let names: [String: String] = [
            "oe1": "Ö1",
            "oe3": "Ö3",
            "fm4": "FM4",
            "bgl": "Radio Burgenland",
            "ktn": "Radio Kärnten",
            "noe": "Radio Niederösterreich",
            "ooe": "Radio Oberösterreich",
            "sbg": "Radio Salzburg",
            "stm": "Radio Steiermark",
            "tir": "Radio Tirol",
            "vbg": "Radio Vorarlberg",
            "wie": "Radio Wien",
            "orf": "ORF",
            "tv": "ORF TV"
        ]

        return names[code.lowercased()] ?? code.uppercased()
    }
}
