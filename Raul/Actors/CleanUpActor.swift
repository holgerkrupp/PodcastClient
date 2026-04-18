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
        let fetchDescriptor = FetchDescriptor<Episode>()
        let context = ModelContext(self.modelContainer)
        let episodes: [Episode]
        do {
            episodes = try context.fetch(fetchDescriptor)
        } catch {
            return
        }

        let now = Date()
        
        for episode in episodes {
            guard episode.source != .sideLoaded else { continue }
            guard episode.metaData?.isAvailableLocally == true else { continue }

            if episode.metaData?.isArchived == true {
                let retentionDays = await settingsActor.getArchiveFileRetentionDays(for: episode.podcast?.feed)
                let archivedAt = episode.metaData?.archivedAt
                    ?? episode.metaData?.completionDate
                    ?? episode.metaData?.lastPlayed
                    ?? now
                let earliestDeletionDate = Calendar.current.date(byAdding: .day, value: retentionDays, to: archivedAt) ?? archivedAt

                guard earliestDeletionDate <= now else { continue }
                await episodeActor.deleteFile(episodeURL: episode.url)
                continue
            }

            guard let lastPlayed = episode.metaData?.lastPlayed, lastPlayed < oneWeekAgo else { continue }
            if episode.playlist?.count == 0 {
                await episodeActor.deleteFile(episodeURL: episode.url)
            }
        }
    }
}
