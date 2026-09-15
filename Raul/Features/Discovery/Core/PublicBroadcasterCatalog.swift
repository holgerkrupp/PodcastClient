//
//  PublicBroadcasterCatalog.swift
//  Raul
//
//  The list of public-service broadcasters the app knows about.
//
//  Being listed here does not make a broadcaster browsable: the registry pairs
//  each entry with a provider, and an entry without one is simply not offered.
//  Adding a broadcaster later is a matter of adding its entry plus its provider —
//  no UI change.
//

import Foundation

enum PublicBroadcasterCatalog {

    static let srf = PublicBroadcaster(
        id: "srf",
        name: "SRF",
        countryCode: "CH",
        region: .europe,
        summary: LocalizedStringResource("German-language radio and podcasts from SRG SSR."),
        website: URL(string: "https://www.srf.ch/audio")
    )

    static let rts = PublicBroadcaster(
        id: "rts",
        name: "RTS",
        countryCode: "CH",
        region: .europe,
        summary: LocalizedStringResource("French-language radio and podcasts from SRG SSR."),
        website: URL(string: "https://www.rts.ch/audio-podcast/")
    )

    static let orf = PublicBroadcaster(
        id: "orf",
        name: "ORF Sound",
        countryCode: "AT",
        region: .europe,
        summary: LocalizedStringResource("Podcasts from Austria's public broadcaster."),
        website: URL(string: "https://sound.orf.at")
    )

    static let rnz = PublicBroadcaster(
        id: "rnz",
        name: "RNZ",
        countryCode: "NZ",
        region: .asiaPacific,
        summary: LocalizedStringResource("Podcasts from Radio New Zealand."),
        website: URL(string: "https://www.rnz.co.nz/podcasts")
    )

    static let rtp = PublicBroadcaster(
        id: "rtp",
        name: "RTP",
        countryCode: "PT",
        region: .europe,
        summary: LocalizedStringResource("Podcasts from Portugal's public broadcaster."),
        website: URL(string: "https://www.rtp.pt/play/podcasts")
    )

    static let ardSounds = PublicBroadcaster(
        id: "ardsounds",
        name: "ARD Sounds",
        countryCode: "DE",
        region: .europe,
        summary: LocalizedStringResource("Podcasts from Germany's public broadcasters."),
        website: URL(string: "https://www.ardsounds.de")
    )

    static let cbc = PublicBroadcaster(
        id: "cbc",
        name: "CBC",
        countryCode: "CA",
        region: .americas,
        summary: LocalizedStringResource("Podcasts from Canada's public broadcaster."),
        website: URL(string: "https://www.cbc.ca/listen/cbc-podcasts")
    )

    static let bbc = PublicBroadcaster(
        id: "bbc",
        name: "BBC",
        countryCode: "GB",
        region: .europe,
        summary: LocalizedStringResource("Podcasts from the British Broadcasting Corporation."),
        website: URL(string: "https://www.bbc.co.uk/sounds/podcasts")
    )

    static let npr = PublicBroadcaster(
        id: "npr",
        name: "NPR",
        countryCode: "US",
        region: .americas,
        summary: LocalizedStringResource("Podcasts from National Public Radio."),
        website: URL(string: "https://www.npr.org/podcasts/")
    )

    static let pbs = PublicBroadcaster(
        id: "pbs",
        name: "PBS",
        countryCode: "US",
        region: .americas,
        summary: LocalizedStringResource("Podcasts from the Public Broadcasting Service."),
        website: URL(string: "https://www.pbs.org/podcasts/")
    )

    static let zdf = PublicBroadcaster(
        id: "zdf",
        name: "ZDF",
        countryCode: "DE",
        region: .europe,
        summary: LocalizedStringResource("Podcasts from Germany's public television broadcaster."),
        website: URL(string: "https://www.zdf.de")
    )

