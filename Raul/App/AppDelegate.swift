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
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: BackgroundTaskConfiguration.storeSplitMigrationIdentifier
        )

        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false,
              StoreSplitRollout.state != .newStoreReads else {
            CrashBreadcrumbs.shared.record(
                "store_split_migration_background_task_not_scheduled",
                details: "state=\(StoreSplitRollout.state.rawValue)"
            )
            return
        }

        let request = BGProcessingTaskRequest(
            identifier: BackgroundTaskConfiguration.storeSplitMigrationIdentifier
        )
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: BackgroundTaskConfiguration.storeSplitMigrationInterval
        )

        do {
            try BGTaskScheduler.shared.submit(request)
            CrashBreadcrumbs.shared.record("store_split_migration_background_task_scheduled")
        } catch {
            CrashBreadcrumbs.shared.record(
                "store_split_migration_background_task_schedule_failed",
                details: error.localizedDescription
            )
            BasicLogger.shared.log(error.localizedDescription)
        }
    }

    private func handleStoreSplitMigration(task: BGProcessingTask) {
        CrashBreadcrumbs.shared.record("store_split_migration_background_task_started")
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
            task.setTaskCompleted(success: Task.isCancelled == false)
        }

        task.expirationHandler = {
            CrashBreadcrumbs.shared.record("store_split_migration_background_task_expired")
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

    static func scheduleAutomaticTranscriptionProcessingIfNeeded() async {
        let settingsActor = PodcastSettingsModelActor(modelContainer: ModelContainerManager.shared.container)
        let automaticTranscriptionsEnabled = await settingsActor.getAutomaticOnDeviceTranscriptionsEnabled()
        let requiresCharging = await settingsActor.getAutomaticOnDeviceTranscriptionsRequiresCharging()

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundTaskConfiguration.automaticTranscriptionIdentifier)

        guard automaticTranscriptionsEnabled, requiresCharging else {
            CrashBreadcrumbs.shared.record(
                "automatic_transcription_background_task_not_scheduled",
                details: "enabled=\(automaticTranscriptionsEnabled),requires_charging=\(requiresCharging)"
            )
            return
        }

        CrashBreadcrumbs.shared.record("automatic_transcription_background_task_schedule_requested")
        BasicLogger.shared.log("schedule automaticTranscriptionProcessing")
        let request = BGProcessingTaskRequest(identifier: BackgroundTaskConfiguration.automaticTranscriptionIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundTaskConfiguration.automaticTranscriptionInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            CrashBreadcrumbs.shared.record("automatic_transcription_background_task_scheduled")
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
            guard Task.isCancelled == false else {
                task.setTaskCompleted(success: false)
                return
            }
            CrashBreadcrumbs.shared.record("feed_processing_background_task_completed")
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

            let didProcess = await TranscriptionManager.shared.runAutomaticTranscriptionsFromUpNextUntilIdle(
                allowOnDeviceFallback: true
            )
            CrashBreadcrumbs.shared.record(
                "automatic_transcription_background_task_completed",
                details: "did_process=\(didProcess)"
            )
            guard Task.isCancelled == false else {
                task.setTaskCompleted(success: false)
                return
            }
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
