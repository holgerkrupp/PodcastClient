import Foundation
import SwiftData

struct PortablePodcastPreferenceSnapshot: Sendable {
    var feedURL: URL?
    var isEnabled: Bool
    var playNextPositionRawValue: String
    var defaultPlaylistID: String?
    var autoDownload: Bool?
    var autoDownloadEpisodeCount: Int?
    var autoDownloadSelectionRawValue: String?
    var autoDownloadNetworkModeRawValue: String?
    var autoDownloadIncludesArchivedEpisodes: Bool?
    var archiveFileRetentionDays: Int?
    var playbackSpeed: Double?
    var reduceSilenceGapsEnabled: Bool
    var silenceGapReductionLevelRawValue: String?
    var voiceEnhancementEnabled: Bool
    var autoSkipKeywordsJSON: String
    var autoDownloadFilterJSON: String?
    var cutFront: Double?
    var cutEnd: Double?
    var skipForwardSeconds: Int
    var skipBackSeconds: Int
    var skipForwardBehaviorRawValue: String?
    var skipBackBehaviorRawValue: String?
    var markAsPlayedAfterSubscribe: Bool
    var playSumAdjustedByPlaySpeed: Bool
    var enableLockscreenSlider: Bool
    var enableInAppSlider: Bool
    var continuousPlayEnabled: Bool
    var showLivePodcasts: Bool
    var liveItemNotificationsEnabled: Bool
    var sleepTimerAddMinutes: Double
    var sleepTimerDurationToReactivate: Double
    var sleepTimerVoiceFeedbackEnabled: Bool
    var sleepTimerText: String

    static func make(
        settings: PodcastSettings,
        feedURL: URL?,
        defaultPlaylistSyncID: String? = nil
    ) -> PortablePodcastPreferenceSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let position = (try? encoder.encode(settings.playnextPosition))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let keywords = (try? encoder.encode(settings.autoSkipKeywords))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let autoDownloadFilterJSON = settings.autoDownloadFilterJSON
        return PortablePodcastPreferenceSnapshot(
            feedURL: feedURL,
            isEnabled: settings.isEnabled,
            playNextPositionRawValue: position,
            defaultPlaylistID: settings.defaultPlaylistID.map {
                defaultPlaylistSyncID ?? $0.uuidString
            },
            autoDownload: settings.autoDownload,
            autoDownloadEpisodeCount: settings.autoDownloadEpisodeCount,
            autoDownloadSelectionRawValue: settings.autoDownloadSelectionRawValue,
            autoDownloadNetworkModeRawValue: settings.autoDownloadNetworkModeRawValue,
            autoDownloadIncludesArchivedEpisodes: settings.autoDownloadIncludesArchivedEpisodes,
            archiveFileRetentionDays: settings.archiveFileRetentionDays,
            playbackSpeed: settings.playbackSpeed.map(Double.init),
            reduceSilenceGapsEnabled: settings.reduceSilenceGapsEnabled,
            silenceGapReductionLevelRawValue: settings.silenceGapReductionLevelRawValue,
            voiceEnhancementEnabled: settings.voiceEnhancementEnabled,
            autoSkipKeywordsJSON: keywords,
            autoDownloadFilterJSON: autoDownloadFilterJSON,
            cutFront: settings.cutFront.map(Double.init),
            cutEnd: settings.cutEnd.map(Double.init),
            skipForwardSeconds: settings.skipForward.rawValue,
            skipBackSeconds: settings.skipBack.rawValue,
            skipForwardBehaviorRawValue: settings.skipForwardBehaviorRawValue,
            skipBackBehaviorRawValue: settings.skipBackBehaviorRawValue,
            markAsPlayedAfterSubscribe: settings.markAsPlayedAfterSubscribe,
            playSumAdjustedByPlaySpeed: settings.playSumAdjustedbyPlayspeed,
            enableLockscreenSlider: settings.enableLockscreenSlider,
            enableInAppSlider: settings.enableInAppSlider,
            continuousPlayEnabled: settings.getContinuousPlay,
            showLivePodcasts: settings.showLivePodcasts,
            liveItemNotificationsEnabled: settings.enableLiveItemNotifications,
            sleepTimerAddMinutes: settings.sleepTimerAddMinutes,
            sleepTimerDurationToReactivate: settings.sleepTimerDurationToReactivate,
            sleepTimerVoiceFeedbackEnabled: settings.sleepTimerVoiceFeedbackEnabled,
            sleepTimerText: settings.sleepTimerText
        )
    }
}

