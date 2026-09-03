#if canImport(UIKit)
import UIKit
import BackgroundTasks
import BasicLogger
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate {
    // This is where the system gives us a completion handler
    // when background URLSession events are delivered
    var backgroundSessionCompletionHandler: (() -> Void)?
    private var playbackStateFlushTask: Task<Void, Never>?
    private var playbackStateBackgroundTaskID = UIBackgroundTaskIdentifier.invalid

    func applicationWillResignActive(_ application: UIApplication) {
        ModelContainerManager.shared.pauseSplitStoreWorkForBackground()
        flushPlaybackState(reason: "will_resign_active")
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        ModelContainerManager.shared.pauseSplitStoreWorkForBackground()
        flushPlaybackState(reason: "did_enter_background")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        CrashBreadcrumbs.shared.record("player_playback_state_cache_requested", details: "will_terminate")
        guard ModelContainerManager.shared.preparedContainer != nil else { return }
        Player.shared.cachePlaybackStateForRecovery()
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // Save for later, DownloadManager will call this in urlSessionDidFinishEvents
        backgroundSessionCompletionHandler = completionHandler
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CrashBreadcrumbs.shared.record("app_delegate_did_finish_launching")
        UNUserNotificationCenter.current().delegate = self

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskConfiguration.feedProcessingIdentifier,
            using: DispatchQueue.main
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleFeedProcessing(task: processingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskConfiguration.automaticTranscriptionIdentifier,
            using: DispatchQueue.main
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAutomaticTranscriptionProcessing(task: processingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskConfiguration.storeSplitMigrationIdentifier,
            using: DispatchQueue.main
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleStoreSplitMigration(task: processingTask)
        }

        return true
    }

    /// Schedules the overnight store-split migration pass. Requires external
    /// power so it runs while charging and idle, and network so CloudKit can
    /// export the migrated user-state. Only scheduled while migration could still
    /// have work to do.
    static func scheduleStoreSplitMigrationProcessingIfNeeded() {
        // Gate on real remaining work, not on the rollout marker. A device can
        // sit at `newStoreReads` from an earlier migration version and still owe
        // the current version every phase — that combination silently stopped the
        // overnight pass from ever being scheduled.
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false,
              ModelContainerManager.hasPendingMigrationWork else {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: BackgroundTaskConfiguration.storeSplitMigrationIdentifier
            )
            CrashBreadcrumbs.shared.record(
                "store_split_migration_background_task_not_scheduled",
                details: "state=\(StoreSplitRollout.state.rawValue),pending=\(ModelContainerManager.hasPendingMigrationWork)"
            )
#if DEBUG
            StoreSplitMigrationDebugLog.record(
                "background task not scheduled",
                details: "no pending migration work"
            )
#endif
            return
        }

        Task {
            // Never cancel-and-resubmit an existing request. Doing that on every
            // launch and every background transition pushed `earliestBeginDate`
            // forward each time, so on a phone that gets picked up during the
            // evening the task could keep sliding and never become eligible.
            let alreadyPending = await BGTaskScheduler.shared.pendingTaskRequests().contains {
                $0.identifier == BackgroundTaskConfiguration.storeSplitMigrationIdentifier
            }
            guard alreadyPending == false else {
                CrashBreadcrumbs.shared.record(
                    "store_split_migration_background_task_already_scheduled"
                )
#if DEBUG
                StoreSplitMigrationDebugLog.record(
                    "background task already scheduled",
                    details: "left the existing request in place"
                )
#endif
                return
            }

            let request = BGProcessingTaskRequest(
                identifier: BackgroundTaskConfiguration.storeSplitMigrationIdentifier
            )
            request.requiresExternalPower = true
            request.requiresNetworkConnectivity = true
            let earliestBeginDate = Date(
                timeIntervalSinceNow: BackgroundTaskConfiguration.storeSplitMigrationInterval
            )
            request.earliestBeginDate = earliestBeginDate

            do {
                try BGTaskScheduler.shared.submit(request)
                CrashBreadcrumbs.shared.record("store_split_migration_background_task_scheduled")
#if DEBUG
                StoreSplitMigrationDebugLog.record(
                    "background task scheduled",
                    details: "not before \(earliestBeginDate.formatted(date: .omitted, time: .shortened)), needs power + network"
                )
#endif
            } catch {
                CrashBreadcrumbs.shared.record(
                    "store_split_migration_background_task_schedule_failed",
                    details: error.localizedDescription
                )
#if DEBUG
                StoreSplitMigrationDebugLog.record(
                    "background task scheduling failed",
                    details: error.localizedDescription
                )
#endif
                BasicLogger.shared.log(error.localizedDescription)
            }
        }
    }

    private func handleStoreSplitMigration(task: BGProcessingTask) {
        CrashBreadcrumbs.shared.record("store_split_migration_background_task_started")
#if DEBUG
        StoreSplitMigrationDebugLog.record("background pass launched by iOS")
#endif
        let processingTask = Task(priority: .utility) {
            await ModelContainerManager.shared.prepareContainer()
            guard ModelContainerManager.shared.preparedContainer != nil else {
                task.setTaskCompleted(success: false)
                return
            }

            await ModelContainerManager.shared.runStoreSplitMigrationBackgroundPass()

            // Re-arm only if work remains (state still pre-completion).
            Self.scheduleStoreSplitMigrationProcessingIfNeeded()

            CrashBreadcrumbs.shared.record(
                "store_split_migration_background_task_completed",
                details: "state=\(StoreSplitRollout.state.rawValue),cancelled=\(Task.isCancelled)"
            )
#if DEBUG
            StoreSplitMigrationDebugLog.record(
                "background pass ended",
                details: "cancelled=\(Task.isCancelled), pending=\(ModelContainerManager.hasPendingMigrationWork)"
            )
#endif
            task.setTaskCompleted(success: Task.isCancelled == false)
        }

        task.expirationHandler = {
            CrashBreadcrumbs.shared.record("store_split_migration_background_task_expired")
#if DEBUG
            StoreSplitMigrationDebugLog.record(
                "background pass expired",
                details: "iOS reclaimed the time budget"
            )
#endif
            processingTask.cancel()
            // Unstructured migration work isn't a child task, so cancel it directly.
            Task { @MainActor in
                ModelContainerManager.shared.pauseSplitStoreWorkForBackground()
            }
        }
    }

    private func flushPlaybackState(reason: String) {
        CrashBreadcrumbs.shared.record("player_playback_state_flush_requested", details: reason)

        guard ModelContainerManager.shared.preparedContainer != nil else { return }
        guard Player.shared.currentEpisodeURL != nil else { return }
        Player.shared.cachePlaybackStateForRecovery()
        guard playbackStateFlushTask == nil else { return }

        playbackStateBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SavePlaybackState") { [weak self] in
            self?.playbackStateFlushTask?.cancel()
            self?.finishPlaybackStateFlush()
        }

        playbackStateFlushTask = Task { [weak self] in
            await Player.shared.captureCurrentPlaybackStateFromEngine(force: true)
            self?.finishPlaybackStateFlush()
        }
    }

    private func finishPlaybackStateFlush() {
        playbackStateFlushTask = nil
        guard playbackStateBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(playbackStateBackgroundTaskID)
        playbackStateBackgroundTaskID = .invalid
    }

    /// Keeps the automatic transcription pass armed.
    ///
    /// The task used to be scheduled only when the user had switched on "only
    /// while charging" — the default is off, so on most devices it was never
    /// scheduled at all. It is now armed whenever transcriptions are on, and the
    /// charging setting decides the request's power requirement instead.
    static func scheduleAutomaticTranscriptionProcessingIfNeeded() async {
        let settingsActor = PodcastSettingsModelActor(modelContainer: ModelContainerManager.shared.container)
        let transcriptionsEnabled = await settingsActor.getTranscriptionsEnabled()

        guard transcriptionsEnabled else {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: BackgroundTaskConfiguration.automaticTranscriptionIdentifier
            )
            CrashBreadcrumbs.shared.record(
                "automatic_transcription_background_task_not_scheduled",
                details: "transcriptions_enabled=false"
            )
            return
        }

        let automaticTranscriptionsEnabled = await settingsActor.getAutomaticOnDeviceTranscriptionsEnabled()
        // Without the analyzer the pass only imports feed-provided transcripts,
        // which is a small download and does not need external power.
        let requiresCharging = automaticTranscriptionsEnabled
            && await settingsActor.getAutomaticOnDeviceTranscriptionsRequiresCharging()

        // Never cancel-and-resubmit a pending request. The app backgrounds many
        // times a day and every resubmit pushed `earliestBeginDate` out again, so
        // on a phone that gets picked up regularly the task kept sliding and
        // never became eligible.
        let pendingRequest = await BGTaskScheduler.shared.pendingTaskRequests().first {
            $0.identifier == BackgroundTaskConfiguration.automaticTranscriptionIdentifier
        }
        if let pendingRequest {
            let pendingRequiresExternalPower = (pendingRequest as? BGProcessingTaskRequest)?
                .requiresExternalPower
            guard pendingRequiresExternalPower != nil,
                  pendingRequiresExternalPower != requiresCharging else {
                CrashBreadcrumbs.shared.record(
                    "automatic_transcription_background_task_already_scheduled"
                )
                return
            }
            // The charging setting changed since the request was submitted, so
            // replace it with one that matches.
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: BackgroundTaskConfiguration.automaticTranscriptionIdentifier
            )
        }

        CrashBreadcrumbs.shared.record("automatic_transcription_background_task_schedule_requested")
        BasicLogger.shared.log("schedule automaticTranscriptionProcessing")
        let request = BGProcessingTaskRequest(identifier: BackgroundTaskConfiguration.automaticTranscriptionIdentifier)
        request.requiresExternalPower = requiresCharging
        // Feed-provided transcripts are downloaded when a connection happens to
        // be there; the analyzer works offline, so this must not be required.
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundTaskConfiguration.automaticTranscriptionInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            CrashBreadcrumbs.shared.record(
                "automatic_transcription_background_task_scheduled",
                details: "requires_external_power=\(requiresCharging)"
            )
        } catch {
            CrashBreadcrumbs.shared.record(
                "automatic_transcription_background_task_schedule_failed",
                details: error.localizedDescription
            )
            BasicLogger.shared.log(error.localizedDescription)
        }
    }

    private static func scheduleFeedProcessing() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundTaskConfiguration.feedProcessingIdentifier)
        let request = BGProcessingTaskRequest(identifier: BackgroundTaskConfiguration.feedProcessingIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundTaskConfiguration.feedProcessingInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
            CrashBreadcrumbs.shared.record("feed_processing_background_task_scheduled")
        } catch {
            CrashBreadcrumbs.shared.record("feed_processing_background_task_schedule_failed", details: error.localizedDescription)
            BasicLogger.shared.log(error.localizedDescription)
        }
    }

    private func handleFeedProcessing(task: BGProcessingTask) {
        CrashBreadcrumbs.shared.record("feed_processing_background_task_started")
        let processingTask = Task(priority: .utility) {
            await ModelContainerManager.shared.prepareContainer()
            guard let container = ModelContainerManager.shared.preparedContainer else {
                task.setTaskCompleted(success: false)
                return
            }

            Self.scheduleFeedProcessing()
            await SubscriptionManager(modelContainer: container).bgupdateFeeds(reason: .processing)
            await PredictedReleaseRefreshScheduler.schedule(using: container)
            guard Task.isCancelled == false else {
                task.setTaskCompleted(success: false)
                return
            }

            // Feeds were just refreshed, so any transcript a podcast published
            // is known now. Importing those here costs a few small downloads and
            // spares the analyzer the episodes it never needed to run on.
            // `TranscriptionManager.shared` builds itself on the main actor, so
            // reach it from there: this task can be the first thing to touch it
            // in a background launch of the process.
            let transcriptionManager = await MainActor.run { TranscriptionManager.shared }
            let importedTranscriptCount = await transcriptionManager
                .runAutomaticTranscriptionsFromPlaylists(
                    allowOnDeviceFallback: false,
                    episodeLimit: BackgroundTaskConfiguration.feedProcessingTranscriptImportLimit,
                    budget: BackgroundTaskConfiguration.feedProcessingTranscriptImportBudget
                )
            guard Task.isCancelled == false else {
                task.setTaskCompleted(success: false)
                return
            }
            CrashBreadcrumbs.shared.record(
                "feed_processing_background_task_completed",
                details: "imported_transcripts=\(importedTranscriptCount)"
            )
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            CrashBreadcrumbs.shared.record("feed_processing_background_task_expired")
            processingTask.cancel()
        }
    }

    private func handleAutomaticTranscriptionProcessing(task: BGProcessingTask) {
        CrashBreadcrumbs.shared.record("automatic_transcription_background_task_started")
        let processingTask = Task(priority: .utility) {
            await ModelContainerManager.shared.prepareContainer()
            guard ModelContainerManager.shared.preparedContainer != nil else {
                task.setTaskCompleted(success: false)
                return
            }

            await Self.scheduleAutomaticTranscriptionProcessingIfNeeded()
            guard Task.isCancelled == false else {
                task.setTaskCompleted(success: false)
                return
            }

            // Work through several episodes per launch instead of one: iOS hands
            // out these windows sparingly, and a single episode left most of the
            // granted time unused.
            let transcriptionManager = await MainActor.run { TranscriptionManager.shared }
            let processedCount = await transcriptionManager
                .runAutomaticTranscriptionsFromPlaylists(
                    allowOnDeviceFallback: true,
                    episodeLimit: BackgroundTaskConfiguration.automaticTranscriptionBackgroundEpisodeLimit,
                    budget: BackgroundTaskConfiguration.automaticTranscriptionBackgroundBudget
                )
            CrashBreadcrumbs.shared.record(
                "automatic_transcription_background_task_completed",
                details: "processed_count=\(processedCount)"
            )
            guard Task.isCancelled == false else {
                task.setTaskCompleted(success: false)
                return
            }

            // Re-arm again now that the launched request is definitely consumed.
            // No-ops when the request submitted at the start of the pass is still
            // pending, so this only covers the case where it was not.
            await Self.scheduleAutomaticTranscriptionProcessingIfNeeded()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            CrashBreadcrumbs.shared.record("automatic_transcription_background_task_expired")
            BasicLogger.shared.log("automatic transcription background task expired")
            processingTask.cancel()
            Task {
                await TranscriptionManager.shared.cancelAutomaticTranscriptionsForBackground()
            }
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
#if DEBUG
    /// Presents the migration diagnostics while the app is open. Scoped to the
    /// debug log's own identifiers so the app's real notifications keep their
    /// existing foreground behaviour.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard StoreSplitMigrationDebugLog.isDebugNotification(
            notification.request.identifier
        ) else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list])
    }
#endif

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo
        guard
            let urlString = userInfo["url"] as? String,
            let url = URL(string: urlString),
            PodcastYearShareCoordinator.isPodcastYearURL(url)
        else { return }

        UserDefaults.standard.set(true, forKey: "PodcastYearShare.pendingNotificationTap")
        NotificationCenter.default.post(name: .podcastYearShareNotificationTapped, object: nil)
    }
}
#endif
