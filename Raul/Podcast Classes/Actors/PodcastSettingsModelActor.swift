//  PodcastSettingsModelActor.swift
//  Raul
//
//  Created by Holger Krupp on 29.06.25.
//

import Foundation
import SwiftData

@ModelActor
actor PodcastSettingsModelActor {
    
    /// Returns a standard global PodcastSettings object (for use as app-wide default)
    func standardSettings() async -> PodcastSettings {
        let defaultSettingsTitle = "de.holgerkrupp.podbay.queue"
        var descriptor = FetchDescriptor<PodcastSettings>(
            predicate: #Predicate { $0.title == defaultSettingsTitle }
        )
        descriptor.fetchLimit = 1
        if let result = try? modelContext.fetch(descriptor).first {
            return result
        } else {
            let newDefaultSettings = PodcastSettings()
            newDefaultSettings.title = defaultSettingsTitle
            modelContext.insert(newDefaultSettings)
            modelContext.saveIfNeeded()
            return newDefaultSettings
        }
    }
    
    /// Example: Update a settings object (edit as needed for your app's settings editing UI)
    func updateSettings(_ settingsID: PersistentIdentifier, apply changes: (PodcastSettings) -> Void) {
        guard let settings = modelContext.model(for: settingsID) as? PodcastSettings else { return }
        changes(settings)
        modelContext.saveIfNeeded()
    }
    
    /// Fetch PodcastSettings by PersistentIdentifier
    func fetchSettings(_ settingsID: PersistentIdentifier) -> PodcastSettings? {
        modelContext.model(for: settingsID) as? PodcastSettings
    }
    
    /// Create and insert a new PodcastSettings (optionally for a podcast)
    func createSettings(for podcast: Podcast? = nil) -> PodcastSettings {
        let settings = podcast == nil ? PodcastSettings() : PodcastSettings(podcast: podcast!)
        modelContext.insert(settings)
        modelContext.saveIfNeeded()
        return settings
    }
    
    /// Example: Delete a PodcastSettings object
    func deleteSettings(_ settingsID: PersistentIdentifier) {
        guard let settings = modelContext.model(for: settingsID) as? PodcastSettings else { return }
        modelContext.delete(settings)
        modelContext.saveIfNeeded()
    }
    
    
    func fetchPodcastSettings(for podcastID: UUID) async -> PodcastSettings? {
        let predicate = #Predicate<PodcastSettings> { setting in
            setting.podcast?.id == podcastID
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<PodcastSettings>(predicate: predicate))
            return results.first
        } catch {
            print("❌ Error fetching episode for episode ID: \(podcastID), Error: \(error)")
            return nil
        }
    }
    
    func getPlaybackSpeed(for podcastID: UUID?) async -> Float?{
        guard let podcastID else {
            return await standardSettings().playbackSpeed // is no podcastID is given, the global Settings are returned
        }
        guard let setting = await fetchPodcastSettings(for: podcastID) else {
            return await standardSettings().playbackSpeed // is no podcastID is found, the global Settings are returned
        }
        return setting.playbackSpeed
    }
    
    func setPlaybackSpeed(for podcastID: UUID?, to value: Float) async{
        
        if let podcastID, let setting = await fetchPodcastSettings(for: podcastID) {
             setting.playbackSpeed  = value// is no podcastID is found, the global Settings are returned
        } else {
            await standardSettings().playbackSpeed = value
        }
        modelContext.saveIfNeeded()
    }
    
    
}
