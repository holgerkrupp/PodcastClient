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
    
    func fetchPodcast(_ podcastFeed: URL) -> Podcast? {
        let predicate = #Predicate<Podcast> { podcast in
            podcast.feed == podcastFeed
        }
        do {
            let results = try modelContext.fetch(FetchDescriptor<Podcast>(predicate: predicate))
            return results.first
        } catch {
            // print("❌ Error fetching episode for episode ID: \(podcastID), Error: \(error)")
            return nil
        }
    }
    
    
    /// Create and insert a new PodcastSettings (optionally for a podcast)
    func createSettings(for podcastFeed: URL) async -> PodcastSettings? {
        // print("PodcastSettingsModelActor - createSettings for podcastID: \(podcastID)")
        if let settings = await fetchPodcastSettings(for: podcastFeed){
            modelContext.insert(settings)
            modelContext.saveIfNeeded()
            return settings
        }else if let podcast = fetchPodcast(podcastFeed){
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
        // print("FETCHING ALL PODCASTSETTINGS")
        do {
            let results = try modelContext.fetch(FetchDescriptor<PodcastSettings>())
            for result in results{
                // print("⚙️ - Found custom Settings: \(result.title ?? "nil") - \(result.id.uuidString) - Podcast: \(result.podcast?.title ?? "nil") - \(result.podcast?.id.uuidString ?? "NIL")")
            }
            // print("----")
            return results
        } catch {
            // print("❌ Error fetching episode for episode ID: \(error)")
            return []
        }
    }
    
    
    func fetchPodcastSettings(for podcastFeed: URL) async -> PodcastSettings? {
    //    await fetchAllPodcastSettings()
       //  await BasicLogger.shared.log("Fetching custom Settings for Podcast with ID: \(podcastID)")
        let predicate = #Predicate<PodcastSettings> { setting in
            setting.podcast?.feed == podcastFeed &&
            setting.isEnabled == true
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<PodcastSettings>(predicate: predicate))
            // print(predicate.debugDescription)
           //  await BasicLogger.shared.log("Found \(results.count) custom Settings for Podcast with ID: (\(podcastID) - \(results.first?.title ?? "nil")")
            return results.first
        } catch {
            // print("❌ Error fetching episode for episode ID: \(podcastID), Error: \(error)")
            return nil
        }
    }
    
    /// Enable custom settings for a podcast (creates or re-enables custom settings)
    func enableCustomSettings(for podcastFeed: URL) async {
        guard let podcast = fetchPodcast(podcastFeed) else { return }

        // Try to find existing settings for this podcast
        let predicate = #Predicate<PodcastSettings> {
            $0.podcast?.feed == podcastFeed
        }
        let existingSettings = (try? modelContext.fetch(FetchDescriptor<PodcastSettings>(predicate: predicate)).first)

        if let settings = existingSettings {
            settings.isEnabled = true
            podcast.settings = settings
        } else {
            let newSettings = PodcastSettings(podcast: podcast)
            let standardSettings = await standardSettings()
            newSettings.isEnabled = true
            newSettings.playbackSpeed = standardSettings.playbackSpeed
            newSettings.playnextPosition = standardSettings.playnextPosition
            newSettings.autoSkipKeywords = standardSettings.autoSkipKeywords
            modelContext.insert(newSettings)
            podcast.settings = newSettings
        }
        modelContext.saveIfNeeded()
    }

    /// Disable custom settings for a podcast
    func disableCustomSettings(for podcastFeed: URL) async {
        guard let podcast = fetchPodcast(podcastFeed) else { return }
        if let settings = podcast.settings {
            settings.isEnabled = false
        }
        modelContext.saveIfNeeded()
    }
    
    func getChapterSkipKeywords(for podcastFeed: URL?) async -> [skipKey]?{
        guard let podcastFeed ,let playbackSpeed = await fetchPodcastSettings(for: podcastFeed)?.autoSkipKeywords  else {
           //  await BasicLogger.shared.log("getChapterSkipKeywords no PodcastID -> standard")
            return await standardSettings().autoSkipKeywords
        }
        return playbackSpeed
    }
    
    func setChapterSkipKeywords(for podcastFeed: URL?, to value: [skipKey]) async {
        guard let podcastFeed  else {
           //  await BasicLogger.shared.log("no PodcastID - not saving")
            return
        }
        guard let settings = await fetchPodcastSettings(for: podcastFeed) else {
           //  await BasicLogger.shared.log("no Podcast Settings - not saving")
            return
        }
        
        settings.autoSkipKeywords = value
    }
    
    
    func getPlaybackSpeed(for podcastFeed: URL?) async -> Float{
        
        guard let podcastFeed  else {
           //  await BasicLogger.shared.log("no PodcastID - standard PlaybackSpeed")
            return await standardSettings().playbackSpeed ?? 1.0 // is no podcastID is given, the global Settings are returned
        }
        guard let playbackSpeed = await fetchPodcastSettings(for: podcastFeed)?.playbackSpeed else {
           //  await BasicLogger.shared.log("no Podcast Settings - standard PlaybackSpeed")

            return await standardSettings().playbackSpeed ?? 1.0 // is no podcastID is found, the global Settings are returned
        }
       //  await BasicLogger.shared.log("custom PlaybackSpeed: \(playbackSpeed.formatted())")

        return playbackSpeed
    }
    
    func setPlaybackSpeed(for podcastFeed: URL?, to value: Float) async{
        
        if let podcastFeed, let setting = await fetchPodcastSettings(for: podcastFeed) {
             setting.playbackSpeed  = value// is no podcastID is found, the global Settings are returned
        } else {
            await standardSettings().playbackSpeed = value
        }
        modelContext.saveIfNeeded()
    }
    
    func getPlaynextposition(for podcastFeed: URL?) async -> Playlist.Position{
       //  await BasicLogger.shared.log("getPlaynextposition for PodcastID: \(String(describing: podcastID))")
        guard let podcastFeed else {
           //  await BasicLogger.shared.log("getPlaynextposition no PodcastID - standard Playnextposition")
            return await standardSettings().playnextPosition
        }
        if let position =  await fetchPodcastSettings(for: podcastFeed)?.playnextPosition {
           //  await BasicLogger.shared.log("getPlaynextposition PodcastID - position: \(position)")

            return position
        }else{
           //  await BasicLogger.shared.log("getPlaynextposition no result - standard Playnextposition 2")

            return await standardSettings().playnextPosition
        }
    }
    
    func getContiniousPlay() async -> Bool{
        return await standardSettings().getContinuousPlay
    }
    
    func getAppSliderEnable() async -> Bool{
        return await standardSettings().enableInAppSlider
    }
    
    func getLockScreenSliderEnable() async -> Bool{
        return await standardSettings().enableLockscreenSlider

    }
}

