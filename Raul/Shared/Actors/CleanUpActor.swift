//
//  CleanUpActor.swift
//  Raul
//
//  Created by AI Assistant on 25.07.25.
//

import Foundation
import SwiftData

@ModelActor
actor CleanUpActor {
    lazy var episodeActor: EpisodeActor = EpisodeActor(modelContainer: self.modelContainer)
    lazy var settingsActor: PodcastSettingsModelActor = PodcastSettingsModelActor(modelContainer: self.modelContainer)

    /// Deletes downloaded episode files once they are eligible for cleanup.
    func cleanUpOldDownloads() async {
        let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date.distantPast
        let fetchDescriptor = FetchDescriptor<EpisodeMetaData>(
            predicate: #Predicate<EpisodeMetaData> { metadata in
                metadata.isAvailableLocally == true
                && (metadata.isArchived == true || (metadata.lastPlayed ?? oneWeekAgo) < oneWeekAgo)
            }
        )
        let metadataRecords: [EpisodeMetaData]
        do {
            metadataRecords = try modelContext.fetch(fetchDescriptor)
        } catch {
            return
        }

        let now = Date()
        var retentionDaysByFeed: [String: Int] = [:]
        var queuedEpisodeURLs: Set<URL>? = nil

        func queuedEpisodeURLSet() -> Set<URL> {
            if let queuedEpisodeURLs {
                return queuedEpisodeURLs
            }

            let playlistEntries = (try? modelContext.fetch(FetchDescriptor<PlaylistEntry>())) ?? []
            let urls = Set(playlistEntries.compactMap { $0.episode?.url })
            queuedEpisodeURLs = urls
            return urls
        }

        for metadata in metadataRecords {
            let isArchived = metadata.isArchived == true
            let isStaleUnarchived: Bool
            if let lastPlayed = metadata.lastPlayed {
                isStaleUnarchived = lastPlayed < oneWeekAgo
            } else {
                isStaleUnarchived = false
            }

            guard isArchived || isStaleUnarchived else { continue }
            guard let episode = metadata.episode else { continue }
            guard episode.source != .sideLoaded else { continue }
            guard let episodeURL = episode.url else { continue }

            if isArchived {
                let feedKey = episode.podcast?.feed?.absoluteString ?? "__global__"
                let retentionDays: Int
                if let cachedValue = retentionDaysByFeed[feedKey] {
                    retentionDays = cachedValue
                } else {
                    let resolvedValue = await settingsActor.getArchiveFileRetentionDays(for: episode.podcast?.feed)
                    retentionDaysByFeed[feedKey] = resolvedValue
                    retentionDays = resolvedValue
                }

                let archivedAt = metadata.archivedAt
                    ?? metadata.completionDate
                    ?? metadata.lastPlayed
                    ?? now
                let earliestDeletionDate = Calendar.current.date(byAdding: .day, value: retentionDays, to: archivedAt) ?? archivedAt

                guard earliestDeletionDate <= now else { continue }
                await episodeActor.deleteFile(episodeURL: episodeURL)
                continue
            }

            guard queuedEpisodeURLSet().contains(episodeURL) == false else { continue }
            await episodeActor.deleteFile(episodeURL: episodeURL)
        }
    }
}
