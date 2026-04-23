//  PodcastSettingsModelActor.swift
//  Raul
//
//  Created by Holger Krupp on 29.06.25.
//

import Foundation
import SwiftData
import BasicLogger

struct AutoDownloadPolicySnapshot: Sendable {
    let keepCount: Int
    let selection: AutoDownloadSelection
    let queuePosition: Playlist.Position
    let playlistID: UUID?
    let networkMode: AutoDownloadNetworkMode
    let includesArchivedEpisodes: Bool
}

@ModelActor
actor PodcastSettingsModelActor {
    private static let includeArchivedEpisodesMigrationKey = "PodcastSettings.autoDownloadIncludesArchivedEpisodes.v1"

    private func logAutoDownload(_ message: String) async {
        await MainActor.run {
            BasicLogger.shared.log("[AutoDL] \(message)")
        }
    }

    private func manualPlaylistExists(id: UUID) -> Bool {
        let descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { $0.id == id }
        )
        guard let playlist = try? modelContext.fetch(descriptor).first else {
            return false
        }
        return playlist.isSmartPlaylist == false
    }

    private func migrateAutoDownloadIncludeArchivedSettingIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.includeArchivedEpisodesMigrationKey) == false else {
            return
        }

        if let settings = try? modelContext.fetch(FetchDescriptor<PodcastSettings>()) {
            for setting in settings {
                setting.autoDownloadIncludesArchivedEpisodes = true
            }
            modelContext.saveIfNeeded()
        }

        defaults.set(true, forKey: Self.includeArchivedEpisodesMigrationKey)
    }

    func ensureStandardSettingsExists() async {
        _ = await standardSettings()
    }
    
    /// Returns a standard global PodcastSettings object (for use as app-wide default)
    func standardSettings() async -> PodcastSettings {
        migrateAutoDownloadIncludeArchivedSettingIfNeeded()
        let defaultPlaylist = Playlist.ensureDefaultQueue(in: modelContext)
        let defaultSettingsTitle = "de.holgerkrupp.podbay.queue"
        var descriptor = FetchDescriptor<PodcastSettings>(
            predicate: #Predicate { $0.title == defaultSettingsTitle }
        )
        descriptor.fetchLimit = 1
        if let result = try? modelContext.fetch(descriptor).first {
            if result.defaultPlaylistID == nil {
                result.defaultPlaylistID = defaultPlaylist.id
                modelContext.saveIfNeeded()
            }
            return result
        } else {
            let newDefaultSettings = PodcastSettings()
            newDefaultSettings.title = defaultSettingsTitle
            newDefaultSettings.defaultPlaylistID = defaultPlaylist.id
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
            newSettings.autoDownload = standardSettings.autoDownload
            newSettings.autoDownloadEpisodeCount = standardSettings.autoDownloadEpisodeCount
            newSettings.autoDownloadSelection = standardSettings.autoDownloadSelection
            newSettings.autoDownloadNetworkMode = standardSettings.autoDownloadNetworkMode
            newSettings.autoDownloadIncludesArchivedEpisodes = standardSettings.autoDownloadIncludesArchivedEpisodes
            newSettings.defaultPlaylistID = standardSettings.defaultPlaylistID
            newSettings.archiveFileRetentionDays = standardSettings.archiveFileRetentionDays
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

    func getDefaultPlaylistID(for podcastFeed: URL?) async -> UUID? {
        guard let podcastFeed else {
            return await standardSettings().defaultPlaylistID
        }

        if let playlistID = await fetchPodcastSettings(for: podcastFeed)?.defaultPlaylistID {
            return playlistID
        }

        return await standardSettings().defaultPlaylistID
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

    func getAutomaticOnDeviceTranscriptionsEnabled() async -> Bool {
        await standardSettings().enableAutomaticOnDeviceTranscriptions
    }

    func getAutomaticOnDeviceTranscriptionsRequiresCharging() async -> Bool {
        await standardSettings().limitAutomaticOnDeviceTranscriptionsToCharging
    }

    func getTranscriptionMaxSnippetDurationSeconds() async -> Double {
        let configuredValue = await standardSettings().transcriptionMaxSnippetDurationSeconds
        return min(max(configuredValue, 0.4), 8.0)
    }

    func getArchiveFileRetentionDays(for podcastFeed: URL?) async -> Int {
        if let podcastFeed,
           let customValue = await fetchPodcastSettings(for: podcastFeed)?.archiveFileRetentionDays {
            return max(customValue, 0)
        }

        return max(await standardSettings().archiveFileRetentionDays, 0)
    }

    func podcastFeedsRequiringAutoDownloadReconciliationOnWiFi() async -> [URL] {
        let descriptor = FetchDescriptor<Podcast>()
        guard let podcasts = try? modelContext.fetch(descriptor),
              podcasts.isEmpty == false else {
            return []
        }

        var feeds = Set<URL>()

        for podcast in podcasts {
            guard podcast.isSubscribed,
                  let feed = podcast.feed,
                  let policy = await autoDownloadPolicy(for: feed),
                  policy.networkMode == .wifiOnly else {
                continue
            }
            feeds.insert(feed)
        }

        return Array(feeds)
    }

    func podcastFeedsRequiringAutoDownloadReconciliation() async -> [URL] {
        let descriptor = FetchDescriptor<Podcast>()
        guard let podcasts = try? modelContext.fetch(descriptor),
              podcasts.isEmpty == false else {
            return []
        }

        var feeds = Set<URL>()

        for podcast in podcasts {
            guard podcast.isSubscribed,
                  let feed = podcast.feed,
                  await autoDownloadPolicy(for: feed) != nil else {
                continue
            }
            feeds.insert(feed)
        }

        return Array(feeds)
    }

    func autoDownloadPolicy(for podcastFeed: URL) async -> AutoDownloadPolicySnapshot? {
        await logAutoDownload("policy-resolution/start feed=\(podcastFeed.absoluteString)")
        guard let podcast = fetchPodcast(podcastFeed) else {
            await logAutoDownload("policy-resolution/none feed=\(podcastFeed.absoluteString) source=podcast reason=podcast-not-found")
            return nil
        }

        guard podcast.isSubscribed else {
            await logAutoDownload("policy-resolution/none feed=\(podcastFeed.absoluteString) source=podcast reason=podcast-unsubscribed")
            return nil
        }

        let customSettings = await fetchPodcastSettings(for: podcastFeed)
        let globalSettings = await standardSettings()
        let settings = (customSettings?.isEnabled == true) ? customSettings : globalSettings
        let source = (customSettings?.isEnabled == true) ? "podcast" : "global"

        guard let settings,
              settings.autoDownload else {
            await logAutoDownload("policy-resolution/none feed=\(podcastFeed.absoluteString) source=\(source) reason=auto-download-disabled")
            return nil
        }

        var didMutateSettings = false

        let ensuredDefaultQueue = Playlist.ensureDefaultQueue(in: modelContext)
        var resolvedGlobalPlaylistID = globalSettings.defaultPlaylistID ?? ensuredDefaultQueue.id
        if manualPlaylistExists(id: resolvedGlobalPlaylistID) == false {
            resolvedGlobalPlaylistID = ensuredDefaultQueue.id
            await logAutoDownload("policy-resolution/repair-global-playlist feed=\(podcastFeed.absoluteString) action=fallback-default-queue")
        }
        if globalSettings.defaultPlaylistID != resolvedGlobalPlaylistID {
            globalSettings.defaultPlaylistID = resolvedGlobalPlaylistID
            didMutateSettings = true
            await logAutoDownload("policy-resolution/repair-global-playlist feed=\(podcastFeed.absoluteString) action=persist-default-playlist id=\(resolvedGlobalPlaylistID.uuidString)")
        }

        var resolvedQueuePosition = settings.playnextPosition
        if resolvedQueuePosition == .none {
            resolvedQueuePosition = .end
            settings.playnextPosition = .end
            didMutateSettings = true
            await logAutoDownload("policy-resolution/repair-queue-position feed=\(podcastFeed.absoluteString) action=none-to-end")
        }

        var resolvedPlaylistID = settings.defaultPlaylistID ?? resolvedGlobalPlaylistID
        if manualPlaylistExists(id: resolvedPlaylistID) == false {
            resolvedPlaylistID = resolvedGlobalPlaylistID
            settings.defaultPlaylistID = resolvedPlaylistID
            didMutateSettings = true
            await logAutoDownload("policy-resolution/repair-target-playlist feed=\(podcastFeed.absoluteString) action=fallback-to-global id=\(resolvedPlaylistID.uuidString)")
        }

        if didMutateSettings {
            modelContext.saveIfNeeded()
            await logAutoDownload("policy-resolution/persisted-repairs feed=\(podcastFeed.absoluteString)")
        }

        await logAutoDownload(
            "policy-resolution/result feed=\(podcastFeed.absoluteString) source=\(source) keep=\(max(settings.autoDownloadEpisodeCount, 1)) selection=\(settings.autoDownloadSelection.rawValue) queuePosition=\(resolvedQueuePosition) playlistID=\(resolvedPlaylistID.uuidString) network=\(settings.autoDownloadNetworkMode.rawValue) includeBackCatalog=\(settings.autoDownloadIncludesArchivedEpisodes)"
        )

        return AutoDownloadPolicySnapshot(
            keepCount: max(settings.autoDownloadEpisodeCount, 1),
            selection: settings.autoDownloadSelection,
            queuePosition: resolvedQueuePosition,
            playlistID: resolvedPlaylistID,
            networkMode: settings.autoDownloadNetworkMode,
            includesArchivedEpisodes: settings.autoDownloadIncludesArchivedEpisodes
        )
    }
}
