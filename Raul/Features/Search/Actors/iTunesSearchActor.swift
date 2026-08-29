//
//  iTunesSearchActor.swift
//  Raul
//
//  Apple Podcasts directory client: search, genre/category browsing and
//  top-chart ("hot") podcasts. Replaces the retired fyyd directory.
//
//  Created by Holger Krupp on 11.08.25.
//

import Foundation

/// A node in the Apple Podcasts genre tree (used for category browsing).
struct AppleGenre: Identifiable, Hashable {
    let id: Int
    let name: String
    let subgenres: [AppleGenre]

    var hasSubgenres: Bool { !subgenres.isEmpty }

    /// An SF Symbol representing the genre. Mapped by id so it survives
    /// localization of the genre name; subgenres fall back to a podcast glyph.
    var symbolName: String {
        Self.symbolsByGenreID[id] ?? "dot.radiowaves.left.and.right"
    }

    private static let symbolsByGenreID: [Int: String] = [
        // Arts
        1301: "paintpalette",
        1306: "fork.knife",                         // Food
        1402: "pencil.and.ruler",                   // Design
        1405: "music.mic",                          // Performing Arts
        1406: "photo.artframe",                     // Visual Arts
        1459: "tshirt",                             // Fashion & Beauty
        1482: "book",                               // Books

        // Comedy
        1303: "theatermasks",
        1495: "bubble.left.and.bubble.right",       // Improv
        1496: "mic",                                // Comedy Interviews
        1497: "figure.stand",                       // Stand-Up

        // Education
        1304: "graduationcap",
        1498: "character.bubble",                   // Language Learning
        1499: "wrench.and.screwdriver",             // How To
        1500: "figure.mind.and.body",               // Self-Improvement
        1501: "book.closed",                        // Courses

        // Kids & Family
        1305: "figure.2.and.child.holdinghands",
        1519: "abc",                                // Education for Kids
        1520: "book.pages",                         // Stories for Kids
        1521: "figure.2.and.child.holdinghands",    // Parenting
        1522: "pawprint",                           // Pets & Animals

        // TV & Film
        1309: "film",
        1561: "tv",                                 // TV Reviews
        1562: "popcorn",                            // After Shows
        1563: "star.bubble",                        // Film Reviews
        1564: "film.stack",                         // Film History
        1565: "mic",                                // Film Interviews

        // Music
        1310: "music.note",
        1523: "text.bubble",                        // Music Commentary
        1524: "music.note.list",                    // Music History
        1525: "music.mic",                          // Music Interviews

        // Religion & Spirituality
        1314: "hands.sparkles",
        1438: "leaf",                               // Buddhism
        1439: "cross",                              // Christianity
        1440: "moon.stars",                         // Islam
        1441: "star",                               // Judaism
        1444: "hands.sparkles",                     // Spirituality
        1463: "flame",                              // Hinduism
        1532: "book.closed",                        // Religion

        // Technology
        1318: "cpu",

        // Business
        1321: "briefcase",
        1410: "person.text.rectangle",              // Careers
        1412: "chart.line.uptrend.xyaxis",          // Investing
        1491: "person.2.badge.gearshape",           // Management
        1492: "megaphone",                          // Marketing
        1493: "lightbulb",                          // Entrepreneurship
        1494: "hand.raised",                        // Non-Profit

        // Society & Culture
        1324: "person.3",
        1302: "pencil.line",                        // Personal Journals
        1320: "airplane",                           // Places & Travel
        1443: "brain",                              // Philosophy
        1543: "video",                              // Documentary
        1544: "heart",                              // Relationships

        // Fiction
        1483: "books.vertical",
        1484: "theatermasks",                       // Drama
        1485: "moon.stars",                         // Science Fiction
        1486: "face.smiling",                       // Comedy Fiction

        // History
        1487: "scroll",

        // True Crime
        1488: "magnifyingglass",

        // News
        1489: "newspaper",
        1490: "chart.bar",                          // Business News
        1526: "sun.max",                            // Daily News
        1527: "building.columns",                   // Politics
        1528: "cpu",                                // Tech News
        1529: "sportscourt",                        // Sports News
        1530: "text.bubble",                        // News Commentary
        1531: "star",                               // Entertainment News

        // Leisure
        1502: "gamecontroller",
        1503: "car",                                // Automotive
        1504: "airplane",                           // Aviation
        1505: "puzzlepiece",                        // Hobbies
        1506: "scissors",                           // Crafts
        1507: "dice",                               // Games
        1508: "house",                              // Home & Garden
        1509: "gamecontroller",                     // Video Games
        1510: "play.rectangle",                     // Animation & Manga

        // Government
        1511: "building.columns",

        // Health & Fitness
        1512: "heart",
        1513: "leaf",                               // Alternative Health
        1514: "figure.run",                         // Fitness
        1515: "carrot",                             // Nutrition
        1516: "heart.circle",                       // Sexuality
        1517: "brain.head.profile",                 // Mental Health
        1518: "cross.case",                         // Medicine

        // Science
        1533: "atom",
        1534: "leaf",                               // Natural Sciences
        1535: "person.2",                           // Social Sciences
        1536: "x.squareroot",                       // Mathematics
        1537: "tree",                               // Nature
        1538: "moon.stars",                         // Astronomy
        1539: "testtube.2",                         // Chemistry
        1540: "globe.americas",                     // Earth Sciences
        1541: "ladybug",                            // Life Sciences
        1542: "atom",                               // Physics

        // Sports
        1545: "sportscourt",
        1546: "figure.soccer",                      // Soccer
        1547: "figure.american.football",           // Football
        1548: "figure.basketball",                  // Basketball
        1549: "figure.baseball",                    // Baseball
        1550: "figure.hockey",                      // Hockey
        1551: "figure.run",                         // Running
        1552: "figure.rugby",                       // Rugby
        1553: "figure.golf",                        // Golf
        1554: "figure.cricket",                     // Cricket
        1555: "figure.wrestling",                   // Wrestling
        1556: "figure.tennis",                      // Tennis
        1557: "figure.volleyball",                  // Volleyball
        1558: "figure.pool.swim",                   // Swimming
        1559: "figure.hiking",                      // Wilderness
        1560: "trophy"                              // Fantasy Sports
    ]
}

