//  PodcastSettingsModelActor.swift
//  Raul
//
//  Created by Holger Krupp on 29.06.25.
//

import Foundation
import SwiftData

/// A subscribed podcast whose new episodes land in one particular playlist.
struct PlaylistRoutedPodcast: Sendable, Identifiable, Hashable {
    /// The feed URL, which is how podcasts are addressed everywhere else here —
    /// `Podcast.id` is a `PersistentIdentifier` and cannot leave its context.
    let id: URL
    let title: String
    let imageURL: URL?
    let position: Playlist.Position
    /// Whether the routing comes from this podcast's own settings rather than
    /// from the global default.
    let usesCustomSettings: Bool
}

struct AutoDownloadPolicySnapshot: Sendable {
    let keepCount: Int
    let selection: AutoDownloadSelection
    let queuePosition: Playlist.Position
    let playlistID: UUID?
    let networkMode: AutoDownloadNetworkMode
    let includesArchivedEpisodes: Bool
    let episodeFilter: AutoDownloadEpisodeFilter
}

@ModelActor
actor PodcastSettingsModelActor {
    private static let includeArchivedEpisodesMigrationKey = "PodcastSettings.autoDownloadIncludesArchivedEpisodes.v1"

    private func logAutoDownload(_ message: String) async {
        await MainActor.run {
            AppDiagnostics.log("[AutoDL] \(message)")
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

    private func defaultQueueID() -> UUID {
        let defaultQueueTitle = Playlist.defaultQueueTitle
        let descriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { $0.title == defaultQueueTitle }
        )

        if let playlist = try? modelContext.fetch(descriptor).first {
            var changed = false
            if playlist.deleteable {
                playlist.deleteable = false
                changed = true
            }
            if playlist.hidden {
                playlist.hidden = false
                changed = true
            }
            if playlist.kind != .manual {
                playlist.kind = .manual
                changed = true
            }
            if playlist.sortIndex != 0 {
                playlist.sortIndex = 0
                changed = true
            }
            if playlist.symbolName.isEmpty || playlist.symbolName == Playlist.defaultManualSymbolName {
                playlist.symbolName = Playlist.defaultQueueSymbolName
                changed = true
            }
            if playlist.smartFilter != nil {
                playlist.smartFilter = nil
                changed = true
            }
            if changed {
                modelContext.saveIfNeeded()
            }
            return playlist.id
        }

        let defaultQueueDisplayName = Playlist.defaultQueueDisplayName
        let legacyDescriptor = FetchDescriptor<Playlist>(
            predicate: #Predicate<Playlist> { $0.title == defaultQueueDisplayName }
        )

        if let legacyPlaylist = try? modelContext.fetch(legacyDescriptor).first {
            legacyPlaylist.title = Playlist.defaultQueueTitle
            legacyPlaylist.deleteable = false
            legacyPlaylist.hidden = false
            legacyPlaylist.kind = .manual
            legacyPlaylist.sortIndex = 0
            legacyPlaylist.symbolName = Playlist.defaultQueueSymbolName
            legacyPlaylist.smartFilter = nil
            modelContext.saveIfNeeded()
            return legacyPlaylist.id
        }

        let playlist = Playlist()
        modelContext.insert(playlist)
        modelContext.saveIfNeeded()
        return playlist.id
    }

    func ensureStandardSettingsExists() async {
        _ = await standardSettings()
    }
    
    /// Returns a standard global PodcastSettings object (for use as app-wide default)
    func standardSettings() async -> PodcastSettings {
        migrateAutoDownloadIncludeArchivedSettingIfNeeded()
        let defaultPlaylistID = defaultQueueID()
        let defaultSettingsTitle = "de.holgerkrupp.podbay.queue"
        var descriptor = FetchDescriptor<PodcastSettings>(
            predicate: #Predicate { $0.title == defaultSettingsTitle }
        )
        descriptor.fetchLimit = 1
        if let result = try? modelContext.fetch(descriptor).first {
            if result.defaultPlaylistID == nil {
                result.defaultPlaylistID = defaultPlaylistID
                modelContext.saveIfNeeded()
            }
            return result
        } else {
            let newDefaultSettings = PodcastSettings()
            newDefaultSettings.title = defaultSettingsTitle
            newDefaultSettings.defaultPlaylistID = defaultPlaylistID
            modelContext.insert(newDefaultSettings)
            modelContext.saveIfNeeded()
            return newDefaultSettings
        }
    }
    
    /// Every subscribed podcast whose new episodes are queued into `playlistID`.
    ///
    /// Mirrors what `EpisodeActor.processAfterCreation` actually does: a podcast's
    /// own settings win only while they are enabled, a queue position of `.none`
    /// means the podcast is not queued anywhere, and a target playlist that no
    /// longer exists falls back to the built-in queue the same way the insert
    /// path does.
    func podcastsRouted(toPlaylistID playlistID: UUID) async -> [PlaylistRoutedPodcast] {
        let globalSettings = await standardSettings()
        let defaultQueueID = defaultQueueID()
        let globalPosition = globalSettings.playnextPosition
        let globalPlaylistID = globalSettings.defaultPlaylistID ?? defaultQueueID

        // One fetch for every podcast's settings instead of one per podcast.
        let customSettingsByFeed = ((try? modelContext.fetch(
            FetchDescriptor<PodcastSettings>(
                predicate: #Predicate<PodcastSettings> { $0.isEnabled == true }
            )
        )) ?? []).reduce(into: [URL: PodcastSettings]()) { partialResult, settings in
            guard let feed = settings.podcast?.feed else { return }
            partialResult[feed] = settings
        }

        let podcasts = (try? modelContext.fetch(FetchDescriptor<Podcast>())) ?? []
        var routed: [PlaylistRoutedPodcast] = []

        for podcast in podcasts {
            guard podcast.isSubscribed, let feed = podcast.feed else { continue }

            let customSettings = customSettingsByFeed[feed]
            let position = customSettings?.playnextPosition ?? globalPosition
            guard position != .none else { continue }

            var resolvedPlaylistID = customSettings?.defaultPlaylistID ?? globalPlaylistID
            if manualPlaylistExists(id: resolvedPlaylistID) == false {
                resolvedPlaylistID = defaultQueueID
            }
            guard resolvedPlaylistID == playlistID else { continue }

            routed.append(
                PlaylistRoutedPodcast(
                    id: feed,
                    title: podcast.title,
                    imageURL: podcast.imageURL,
                    position: position,
                    usesCustomSettings: customSettings?.defaultPlaylistID != nil
                )
            )
        }

        return routed.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// The network preference every automatic download is gated on.
    ///
    /// `standardSettings()` hands back a model object, which cannot leave this
    /// actor, so callers outside it ask for the resolved value instead.
    func globalAutoDownloadNetworkMode() async -> AutoDownloadNetworkMode {
        await standardSettings().autoDownloadNetworkMode
    }

    /// Example: Update a settings object (edit as needed for your app's settings editing UI)
    func updateSettings(_ settingsID: PersistentIdentifier, apply changes: (PodcastSettings) -> Void) {
        guard let settings: PodcastSettings = modelContext.existingModel(for: settingsID) else { return }
        changes(settings)
        modelContext.saveIfNeeded()
    }
    
    /// Fetch PodcastSettings by PersistentIdentifier
    func fetchSettings(_ settingsID: PersistentIdentifier) -> PodcastSettings? {
        modelContext.existingModel(for: settingsID)
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
        guard let settings: PodcastSettings = modelContext.existingModel(for: settingsID) else { return }
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
       //  AppDiagnostics.log("Fetching custom Settings for Podcast with ID: \(podcastID)")
        let predicate = #Predicate<PodcastSettings> { setting in
            setting.podcast?.feed == podcastFeed &&
            setting.isEnabled == true
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<PodcastSettings>(predicate: predicate))
            // print(predicate.debugDescription)
           //  AppDiagnostics.log("Found \(results.count) custom Settings for Podcast with ID: (\(podcastID) - \(results.first?.title ?? "nil")")
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
            if settings.title == nil || settings.title?.isEmpty == true {
                settings.title = podcast.title
            }
            settings.podcast = podcast
        } else {
            let newSettings = PodcastSettings(podcast: podcast)
            let standardSettings = await standardSettings()
            newSettings.isEnabled = true
            newSettings.playbackSpeed = standardSettings.playbackSpeed
            newSettings.reduceSilenceGapsEnabled = standardSettings.reduceSilenceGapsEnabled
            newSettings.silenceGapReductionLevel = standardSettings.silenceGapReductionLevel
            newSettings.voiceEnhancementEnabled = standardSettings.voiceEnhancementEnabled
            newSettings.cutFront = standardSettings.cutFront ?? 0
            newSettings.cutEnd = standardSettings.cutEnd ?? 0
            newSettings.skipForward = standardSettings.skipForward
            newSettings.skipBack = standardSettings.skipBack
            newSettings.skipForwardBehavior = standardSettings.skipForwardBehavior
            newSettings.skipBackBehavior = standardSettings.skipBackBehavior
            newSettings.playnextPosition = standardSettings.playnextPosition
            newSettings.autoSkipKeywords = standardSettings.autoSkipKeywords
            newSettings.autoDownload = standardSettings.autoDownload
            newSettings.autoDownloadEpisodeCount = standardSettings.autoDownloadEpisodeCount
            newSettings.autoDownloadSelection = standardSettings.autoDownloadSelection
            newSettings.autoDownloadNetworkMode = standardSettings.autoDownloadNetworkMode
            newSettings.autoDownloadIncludesArchivedEpisodes = standardSettings.autoDownloadIncludesArchivedEpisodes
            newSettings.defaultPlaylistID = standardSettings.defaultPlaylistID
            newSettings.archiveFileRetentionDays = standardSettings.archiveFileRetentionDays
            newSettings.showLivePodcasts = standardSettings.showLivePodcasts
            newSettings.enableLiveItemNotifications = standardSettings.enableLiveItemNotifications
            modelContext.insert(newSettings)
            podcast.settings = newSettings
        }
        modelContext.saveIfNeeded()
        if let settings = podcast.settings {
            await publishPortablePreferences(settings, feedURL: podcastFeed)
        }
    }

    /// Disable custom settings for a podcast
    func disableCustomSettings(for podcastFeed: URL) async {
        guard let podcast = fetchPodcast(podcastFeed) else { return }
        if let settings = podcast.settings {
            settings.isEnabled = false
            modelContext.saveIfNeeded()
            await publishPortablePreferences(settings, feedURL: podcastFeed)
            return
        }
        modelContext.saveIfNeeded()
    }
    
    func getChapterSkipKeywords(for podcastFeed: URL?) async -> [skipKey]?{
        guard let podcastFeed ,let playbackSpeed = await fetchPodcastSettings(for: podcastFeed)?.autoSkipKeywords  else {
           //  AppDiagnostics.log("getChapterSkipKeywords no PodcastID -> standard")
            return await standardSettings().autoSkipKeywords
        }
        return playbackSpeed
    }
    
    func setChapterSkipKeywords(for podcastFeed: URL?, to value: [skipKey]) async {
        guard let podcastFeed  else {
           //  AppDiagnostics.log("no PodcastID - not saving")
            return
        }
        guard let settings = await fetchPodcastSettings(for: podcastFeed) else {
           //  AppDiagnostics.log("no Podcast Settings - not saving")
            return
        }
        
        settings.autoSkipKeywords = value
        modelContext.saveIfNeeded()
        await publishPortablePreferences(settings, feedURL: podcastFeed)
    }
    
    
    func getPlaybackSpeed(for podcastFeed: URL?) async -> Float{
        
        guard let podcastFeed  else {
           //  AppDiagnostics.log("no PodcastID - standard PlaybackSpeed")
            return await standardSettings().playbackSpeed ?? 1.0 // is no podcastID is given, the global Settings are returned
        }
        guard let playbackSpeed = await fetchPodcastSettings(for: podcastFeed)?.playbackSpeed else {
           //  AppDiagnostics.log("no Podcast Settings - standard PlaybackSpeed")

            return await standardSettings().playbackSpeed ?? 1.0 // is no podcastID is found, the global Settings are returned
        }
       //  AppDiagnostics.log("custom PlaybackSpeed: \(playbackSpeed.formatted())")

        return playbackSpeed
    }

    func getReduceSilenceGapsEnabled(for podcastFeed: URL?) async -> Bool {
        if let podcastFeed,
           let settings = await fetchPodcastSettings(for: podcastFeed),
           settings.isEnabled {
            return settings.reduceSilenceGapsEnabled
        }

        return await standardSettings().reduceSilenceGapsEnabled
    }

    func getSilenceGapReductionLevel(for podcastFeed: URL?) async -> SilenceGapReductionLevel {
        if let podcastFeed,
           let settings = await fetchPodcastSettings(for: podcastFeed),
           settings.isEnabled {
            return settings.silenceGapReductionLevel
        }

        return await standardSettings().silenceGapReductionLevel
    }

    func getVoiceEnhancementEnabled(for podcastFeed: URL?) async -> Bool {
        if let podcastFeed,
           let settings = await fetchPodcastSettings(for: podcastFeed),
           settings.isEnabled {
            return settings.voiceEnhancementEnabled
        }

        return await standardSettings().voiceEnhancementEnabled
    }

    func getPlaybackTrim(for podcastFeed: URL?) async -> PodcastPlaybackTrim {
        let settings: PodcastSettings
        if let podcastFeed,
           let customSettings = await fetchPodcastSettings(for: podcastFeed) {
            settings = customSettings
        } else {
            settings = await standardSettings()
        }

        return PodcastPlaybackTrim(
            introSkipSeconds: Double(settings.cutFront ?? 0),
            outroSkipSeconds: Double(settings.cutEnd ?? 0)
        )
    }

    func getSkipForwardStep(for podcastFeed: URL?) async -> SkipSteps {
        if let podcastFeed,
           let customValue = await fetchPodcastSettings(for: podcastFeed)?.skipForward {
            return customValue
        }

        return await standardSettings().skipForward
    }

    func getSkipBackStep(for podcastFeed: URL?) async -> SkipSteps {
        if let podcastFeed,
           let customValue = await fetchPodcastSettings(for: podcastFeed)?.skipBack {
            return customValue
        }

        return await standardSettings().skipBack
    }

    func getSkipForwardBehavior(for podcastFeed: URL?) async -> SkipButtonBehavior {
        if let podcastFeed,
           let customValue = await fetchPodcastSettings(for: podcastFeed)?.skipForwardBehavior {
            return customValue
        }

        return await standardSettings().skipForwardBehavior
    }

    func getSkipBackBehavior(for podcastFeed: URL?) async -> SkipButtonBehavior {
        if let podcastFeed,
           let customValue = await fetchPodcastSettings(for: podcastFeed)?.skipBackBehavior {
            return customValue
        }

        return await standardSettings().skipBackBehavior
    }
    
    func setPlaybackSpeed(for podcastFeed: URL?, to value: Float) async{
        let settings: PodcastSettings
        if let podcastFeed, let setting = await fetchPodcastSettings(for: podcastFeed) {
            settings = setting
        } else {
            settings = await standardSettings()
        }
        settings.playbackSpeed = value
        modelContext.saveIfNeeded()
        await publishPortablePreferences(settings, feedURL: podcastFeed)
    }
    
    func getPlaynextposition(for podcastFeed: URL?) async -> Playlist.Position{
       //  AppDiagnostics.log("getPlaynextposition for PodcastID: \(String(describing: podcastID))")
        guard let podcastFeed else {
           //  AppDiagnostics.log("getPlaynextposition no PodcastID - standard Playnextposition")
            return await standardSettings().playnextPosition
        }
        if let position =  await fetchPodcastSettings(for: podcastFeed)?.playnextPosition {
           //  AppDiagnostics.log("getPlaynextposition PodcastID - position: \(position)")

            return position
        }else{
           //  AppDiagnostics.log("getPlaynextposition no result - standard Playnextposition 2")

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

    func getSkipProtectionEnabled() async -> Bool {
        await standardSettings().enableSkipProtection
    }

    func getSkipProtectionNotificationsEnabled() async -> Bool {
        await standardSettings().enableSkipProtectionNotifications
    }

    func getTranscriptionsEnabled() async -> Bool {
        await standardSettings().enableTranscriptions
    }

    func getAutomaticOnDeviceTranscriptionsEnabled() async -> Bool {
        await standardSettings().enableAutomaticOnDeviceTranscriptions
    }

    func getPublisherTranscriptSynchronizationEnabled() async -> Bool {
        await standardSettings().enablePublisherTranscriptSynchronization
    }

    func getAutomaticOnDeviceTranscriptionsRequiresCharging() async -> Bool {
        await standardSettings().limitAutomaticOnDeviceTranscriptionsToCharging
    }

    func getAdvertisementDetectionEnabled() async -> Bool {
        await standardSettings().enableAdvertisementDetection
    }

    func getDetectedAdvertisementsVisible() async -> Bool {
        await standardSettings().showDetectedAdvertisements
    }

    func getAutomaticAdvertisementSkippingEnabled() async -> Bool {
        await standardSettings().enableAutomaticAdvertisementSkipping
    }

    func getAutomaticChapterGenerationEnabled() async -> Bool {
        await standardSettings().automaticallyGenerateChaptersWhenUnavailable
    }

    func getTranscriptionMaxSnippetDurationSeconds() async -> Double {
        let configuredValue = await standardSettings().transcriptionMaxSnippetDurationSeconds
        return min(max(configuredValue, 0.4), 8.0)
    }

    func getLiveItemNotificationsEnabled(for podcastFeed: URL?) async -> Bool {
        let globalSettings = await standardSettings()
        guard globalSettings.enableLiveItemNotifications else {
            return false
        }

        guard let podcastFeed,
              let customSettings = await fetchPodcastSettings(for: podcastFeed),
              customSettings.isEnabled else {
            return true
        }

        return customSettings.enableLiveItemNotifications
    }

    func getShowLivePodcastsEnabled() async -> Bool {
        await standardSettings().showLivePodcasts
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

        let globalSettings = await standardSettings()
        var feeds = Set<URL>()

        for podcast in podcasts {
            guard let feed = autoDownloadCandidateFeed(
                for: podcast,
                globalSettings: globalSettings,
                requireWiFiOnly: true
            ) else {
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

        let globalSettings = await standardSettings()
        var feeds = Set<URL>()

        for podcast in podcasts {
            guard let feed = autoDownloadCandidateFeed(
                for: podcast,
                globalSettings: globalSettings,
                requireWiFiOnly: false
            ) else {
                continue
            }
            feeds.insert(feed)
        }

        return Array(feeds)
    }

    private func autoDownloadCandidateFeed(
        for podcast: Podcast,
        globalSettings: PodcastSettings,
        requireWiFiOnly: Bool
    ) -> URL? {
        guard podcast.isSubscribed,
              let feed = podcast.feed else {
            return nil
        }

        let resolvedSettings: PodcastSettings
        if let customSettings = podcast.settings,
           customSettings.isEnabled {
            resolvedSettings = customSettings
        } else {
            resolvedSettings = globalSettings
        }

        guard resolvedSettings.autoDownload else {
            return nil
        }

        if requireWiFiOnly,
           resolvedSettings.autoDownloadNetworkMode != .wifiOnly {
            return nil
        }

        return feed
    }

    private func publishPortablePreferences(
        _ settings: PodcastSettings,
        feedURL: URL?
    ) async {
        let snapshot = PortablePodcastPreferenceSnapshot.make(
            settings: settings,
            feedURL: feedURL
        )
        await ModelContainerManager.shared.prepareSplitStores()
        guard let userStateContainer = await MainActor.run(body: {
            ModelContainerManager.shared.preparedUserStateContainer
        }) else { return }
        await StoreSplitPreferenceSyncWriter(modelContainer: userStateContainer)
            .upsert(snapshot)
    }

    func autoDownloadPolicy(for podcastFeed: URL) async -> AutoDownloadPolicySnapshot? {
        await logAutoDownload("policy-resolution/start feed=\(podcastFeed.redactedPodcastURLString)")
        guard let podcast = fetchPodcast(podcastFeed) else {
            await logAutoDownload("policy-resolution/none feed=\(podcastFeed.redactedPodcastURLString) source=podcast reason=podcast-not-found")
            return nil
        }

        guard podcast.isSubscribed else {
            await logAutoDownload("policy-resolution/none feed=\(podcastFeed.redactedPodcastURLString) source=podcast reason=podcast-unsubscribed")
            return nil
        }

        let customSettings = await fetchPodcastSettings(for: podcastFeed)
        let globalSettings = await standardSettings()
        let settings = (customSettings?.isEnabled == true) ? customSettings : globalSettings
        let source = (customSettings?.isEnabled == true) ? "podcast" : "global"

        guard let settings,
              settings.autoDownload else {
            await logAutoDownload("policy-resolution/none feed=\(podcastFeed.redactedPodcastURLString) source=\(source) reason=auto-download-disabled")
            return nil
        }

        var didMutateSettings = false

        let ensuredDefaultQueueID = defaultQueueID()
        var resolvedGlobalPlaylistID = globalSettings.defaultPlaylistID ?? ensuredDefaultQueueID
        if manualPlaylistExists(id: resolvedGlobalPlaylistID) == false {
            resolvedGlobalPlaylistID = ensuredDefaultQueueID
            await logAutoDownload("policy-resolution/repair-global-playlist feed=\(podcastFeed.redactedPodcastURLString) action=fallback-default-queue")
        }
        if globalSettings.defaultPlaylistID != resolvedGlobalPlaylistID {
            globalSettings.defaultPlaylistID = resolvedGlobalPlaylistID
            didMutateSettings = true
            await logAutoDownload("policy-resolution/repair-global-playlist feed=\(podcastFeed.redactedPodcastURLString) action=persist-default-playlist id=\(resolvedGlobalPlaylistID.uuidString)")
        }

        var resolvedQueuePosition = settings.playnextPosition
        if resolvedQueuePosition == .none {
            resolvedQueuePosition = .end
            settings.playnextPosition = .end
            didMutateSettings = true
            await logAutoDownload("policy-resolution/repair-queue-position feed=\(podcastFeed.redactedPodcastURLString) action=none-to-end")
        }

        var resolvedPlaylistID = settings.defaultPlaylistID ?? resolvedGlobalPlaylistID
        if manualPlaylistExists(id: resolvedPlaylistID) == false {
            resolvedPlaylistID = resolvedGlobalPlaylistID
            settings.defaultPlaylistID = resolvedPlaylistID
            didMutateSettings = true
            await logAutoDownload("policy-resolution/repair-target-playlist feed=\(podcastFeed.redactedPodcastURLString) action=fallback-to-global id=\(resolvedPlaylistID.uuidString)")
        }

        if didMutateSettings {
            modelContext.saveIfNeeded()
            await logAutoDownload("policy-resolution/persisted-repairs feed=\(podcastFeed.redactedPodcastURLString)")
        }

        await logAutoDownload(
            "policy-resolution/result feed=\(podcastFeed.redactedPodcastURLString) source=\(source) keep=\(max(settings.autoDownloadEpisodeCount, 1)) selection=\(settings.autoDownloadSelection.rawValue) queuePosition=\(resolvedQueuePosition) playlistID=\(resolvedPlaylistID.uuidString) network=\(settings.autoDownloadNetworkMode.rawValue) includeBackCatalog=\(settings.autoDownloadIncludesArchivedEpisodes)"
        )

        return AutoDownloadPolicySnapshot(
            keepCount: max(settings.autoDownloadEpisodeCount, 1),
            selection: settings.autoDownloadSelection,
            queuePosition: resolvedQueuePosition,
            playlistID: resolvedPlaylistID,
            networkMode: settings.autoDownloadNetworkMode,
            includesArchivedEpisodes: settings.autoDownloadIncludesArchivedEpisodes,
            episodeFilter: settings.autoDownloadFilter
        )
    }
}