@ModelActor
actor StoreSplitPreferenceSyncWriter {
    @discardableResult
    func upsert(_ value: PortablePodcastPreferenceSnapshot, at date: Date = .now) -> Bool {
        let feedKey = value.feedURL.map(PodcastFeedIdentity.normalizedFeedURLString)
        let candidate = PodcastPreferenceSync(
            feedURL: feedKey,
            isEnabled: value.isEnabled,
            playNextPositionRawValue: value.playNextPositionRawValue,
            defaultPlaylistID: value.defaultPlaylistID,
            autoDownload: value.autoDownload,
            autoDownloadEpisodeCount: value.autoDownloadEpisodeCount,
            autoDownloadSelectionRawValue: value.autoDownloadSelectionRawValue,
            autoDownloadNetworkModeRawValue: value.autoDownloadNetworkModeRawValue,
            autoDownloadIncludesArchivedEpisodes: value.autoDownloadIncludesArchivedEpisodes,
            archiveFileRetentionDays: value.archiveFileRetentionDays,
            playbackSpeed: value.playbackSpeed,
            reduceSilenceGapsEnabled: value.reduceSilenceGapsEnabled,
            silenceGapReductionLevelRawValue: value.silenceGapReductionLevelRawValue,
            voiceEnhancementEnabled: value.voiceEnhancementEnabled,
            autoSkipKeywordsJSON: value.autoSkipKeywordsJSON,
            autoDownloadFilterJSON: value.autoDownloadFilterJSON,
            cutFront: value.cutFront,
            cutEnd: value.cutEnd,
            skipForwardSeconds: value.skipForwardSeconds,
            skipBackSeconds: value.skipBackSeconds,
            skipForwardBehaviorRawValue: value.skipForwardBehaviorRawValue,
            skipBackBehaviorRawValue: value.skipBackBehaviorRawValue,
            markAsPlayedAfterSubscribe: value.markAsPlayedAfterSubscribe,
            playSumAdjustedByPlaySpeed: value.playSumAdjustedByPlaySpeed,
            enableLockscreenSlider: value.enableLockscreenSlider,
            enableInAppSlider: value.enableInAppSlider,
            continuousPlayEnabled: value.continuousPlayEnabled,
            showLivePodcasts: value.showLivePodcasts,
            liveItemNotificationsEnabled: value.liveItemNotificationsEnabled,
            sleepTimerAddMinutes: value.sleepTimerAddMinutes,
            sleepTimerDurationToReactivate: value.sleepTimerDurationToReactivate,
            sleepTimerVoiceFeedbackEnabled: value.sleepTimerVoiceFeedbackEnabled,
            sleepTimerText: value.sleepTimerText,
            updatedAt: date,
            sourceDeviceID: ListeningDeviceIdentity.current().id
        )
        let preferenceID = candidate.id
        var descriptor = FetchDescriptor<PodcastPreferenceSync>(
            predicate: #Predicate { $0.id == preferenceID }
        )
        descriptor.fetchLimit = 1
        do {
            if let current = try modelContext.fetch(descriptor).first {
                // The timestamp is captured when the user edits the setting. A
                // queued older snapshot must never replace a newer committed edit.
                guard date > current.updatedAt else { return false }
                current.feedURL = candidate.feedURL
                current.isEnabled = candidate.isEnabled
                current.playNextPositionRawValue = candidate.playNextPositionRawValue
                current.defaultPlaylistID = candidate.defaultPlaylistID
                current.autoDownload = candidate.autoDownload
                current.autoDownloadEpisodeCount = candidate.autoDownloadEpisodeCount
                current.autoDownloadSelectionRawValue = candidate.autoDownloadSelectionRawValue
                current.autoDownloadNetworkModeRawValue = candidate.autoDownloadNetworkModeRawValue
                current.autoDownloadIncludesArchivedEpisodes = candidate.autoDownloadIncludesArchivedEpisodes
                current.archiveFileRetentionDays = candidate.archiveFileRetentionDays
                current.playbackSpeed = candidate.playbackSpeed
                current.reduceSilenceGapsEnabled = candidate.reduceSilenceGapsEnabled
                current.silenceGapReductionLevelRawValue = candidate.silenceGapReductionLevelRawValue
                current.voiceEnhancementEnabled = candidate.voiceEnhancementEnabled
                current.autoSkipKeywordsJSON = candidate.autoSkipKeywordsJSON
                current.autoDownloadFilterJSON = candidate.autoDownloadFilterJSON
                current.cutFront = candidate.cutFront
                current.cutEnd = candidate.cutEnd
                current.skipForwardSeconds = candidate.skipForwardSeconds
                current.skipBackSeconds = candidate.skipBackSeconds
                current.skipForwardBehaviorRawValue = candidate.skipForwardBehaviorRawValue
                current.skipBackBehaviorRawValue = candidate.skipBackBehaviorRawValue
                current.markAsPlayedAfterSubscribe = candidate.markAsPlayedAfterSubscribe
                current.playSumAdjustedByPlaySpeed = candidate.playSumAdjustedByPlaySpeed
                current.enableLockscreenSlider = candidate.enableLockscreenSlider
                current.enableInAppSlider = candidate.enableInAppSlider
                current.continuousPlayEnabled = candidate.continuousPlayEnabled
                current.showLivePodcasts = candidate.showLivePodcasts
                current.liveItemNotificationsEnabled = candidate.liveItemNotificationsEnabled
                current.sleepTimerAddMinutes = candidate.sleepTimerAddMinutes
                current.sleepTimerDurationToReactivate = candidate.sleepTimerDurationToReactivate
                current.sleepTimerVoiceFeedbackEnabled = candidate.sleepTimerVoiceFeedbackEnabled
                current.sleepTimerText = candidate.sleepTimerText
                current.updatedAt = date
                current.sourceDeviceID = candidate.sourceDeviceID
            } else {
                modelContext.insert(candidate)
            }
            try modelContext.commitChangesIfNeeded()
            return true
        } catch {
            modelContext.rollback()
            AppDiagnostics.log("Portable settings sync write failed: \(error.localizedDescription)")
            CrashBreadcrumbs.shared.record("portable_settings_sync_failed", details: error.localizedDescription)
            return false
        }
    }
}
