//
//  ApplePublisherRules.swift
//  Raul
//
//  How each Apple-catalogue-backed broadcaster is recognised.
//
//  Publisher names are messy and collide between broadcasters, so every rule is
//  written out rather than derived from the broadcaster's name. A prefix is used
//  only where the stem is distinctive enough to belong to one broadcaster; where
//  it is not ("ABC News" is both Australian and American, "PBS" has unrelated
//  regional and Thai namesakes), the publishers are listed exactly instead.
//
//  Several narrow queries find more than one broad one, because Apple's result
//  list is capped and relevance-ranked.
//

import Foundation

enum ApplePublisherRules {
    static let bbc = ApplePublisherRule(
        storefront: "gb",
        queries: ["BBC", "BBC Radio 4", "BBC Sounds", "BBC World Service", "BBC Radio 5 Live", "BBC Radio 3"],
        publisherPrefixes: ["BBC"]
    )

    static let npr = ApplePublisherRule(
        storefront: "us",
        queries: ["NPR", "NPR news", "NPR music"],
        exactPublishers: ["NPR"]
    )

    static let sverigesRadio = ApplePublisherRule(
        storefront: "se",
        queries: ["Sveriges Radio", "Sveriges Radio P1", "Sveriges Radio P3"],
        exactPublishers: ["Sveriges Radio"]
    )

    static let rte = ApplePublisherRule(
        storefront: "ie",
        queries: ["RTÉ", "RTE Radio 1", "RTÉ Documentary"],
        publisherPrefixes: ["RTÉ", "RTE"]
    )

    static let npo = ApplePublisherRule(
        storefront: "nl",
        queries: ["NPO Luister", "NPO Radio 1", "NPO"],
        publisherPrefixes: ["NPO"]
    )

    /// Exact names only: "ABC News" is an American publisher as well.
    static let abc = ApplePublisherRule(
        storefront: "au",
        queries: ["ABC listen", "ABC Radio Australia", "ABC Australia"],
        exactPublishers: ["ABC Australia", "ABC Radio Australia", "ABC Podcasts", "ABC listen"]
    )

    /// Exact names only: Thai PBS, Iowa PBS and Cascade PBS are different
    /// organizations that would otherwise be swept in by a prefix.
    static let pbs = ApplePublisherRule(
        storefront: "us",
        queries: ["PBS", "PBS News"],
        exactPublishers: ["PBS", "PBS News", "PBS NewsHour", "PBS KIDS", "PBS Nature"]
    )

    /// ZDF publishes under a family of "ZDF …" imprints. The prefix is
    /// distinctive, and it deliberately excludes "funk – von ARD und ZDF":
    /// funk is a joint venture that already appears in ARD's own catalogue.
    static let zdf = ApplePublisherRule(
        storefront: "de",
        queries: [
            "ZDF", "ZDF Podcast", "ZDFheute", "Terra X",
            "Markus Lanz", "auslandsjournal", "Aktenzeichen XY", "ZDF frontal"
        ],
        publisherPrefixes: ["ZDF"]
    )

    static let vrt = ApplePublisherRule(
        storefront: "be",
        queries: ["VRT MAX", "VRT NWS"],
        publisherPrefixes: ["VRT"]
    )
}
