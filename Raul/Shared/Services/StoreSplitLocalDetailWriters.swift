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
    /// Adds or updates the row for these settings without saving; the caller owns
    /// the save. Settings owned by neither a podcast nor the global scope are skipped.
    static func upsert(from settings: PodcastSettings, in cacheContext: ModelContext) {
        if let feed = settings.podcast?.feed {
            upsert(
                PodcastLocalSettingsPayload(settings),
                feedKey: PodcastFeedIdentity.normalizedFeedURLString(feed),
                in: cacheContext
            )
        } else if settings.title == PodcastSettings.globalSettingsTitle {
            upsert(PodcastLocalSettingsPayload(settings), feedKey: nil, in: cacheContext)
        }
    }

    /// Persists a committed settings edit in the background.
    static func persist(_ settings: PodcastSettings) {
        let feedKey = settings.podcast?.feed.map(PodcastFeedIdentity.normalizedFeedURLString)
        guard feedKey != nil || settings.title == PodcastSettings.globalSettingsTitle else { return }
        let payload = PodcastLocalSettingsPayload(settings)
        Task {
            await ModelContainerManager.shared.prepareSplitStores()
            guard let cache = await MainActor.run(body: {
                ModelContainerManager.shared.preparedCacheContainer
            }) else {
                AppDiagnostics.log("Local podcast settings could not be saved: PodcastCache unavailable")
                return
            }
            await Task.detached(priority: .utility) {
                let context = ModelContext(cache)
                upsert(payload, feedKey: feedKey, in: context)
                do {
                    try context.save()
                } catch {
                    CrashBreadcrumbs.shared.record(
                        "store_split_local_settings_save_failed",
                        details: error.localizedDescription
                    )
                }
            }.value
        }
    }

    private static func upsert(
        _ payload: PodcastLocalSettingsPayload,
        feedKey: String?,
        in context: ModelContext
    ) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let rowID = CachedPodcastLocalSettings.scopeID(feedURL: feedKey)
        var descriptor = FetchDescriptor<CachedPodcastLocalSettings>(
            predicate: #Predicate { $0.id == rowID }
        )
        descriptor.fetchLimit = 1
        if let row = try? context.fetch(descriptor).first {
            guard row.payload != data else { return }
            row.payload = data
            row.updatedAt = .now
        } else {
            context.insert(CachedPodcastLocalSettings(feedURL: feedKey, payload: data))
        }
    }
}

enum StoreSplitBookmarkDetailWriter {
    /// Adds or updates the detail row for `id` (the BookmarkSync id) without saving;
    /// the caller owns the save.
    static func upsert(from bookmark: Bookmark, id: String, in cacheContext: ModelContext) {
        var descriptor = FetchDescriptor<CachedBookmarkDetail>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        let identity = bookmark.bookmarkEpisode?.stableEpisodeIdentity
        let row = (try? cacheContext.fetch(descriptor).first) ?? {
            let created = CachedBookmarkDetail(
                id: id,
                feedURL: identity?.feedURL ?? "",
                episodeID: identity?.episodeID ?? ""
            )
            cacheContext.insert(created)
            return created
        }()
        row.imageData = bookmark.imageData
        row.duration = bookmark.duration
        row.endTime = bookmark.endTime
        row.link = bookmark.link
        row.progress = bookmark.progress
        row.updatedAt = .now
    }

    static func delete(id: String, cacheContainer: ModelContainer) {
        let context = ModelContext(cacheContainer)
        try? context.delete(model: CachedBookmarkDetail.self, where: #Predicate { $0.id == id })
        try? context.save()
    }
}
