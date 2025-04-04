//
//  Podcast.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import Foundation
import SwiftData

@Model
class Podcast {
    var id = UUID()
    var title: String = "Loading..."
    var desc: String?
    var author: String?
    var feed: URL?
    var episodes: [Episode] = []
    var lastBuildDate: Date?
    var coverImageURL: URL?
    
    init(feed: URL) {
        self.feed = feed
    }
}

@ModelActor
actor PodcastModelActor {
    let container: ModelContainer
    
    init(modelContainer: ModelContainer) {
        self.container = modelContainer
    }

    func updatePodcast(_ podcastID: PersistentIdentifier) async throws {
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return }
        guard let feedURL = podcast.feed else { return }

        let (data, _) = try await URLSession.shared.data(from: feedURL)
        
        let parser = XMLParser(data: data)
        let podcastParser = PodcastParser()
        parser.delegate = podcastParser

        if parser.parse() {
            podcast.title = podcastParser.podcastDictArr["title"] as? String ?? ""
            podcast.author = podcastParser.podcastDictArr["author"] as? String ?? ""
            podcast.desc = podcastParser.podcastDictArr["description"] as? String ?? ""
            
            if let imageURL = podcastParser.podcastDictArr["coverImage"] as? String {
                podcast.coverImageURL = URL(string: imageURL)
            }
            
            podcast.lastBuildDate = Date.dateFromRFC1123(
                dateString: podcastParser.podcastDictArr["lastBuildDate"] as? String ?? ""
            )
            
            // Update episodes
            if let episodesData = podcastParser.podcastDictArr["episodes"] as? [[String: Any]] {
                var newEpisodes: [Episode] = []
                
                for episodeData in episodesData {
                    if let title = episodeData["title"] as? String,
                       let urlString = episodeData["enclosure"] as? [[String: Any]],
                       let firstEnclosure = urlString.first,
                       let urlString = firstEnclosure["url"] as? String,
                       let url = URL(string: urlString),
                       let pubDateString = episodeData["pubDate"] as? String,
                       let pubDate = Date.dateFromRFC1123(dateString: pubDateString) {
                        
                        let episode = Episode(
                            id: UUID(),
                            title: title,
                            publishDate: pubDate,
                            url: url,
                            podcast: podcast
                        )
                        newEpisodes.append(episode)
                    }
                }
                
                // Update episodes array
                podcast.episodes = newEpisodes
            }

            try modelContext.save()
        } else {
            throw parser.parserError ?? NSError(domain: "ParserError", code: -1, userInfo: nil)
        }
    }
    
    func createPodcast(from url: URL) async throws -> Podcast {
        let podcast = Podcast(feed: url)
        modelContext.insert(podcast)
        
        do {
            try await updatePodcast(podcast.persistentModelID)
        } catch {
            print("Could not update podcast: \(error)")
        }
        
        return podcast
    }
    
    func deletePodcast(_ podcastID: PersistentIdentifier) async throws {
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return }
        modelContext.delete(podcast)
        try modelContext.save()
    }
    
    func refreshAllPodcasts() async throws {
        let descriptor = FetchDescriptor<Podcast>()
        let podcasts = try modelContext.fetch(descriptor)
        
        for podcast in podcasts {
            do {
                try await updatePodcast(podcast.persistentModelID)
            } catch {
                print("Failed to update podcast \(podcast.title): \(error)")
            }
        }
    }
}

@Model class Episode {
    var id: UUID
    var title: String
    var publishDate: Date
    var url: URL
    var podcast: Podcast?

    init(id: UUID, title: String, publishDate: Date, url: URL, podcast: Podcast? = nil) {
        self.id = id
        self.title = title
        self.publishDate = publishDate
        self.url = url
        self.podcast = podcast
    }
}
