//  PodcastSettingsModelActor.swift
//  Raul
//
//  Created by Holger Krupp on 29.06.25.
//

import Foundation
import SwiftData
import BasicLogger

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
    
    func fetchPodcast(_ podcastID: UUID) -> Podcast? {
        let predicate = #Predicate<Podcast> { podcast in
            podcast.id == podcastID
        }
        do {
            let results = try modelContext.fetch(FetchDescriptor<Podcast>(predicate: predicate))
            return results.first
        } catch {
            print("❌ Error fetching episode for episode ID: \(podcastID), Error: \(error)")
            return nil
        }
    }
    
    
    /// Create and insert a new PodcastSettings (optionally for a podcast)
    func createSettings(for podcastID: UUID) async -> PodcastSettings? {
        print("PodcastSettingsModelActor - createSettings for podcastID: \(podcastID)")
        if let settings = await fetchPodcastSettings(for: podcastID){
            modelContext.insert(settings)
            modelContext.saveIfNeeded()
            return settings
        }else if let podcast = fetchPodcast(podcastID){
            let settings = PodcastSettings(podcast: podcast)
            modelContext.insert(settings)
            podcast.settings = settings

            modelContext.saveIfNeeded()
            return settings
        }else{
            return nil
        }
    }
    
    /// Example: Delete a PodcastSettings object
    func deleteSettings(_ settingsID: PersistentIdentifier) {
        guard let settings = modelContext.model(for: settingsID) as? PodcastSettings else { return }
        modelContext.delete(settings)
        modelContext.saveIfNeeded()
    }
    

    func fetchAllPodcastSettings() async -> [PodcastSettings] {
        print("FETCHING ALL PODCASTSETTINGS")
        do {
            let results = try modelContext.fetch(FetchDescriptor<PodcastSettings>())
            for result in results{
                print("⚙️ - Found custom Settings: \(result.title ?? "nil") - \(result.id.uuidString) - Podcast: \(result.podcast?.title ?? "nil") - \(result.podcast?.id.uuidString ?? "NIL")")
            }
            print("----")
            return results
        } catch {
            print("❌ Error fetching episode for episode ID: \(error)")
            return []
        }
    }
    
    
    func fetchPodcastSettings(for podcastID: UUID) async -> PodcastSettings? {
    //    await fetchAllPodcastSettings()
        await BasicLogger.shared.log("Fetching custom Settings for Podcast with ID: \(podcastID)")
        let predicate = #Predicate<PodcastSettings> { setting in
            setting.podcast?.id == podcastID &&
            setting.isEnabled == true
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<PodcastSettings>(predicate: predicate))
            print(predicate.debugDescription)
            await BasicLogger.shared.log("Found \(results.count) custom Settings for Podcast with ID: (\(podcastID) - \(results.first?.title ?? "nil")")
            return results.first
        } catch {
            print("❌ Error fetching episode for episode ID: \(podcastID), Error: \(error)")
            return nil
        }
    }
    
    
    
    func getPlaybackSpeed(for podcastID: UUID?) async -> Float?{
        
        guard let podcastID else {
            await BasicLogger.shared.log("no PodcastID - standard PlaybackSpeed")
            return await standardSettings().playbackSpeed // is no podcastID is given, the global Settings are returned
        }
        guard let playbackSpeed = await fetchPodcastSettings(for: podcastID)?.playbackSpeed else {
            await BasicLogger.shared.log("no Podcast Settings - standard PlaybackSpeed")

            return await standardSettings().playbackSpeed // is no podcastID is found, the global Settings are returned
        }
        await BasicLogger.shared.log("custom PlaybackSpeed: \(playbackSpeed.formatted())")

        return playbackSpeed
    }
    
    func setPlaybackSpeed(for podcastID: UUID?, to value: Float) async{
        
        if let podcastID, let setting = await fetchPodcastSettings(for: podcastID) {
             setting.playbackSpeed  = value// is no podcastID is found, the global Settings are returned
        } else {
            await standardSettings().playbackSpeed = value
        }
        modelContext.saveIfNeeded()
    }
    
    func getPlaynextposition(for podcastID: UUID?) async -> Playlist.Position{
        await BasicLogger.shared.log("getPlaynextposition for PodcastID: \(String(describing: podcastID))")
        guard let podcastID else {
            await BasicLogger.shared.log("getPlaynextposition no PodcastID - standard Playnextposition")
            return await standardSettings().playnextPosition
        }
        if let position =  await fetchPodcastSettings(for: podcastID)?.playnextPosition {
            await BasicLogger.shared.log("getPlaynextposition PodcastID - position: \(position)")

            return position
        }else{
            await BasicLogger.shared.log("getPlaynextposition no result - standard Playnextposition 2")

            return await standardSettings().playnextPosition
        }
    }
}
