import Foundation
import SwiftData

/// `PodcastSettings` fields with no place in `PodcastPreferenceSync`.
struct PodcastLocalSettingsPayload: Codable, Sendable {
    var title: String?
    var enableSkipProtection: Bool
    var enableSkipProtectionNotifications: Bool
    var enableTranscriptions: Bool
    var enableAutomaticOnDeviceTranscriptions: Bool
    var enablePublisherTranscriptSynchronization: Bool
    var createTranscriptGapChapters: Bool
    var automaticallySkipTranscriptGapChapters: Bool
    var limitAutomaticOnDeviceTranscriptionsToCharging: Bool
    var enableAdvertisementDetection: Bool
    var showDetectedAdvertisements: Bool
    var enableAutomaticAdvertisementSkipping: Bool
    var automaticallyGenerateChaptersWhenUnavailable: Bool
    var transcriptionMaxSnippetDurationSeconds: Double
    var sleepTimerVoice: String
    var voices: [String: [String: String]]?

    init(_ settings: PodcastSettings) {
        title = settings.title
        enableSkipProtection = settings.enableSkipProtection
        enableSkipProtectionNotifications = settings.enableSkipProtectionNotifications
        enableTranscriptions = settings.enableTranscriptions
        enableAutomaticOnDeviceTranscriptions = settings.enableAutomaticOnDeviceTranscriptions
        enablePublisherTranscriptSynchronization = settings.enablePublisherTranscriptSynchronization
        createTranscriptGapChapters = settings.createTranscriptGapChapters
        automaticallySkipTranscriptGapChapters = settings.automaticallySkipTranscriptGapChapters
        limitAutomaticOnDeviceTranscriptionsToCharging = settings.limitAutomaticOnDeviceTranscriptionsToCharging
        enableAdvertisementDetection = settings.enableAdvertisementDetection
        showDetectedAdvertisements = settings.showDetectedAdvertisements
        enableAutomaticAdvertisementSkipping = settings.enableAutomaticAdvertisementSkipping
        automaticallyGenerateChaptersWhenUnavailable = settings.automaticallyGenerateChaptersWhenUnavailable
        transcriptionMaxSnippetDurationSeconds = settings.transcriptionMaxSnippetDurationSeconds
        sleepTimerVoice = settings.sleepTimerVoice
        voices = settings.voices
    }

    func apply(to settings: PodcastSettings) {
        func set<Value: Equatable>(
            _ keyPath: ReferenceWritableKeyPath<PodcastSettings, Value>,
            _ value: Value
        ) {
            if settings[keyPath: keyPath] != value { settings[keyPath: keyPath] = value }
        }
        set(\.title, title)
        set(\.enableSkipProtection, enableSkipProtection)
        set(\.enableSkipProtectionNotifications, enableSkipProtectionNotifications)
        set(\.enableTranscriptions, enableTranscriptions)
        set(\.enableAutomaticOnDeviceTranscriptions, enableAutomaticOnDeviceTranscriptions)
        set(\.enablePublisherTranscriptSynchronization, enablePublisherTranscriptSynchronization)
        set(\.createTranscriptGapChapters, createTranscriptGapChapters)
        set(\.automaticallySkipTranscriptGapChapters, automaticallySkipTranscriptGapChapters)
        set(\.limitAutomaticOnDeviceTranscriptionsToCharging, limitAutomaticOnDeviceTranscriptionsToCharging)
        set(\.enableAdvertisementDetection, enableAdvertisementDetection)
        set(\.showDetectedAdvertisements, showDetectedAdvertisements)
        set(\.enableAutomaticAdvertisementSkipping, enableAutomaticAdvertisementSkipping)
        set(\.automaticallyGenerateChaptersWhenUnavailable, automaticallyGenerateChaptersWhenUnavailable)
        set(\.transcriptionMaxSnippetDurationSeconds, transcriptionMaxSnippetDurationSeconds)
        set(\.sleepTimerVoice, sleepTimerVoice)
        set(\.voices, voices)
    }
}

enum StoreSplitLocalSettingsWriter {
    /// Kept for the deferred legacy-copy call sites. Local settings now live in
    /// the durable library, so copying them into PodcastCache would create a
    /// second authority that can later overwrite a newer edit.
    static func upsert(from settings: PodcastSettings, in cacheContext: ModelContext) {
        _ = settings
        _ = cacheContext
    }

    /// Kept for source compatibility with settings editors. `PodcastSettings`
    /// is already saved in the durable library by its owner.
    static func persist(_ settings: PodcastSettings) {
        _ = settings
    }
}

enum StoreSplitBookmarkDetailWriter {
    /// Adds or updates the detail row for `id` (the BookmarkSync id) without saving;
    /// the caller owns the save. Kept for deferred-copy call sites; canonical
    /// Bookmark rows now retain these device-local fields directly.
    static func upsert(from bookmark: Bookmark, id: String, in cacheContext: ModelContext) {
        _ = bookmark
        _ = id
        _ = cacheContext
    }

    static func delete(id: String, cacheContainer: ModelContainer) {
        let context = ModelContext(cacheContainer)
        try? context.delete(model: CachedBookmarkDetail.self, where: #Predicate { $0.id == id })
        try? context.save()
    }
}