    static let abc = PublicBroadcaster(
        id: "abc",
        name: "ABC",
        countryCode: "AU",
        region: .asiaPacific,
        summary: LocalizedStringResource("Podcasts from the Australian Broadcasting Corporation."),
        website: URL(string: "https://www.abc.net.au/listen/podcasts")
    )

    static let rte = PublicBroadcaster(
        id: "rte",
        name: "RTÉ",
        countryCode: "IE",
        region: .europe,
        summary: LocalizedStringResource("Podcasts from Ireland's public broadcaster."),
        website: URL(string: "https://www.rte.ie/radio/podcasts/")
    )

    static let npo = PublicBroadcaster(
        id: "npo",
        name: "NPO",
        countryCode: "NL",
        region: .europe,
        summary: LocalizedStringResource("Podcasts from the Dutch public broadcasters."),
        website: URL(string: "https://www.nporadio1.nl/podcasts")
    )

    static let sverigesRadio = PublicBroadcaster(
        id: "sverigesradio",
        name: "Sveriges Radio",
        countryCode: "SE",
        region: .europe,
        summary: LocalizedStringResource("Podcasts from Sweden's public radio."),
        website: URL(string: "https://sverigesradio.se/podcaster")
    )

    static let vrt = PublicBroadcaster(
        id: "vrt",
        name: "VRT",
        countryCode: "BE",
        region: .europe,
        summary: LocalizedStringResource("Podcasts from Flanders' public broadcaster."),
        website: URL(string: "https://www.vrt.be/vrtmax/luister/")
    )

    /// Broadcasters the architecture already models but that have no provider
    /// yet. They are kept here so adding one later is a one-line change, and are
    /// never shown as if they were browsable.
    static let plannedBroadcasters: [PublicBroadcaster] = [
        // RSI and RTR are modelled but not offered: SRG's API publishes no
        // podcast feed for either, so their shows could not be subscribed to.
        PublicBroadcaster(
            id: "rsi",
            name: "RSI",
            countryCode: "CH",
            region: .europe,
            summary: LocalizedStringResource("Italian-language radio and podcasts from SRG SSR."),
            website: URL(string: "https://www.rsi.ch/play/audio")
        ),
        PublicBroadcaster(
            id: "rtr",
            name: "RTR",
            countryCode: "CH",
            region: .europe,
            summary: LocalizedStringResource("Romansh-language radio and podcasts from SRG SSR."),
            website: URL(string: "https://www.rtr.ch/audio")
        ),
        PublicBroadcaster(
            id: "radiofrance",
            name: "Radio France",
            countryCode: "FR",
            region: .europe,
            summary: LocalizedStringResource("Podcasts from France's public radio."),
            website: URL(string: "https://www.radiofrance.fr/podcasts")
        ),
        PublicBroadcaster(
            id: "yle",
            name: "Yle",
            countryCode: "FI",
            region: .europe,
            summary: LocalizedStringResource("Podcasts from Finland's public broadcaster."),
            website: URL(string: "https://areena.yle.fi/podcastit")
        ),
        PublicBroadcaster(
            id: "rtve",
            name: "RTVE",
            countryCode: "ES",
            region: .europe,
            summary: LocalizedStringResource("Podcasts from Spain's public broadcaster."),
            website: URL(string: "https://www.rtve.es/play/radio/")
        ),
        PublicBroadcaster(
            id: "rai",
            name: "RAI",
            countryCode: "IT",
            region: .europe,
            summary: LocalizedStringResource("Podcasts from Italy's public broadcaster."),
            website: URL(string: "https://www.raiplaysound.it/podcast")
        ),
    ]

    /// Every broadcaster the app knows about, browsable or not.
    static let all: [PublicBroadcaster] = [
        srf, rts, orf, rnz, rtp, ardSounds,
        bbc, rte, npo, sverigesRadio, vrt, zdf,
        npr, pbs, cbc,
        abc
    ] + plannedBroadcasters
}
