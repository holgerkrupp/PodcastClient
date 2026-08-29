import Foundation
import SwiftData

struct PortablePodcastPreferenceSnapshot: Sendable {
    var feedURL: URL?
    var isEnabled: Bool
    var playNextPositionRawValue: String
    var defaultPlaylistID: String?
    var playbackSpeed: Double?
    var reduceSilenceGapsEnabled: Bool
    var silenceGapReductionLevelRawValue: String?
    var voiceEnhancementEnabled: Bool
    var autoSkipKeywordsJSON: String
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
    var liveItemNotificationsEnabled: Bool
    var sleepTimerAddMinutes: Double
    var sleepTimerDurationToReactivate: Double
    var sleepTimerVoiceFeedbackEnabled: Bool
    var sleepTimerText: String

    static func make(
        settings: PodcastSettings,
        feedURL: URL?
    ) -> PortablePodcastPreferenceSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let position = (try? encoder.encode(settings.playnextPosition))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let keywords = (try? encoder.encode(settings.autoSkipKeywords))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return PortablePodcastPreferenceSnapshot(
            feedURL: feedURL,
            isEnabled: settings.isEnabled,
            playNextPositionRawValue: position,
            defaultPlaylistID: settings.defaultPlaylistID?.uuidString,
            playbackSpeed: settings.playbackSpeed.map(Double.init),
            reduceSilenceGapsEnabled: settings.reduceSilenceGapsEnabled,
            silenceGapReductionLevelRawValue: settings.silenceGapReductionLevelRawValue,
            voiceEnhancementEnabled: settings.voiceEnhancementEnabled,
            autoSkipKeywordsJSON: keywords,
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
    func upsert(_ value: PortablePodcastPreferenceSnapshot, at date: Date = .now) {
        let feedKey = value.feedURL.map(PodcastFeedIdentity.normalizedFeedURLString)
        let candidate = PodcastPreferenceSync(
            feedURL: feedKey,
            isEnabled: value.isEnabled,
            playNextPositionRawValue: value.playNextPositionRawValue,
            defaultPlaylistID: value.defaultPlaylistID,
            playbackSpeed: value.playbackSpeed,
            reduceSilenceGapsEnabled: value.reduceSilenceGapsEnabled,
            silenceGapReductionLevelRawValue: value.silenceGapReductionLevelRawValue,
            voiceEnhancementEnabled: value.voiceEnhancementEnabled,
            autoSkipKeywordsJSON: value.autoSkipKeywordsJSON,
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
        if let current = try? modelContext.fetch(descriptor).first {
            guard date >= current.updatedAt else { return }
            current.feedURL = candidate.feedURL
            current.isEnabled = candidate.isEnabled
            current.playNextPositionRawValue = candidate.playNextPositionRawValue
            current.defaultPlaylistID = candidate.defaultPlaylistID
            current.playbackSpeed = candidate.playbackSpeed
            current.reduceSilenceGapsEnabled = candidate.reduceSilenceGapsEnabled
            current.silenceGapReductionLevelRawValue = candidate.silenceGapReductionLevelRawValue
            current.voiceEnhancementEnabled = candidate.voiceEnhancementEnabled
            current.autoSkipKeywordsJSON = candidate.autoSkipKeywordsJSON
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
        modelContext.saveIfNeeded()
    }
}