actor ITunesSearchActor {

    /// Storefront country code (ISO 3166-1 alpha-2, lowercased), e.g. "us", "de".
    private var country: String

    init(country: String? = nil) {
        let resolved = country
            ?? Locale.autoupdatingCurrent.region?.identifier
            ?? "US"
        self.country = resolved.lowercased()
    }

    func setCountry(_ code: String) {
        country = code.lowercased()
    }

    // MARK: - Search

    func search(for term: String) async -> [PodcastFeed]? {
        guard term.isEmpty == false else { return nil }
        guard let encodedTerm = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }

        let urlString = "https://itunes.apple.com/search?term=\(encodedTerm)&media=podcast&country=\(country)"
        guard let requestURL = URL(string: urlString) else { return nil }

        guard let json = await fetchJSON(from: requestURL) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return nil
        }

        return results.compactMap { feed(from: $0) }
    }

    // MARK: - Categories / genres

    /// Returns the Apple Podcasts genre tree (top-level genres with their subgenres).
    func getGenres() async -> [AppleGenre] {
        let urlString = "https://itunes.apple.com/WebObjects/MZStoreServices.woa/ws/genres?id=26&cc=\(country)"
        guard let requestURL = URL(string: urlString) else { return [] }

        guard let json = await fetchJSON(from: requestURL) as? [String: Any],
              let podcasts = json["26"] as? [String: Any] else {
            return []
        }

        return parseSubgenres(from: podcasts)
    }

    private func parseSubgenres(from node: [String: Any]) -> [AppleGenre] {
        guard let subgenres = node["subgenres"] as? [String: Any] else { return [] }

        let genres: [AppleGenre] = subgenres.values.compactMap { value in
            guard let dict = value as? [String: Any],
                  let idString = dict["id"] as? String,
                  let id = Int(idString),
                  let name = dict["name"] as? String else {
                return nil
            }
            return AppleGenre(id: id, name: name, subgenres: parseSubgenres(from: dict))
        }

        return genres.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Top / "hot" podcasts

    /// Returns the top podcasts chart, optionally filtered to a genre.
    /// - Parameters:
    ///   - genreID: An Apple genre id, or `nil` for the overall chart.
    ///   - limit: Maximum number of podcasts to return.
    func getTopPodcasts(genreID: Int? = nil, limit: Int = 50) async -> [PodcastFeed] {
        var urlString = "https://itunes.apple.com/\(country)/rss/toppodcasts/limit=\(limit)"
        if let genreID {
            urlString += "/genre=\(genreID)"
        }
        urlString += "/json"

        guard let requestURL = URL(string: urlString) else { return [] }

        guard let json = await fetchJSON(from: requestURL) as? [String: Any],
              let feed = json["feed"] as? [String: Any] else {
            return []
        }

        // `entry` is an array, or a single object when the chart has one item.
        let entries: [[String: Any]]
        if let array = feed["entry"] as? [[String: Any]] {
            entries = array
        } else if let single = feed["entry"] as? [String: Any] {
            entries = [single]
        } else {
            entries = []
        }

        let ids: [String] = entries.compactMap { entry in
            (entry["id"] as? [String: Any])?["attributes"] as? [String: Any]
        }.compactMap { $0["im:id"] as? String }

        guard ids.isEmpty == false else { return [] }

        return await lookupPodcasts(ids: ids)
    }

    // MARK: - Lookup

    /// Resolves Apple collection ids into `PodcastFeed`s (which carry the RSS `feedUrl`),
    /// preserving the order of the supplied ids.
    private func lookupPodcasts(ids: [String]) async -> [PodcastFeed] {
        let joined = ids.joined(separator: ",")
        let urlString = "https://itunes.apple.com/lookup?id=\(joined)&country=\(country)&entity=podcast"
        guard let requestURL = URL(string: urlString) else { return [] }

        guard let json = await fetchJSON(from: requestURL) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        var feedsByID: [String: PodcastFeed] = [:]
        for result in results {
            guard let feed = feed(from: result) else { continue }
            if let trackID = result["trackId"] as? Int {
                feedsByID[String(trackID)] = feed
            } else if let collectionID = result["collectionId"] as? Int {
                feedsByID[String(collectionID)] = feed
            }
        }

        // Preserve chart ordering.
        return ids.compactMap { feedsByID[$0] }
    }

    // MARK: - Mapping helpers

    /// Builds a `PodcastFeed` from an iTunes Search/Lookup result entry.
    private func feed(from podcast: [String: Any]) -> PodcastFeed? {
        guard let urlString = podcast["feedUrl"] as? String,
              let url = URL(string: urlString) else {
            return nil
        }

        let newFeed = PodcastFeed(url: url, fetchMetadataIfNeeded: false)
        newFeed.source = .iTunes
        newFeed.artist = podcast["artistName"] as? String
        newFeed.title = podcast["collectionName"] as? String
        let artworkString = (podcast["artworkUrl600"] as? String)
            ?? (podcast["artworkUrl100"] as? String)
            ?? ""
        newFeed.artworkURL = URL(string: artworkString)
        newFeed.lastRelease = ISO8601DateFormatter().date(from: podcast["releaseDate"] as? String ?? "")
        return newFeed
    }

    private func fetchJSON(from url: URL) async -> Any? {
        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            return try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return nil
        }
    }
}
