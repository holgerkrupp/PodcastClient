#if canImport(UIKit)
import UIKit
import BackgroundTasks
import UserNotifications

@MainActor
final class BackgroundSessionCompletionCoordinator {
    static let shared = BackgroundSessionCompletionCoordinator()

    private struct PendingCompletion {
        let installedAt: Date
        let handler: () -> Void
    }

    private var pendingCompletions: [String: PendingCompletion] = [:]
    private var fallbackTasks: [String: Task<Void, Never>] = [:]

    func install(identifier: String, handler: @escaping () -> Void) {
        fallbackTasks.removeValue(forKey: identifier)?.cancel()
        if let previous = pendingCompletions.removeValue(forKey: identifier) {
            record(
                "background_urlsession_completion_replaced",
                identifier: identifier,
                details: "previous_age_ms=\(elapsedMilliseconds(since: previous.installedAt))"
            )
            previous.handler()
        }

        pendingCompletions[identifier] = PendingCompletion(installedAt: .now, handler: handler)
        record("background_urlsession_completion_installed", identifier: identifier)
    }

    func complete(identifier: String, reason: String) {
        fallbackTasks.removeValue(forKey: identifier)?.cancel()
        guard let completion = pendingCompletions.removeValue(forKey: identifier) else {
            record(
                "background_urlsession_completion_ignored",
                identifier: identifier,
                details: "reason=\(reason)"
            )
            return
        }

        record(
            reason == "idle_session_fallback"
                ? "background_urlsession_completion_force_released"
                : "background_urlsession_completion_released",
            identifier: identifier,
            details: "reason=\(reason),age_ms=\(elapsedMilliseconds(since: completion.installedAt))"
        )
        completion.handler()
    }

    /// A relaunch can legitimately have no tasks left by the time the exact
    /// background session is inspected. Keep the system assertion bounded even
    /// if URLSession does not deliver a finish-events callback for that launch.
    func scheduleIdleFallback(identifier: String) {
        guard pendingCompletions[identifier] != nil else { return }
        fallbackTasks.removeValue(forKey: identifier)?.cancel()
        fallbackTasks[identifier] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard Task.isCancelled == false else { return }
            self?.complete(identifier: identifier, reason: "idle_session_fallback")
        }
        record(
            "background_urlsession_completion_fallback_scheduled",
            identifier: identifier,
            details: "delay_ms=2000"
        )
    }

    private func record(_ event: String, identifier: String, details: String? = nil) {
        let category = DownloadManager.backgroundSessionCategory(for: identifier)
        let suffix = details.map { ",\($0)" } ?? ""
        CrashBreadcrumbs.shared.record(
            event,
            details: "category=\(category),suspendable=true\(suffix)"
        )
    }

    private func elapsedMilliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    private var playbackStateFlushTask: Task<Void, Never>?
    private var playbackStateBackgroundTaskID = UIBackgroundTaskIdentifier.invalid
    private var backgroundTaskCPUStart: [String: Double] = [:]

    private func beginBackgroundTaskDiagnostics(_ task: BGProcessingTask) {
        let cpu = SystemProcessCPUTimeSource().sample().cpuTime
        backgroundTaskCPUStart[task.identifier] = cpu
        AppDiagnostics.log(
            "background_processing_started task=\(task.identifier) process_cpu_seconds=\(String(format: "%.2f", cpu))"
        )
    }

    func applicationWillResignActive(_ application: UIApplication) {
        ModelContainerManager.shared.pauseSplitStoreWorkForBackground()
        flushPlaybackState(reason: "will_resign_active")
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        ModelContainerManager.shared.pauseSplitStoreWorkForBackground()
        // The recovery snapshot is intentionally cheap and does not touch
        // SwiftData. Starting another CloudKit-backed save after the process has
        // crossed the suspension boundary can leave SharedDatabase.sqlite locked
        // while RunningBoard is trying to suspend us (0xdead10cc).
        CrashBreadcrumbs.shared.record(
            "player_playback_state_cache_requested",
            details: "did_enter_background"
        )
        Player.shared.cachePlaybackStateForRecovery()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        CrashBreadcrumbs.shared.record("player_playback_state_cache_requested", details: "will_terminate")
        guard ModelContainerManager.shared.preparedContainer != nil else { return }
        Player.shared.cachePlaybackStateForRecovery()
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        let category = DownloadManager.backgroundSessionCategory(for: identifier)
        CrashBreadcrumbs.shared.record(
            "background_urlsession_relaunch_received",
            details: "category=\(category),application_state=\(applicationStateName(application.applicationState)),suspendable=true"
        )
        BackgroundSessionCompletionCoordinator.shared.install(
            identifier: identifier,
            handler: completionHandler
        )

        Task(priority: .utility) {
            let prepareStartedAt = Date()
            let reconnection = await DownloadManager.shared.reconnectBackgroundSession(for: identifier)
            CrashBreadcrumbs.shared.record(
                "background_urlsession_reconnected",
                details: "category=\(category),task_count=\(reconnection.taskCount),prepare_ms=\(Int(Date().timeIntervalSince(prepareStartedAt) * 1_000)),application_state=\(applicationStateName(application.applicationState)),suspendable=true"
            )
            if reconnection.taskCount == 0 {
                BackgroundSessionCompletionCoordinator.shared.scheduleIdleFallback(identifier: identifier)
            }
            await DownloadManager.shared.restorePendingDownloads()
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CrashBreadcrumbs.shared.record(
            "app_delegate_did_finish_launching",
            details: "application_state=\(applicationStateName(application.applicationState)),launch_categories=\(launchOptionCategories(launchOptions))"
        )
        // Begin whole-process CPU accounting before any optional background
        // maintenance is admitted later in this process lifetime.
        _ = StoreMaintenanceResourceBudget.shared
        // A background launch reaches the container through whichever
        // BGTask asked for it, and must not do store work it was not
        // granted budget for.
        if application.applicationState != .background {
            ModelContainerManager.startEagerContainerPreparation()
        }
        UNUserNotificationCenter.current().delegate = self
        SkipProtectionNotification.registerCategory()
        ListenTogetherController.shared.startListening()

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
            forTaskWithIdentifier: BackgroundTaskConfiguration.publisherTranscriptSynchronizationIdentifier,
            using: DispatchQueue.main
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handlePublisherTranscriptSynchronization(task: processingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskConfiguration.storeSplitMigrationIdentifier,
            using: DispatchQueue.main
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleStoreSplitBackgroundProcessing(task: processingTask)
        }

        return true
    }

    private func applicationStateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func launchOptionCategories(_ options: [UIApplication.LaunchOptionsKey: Any]?) -> String {
        guard let options, options.isEmpty == false else { return "none" }
        // Notification, location, and shortcut launch context is delivered by
        // scene connection options (or the corresponding delegate callbacks)
        // after scene-based apps connect. Do not inspect the deprecated launch
        // option keys here just for diagnostics.
        return options.keys.map { key in
            _ = key
            return "other"
        }.sorted().joined(separator: "+")
    }

    /// Schedules the store-sync background pass (the task identifier is kept
    /// from the migration era). It drains the portable-write outbox and repair
    /// journal and applies a pending CloudKit user-state import, so it is only
    /// scheduled while one of those is outstanding. Requires external power.
    static func scheduleStoreSplitBackgroundProcessingIfNeeded() {
        guard ModelContainerManager.hasPendingStoreSplitBackgroundWork else {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: BackgroundTaskConfiguration.storeSplitMigrationIdentifier
            )
            CrashBreadcrumbs.shared.record(
                "store_split_migration_background_task_not_scheduled",
                details: "pending=false"
            )
#if DEBUG
            StoreSplitMigrationDebugLog.record(
                "background task not scheduled",
                details: "no pending store-sync work"
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
            request.requiresNetworkConnectivity = false
            let earliestBeginDate = ModelContainerManager.nextStoreSplitBackgroundOpportunity
            request.earliestBeginDate = earliestBeginDate

            do {
                try BGTaskScheduler.shared.submit(request)
                CrashBreadcrumbs.shared.record("store_split_migration_background_task_scheduled")
#if DEBUG
                StoreSplitMigrationDebugLog.record(
                    "background task scheduled",
                    details: "not before \(earliestBeginDate.formatted(date: .omitted, time: .shortened)), needs external power"
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
                AppDiagnostics.log(error.localizedDescription)
            }
        }
    }

    private func handleStoreSplitBackgroundProcessing(task: BGProcessingTask) {
        beginBackgroundTaskDiagnostics(task)
        CrashBreadcrumbs.shared.record("store_split_migration_background_task_started")
#if DEBUG
        StoreSplitMigrationDebugLog.record("background pass launched by iOS")
#endif
        let processingTask = Task(priority: .utility) {
            await ModelContainerManager.shared.runStoreSplitBackgroundPass()

            // Re-arm only if work remains.
            Self.scheduleStoreSplitBackgroundProcessingIfNeeded()

            CrashBreadcrumbs.shared.record(
                "store_split_migration_background_task_completed",
                details: "cancelled=\(Task.isCancelled)"
            )
#if DEBUG
            StoreSplitMigrationDebugLog.record(
                "background pass ended",
                details: "cancelled=\(Task.isCancelled), pending=\(ModelContainerManager.hasPendingStoreSplitBackgroundWork)"
            )
#endif
            await self.finishBackgroundProcessingTask(
                task,
                operation: "store_split_migration",
                requestedSuccess: Task.isCancelled == false,
                waitForExportQuiescence: true,
                details: "pending=\(ModelContainerManager.hasPendingStoreSplitBackgroundWork)"
            )
        }

        task.expirationHandler = {
            CrashBreadcrumbs.shared.record(
                "background_task_expired",
                details: "operation=store_split_migration"
            )
            processingTask.cancel()
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
            await Player.shared.captureCurrentPlaybackStateFromEngine(
                force: true,
                persistToStore: false
            )
            self?.finishPlaybackStateFlush()
        }
    }

    private func finishPlaybackStateFlush() {
        playbackStateFlushTask = nil
        guard playbackStateBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(playbackStateBackgroundTaskID)
        playbackStateBackgroundTaskID = .invalid
    }

    /// Record the CloudKit export state before reporting a background task as
    /// complete. Tasks that wrote to a mirrored store keep their grant through
    /// a bounded quiet period so Core Data can finish exporting those writes.
    private func finishBackgroundProcessingTask(
        _ task: BGProcessingTask,
        operation: String,
        requestedSuccess: Bool,
        waitForExportQuiescence: Bool,
        details: String? = nil
    ) async {
        let monitor = StoreCloudKitActivityMonitor.shared
        let drainStartedAt = Date()
        let exportSettled: Bool
        if waitForExportQuiescence {
            exportSettled = await monitor.waitForExportQuiescence()
        } else {
            exportSettled = monitor.isAnyStoreExporting == false
        }
        let elapsedMilliseconds = Int(Date().timeIntervalSince(drainStartedAt) * 1_000)
        let storeExportStatus = StoreCloudKitActivityMonitor.StoreKind.allCases
            .map { kind in
                let identifiers = monitor.activeExportIdentifiers(for: kind)
                return "\(kind.rawValue):\(monitor.activeExportStatus(for: kind)):ids=\(identifiers.isEmpty ? "none" : identifiers.joined(separator: "+"))"
            }
            .joined(separator: ";")
        let cancelled = Task.isCancelled
        let succeeded = requestedSuccess
            && cancelled == false
            && (waitForExportQuiescence == false || exportSettled)
        let detail = "task=\(task.identifier),operation=\(operation),requested_success=\(requestedSuccess),cancelled=\(cancelled),drain_required=\(waitForExportQuiescence),export_settled=\(exportSettled),drain_ms=\(elapsedMilliseconds),exports=\(storeExportStatus)"
            + (details.map { ",\($0)" } ?? "")
        let cpuAtStart = backgroundTaskCPUStart.removeValue(forKey: task.identifier)
        let cpuAtEnd = SystemProcessCPUTimeSource().sample().cpuTime
        let cpuDelta = cpuAtStart.map { max(0, cpuAtEnd - $0) }
        CrashBreadcrumbs.shared.record(
            "background_task_export_diagnostics",
            details: detail + ",process_cpu_seconds_delta=\(cpuDelta.map { String(format: "%.2f", $0) } ?? "unavailable")"
        )
        AppDiagnostics.log(
            "background_processing_completed task=\(task.identifier) operation=\(operation) success=\(succeeded) process_cpu_seconds_delta=\(cpuDelta.map { String(format: "%.2f", $0) } ?? "unavailable")"
        )
        if operation == "feed_processing" {
            await Self.scheduleFeedProcessing()
        }
        task.setTaskCompleted(success: succeeded)
    }

    /// Keeps the automatic transcription pass armed.
    ///
    /// The task used to be scheduled only when the user had switched on "only
    /// while charging" — the default is off, so on most devices it was never
    /// scheduled at all. It is now armed whenever transcriptions are on, and the
    /// charging setting decides the request's power requirement instead.
    static func scheduleAutomaticTranscriptionProcessingIfNeeded() async {
        guard StoreRuntimeProjection.isLibraryBackfillPending == false else { return }
        guard let container = await ModelContainerManager.shared
            .prepareContainerForExternalEntryPoint() else {
            CrashBreadcrumbs.shared.record(
                "automatic_transcription_background_task_not_scheduled",
                details: "reason=model_container_unavailable"
            )
            return
        }
        guard Task.isCancelled == false else { return }
        let settingsActor = PodcastSettingsModelActor(modelContainer: container)
        let transcriptionsEnabled = await settingsActor.getTranscriptionsEnabled()
        guard Task.isCancelled == false else { return }

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
        guard Task.isCancelled == false else { return }
        // Without the analyzer the pass only imports feed-provided transcripts,
        // which is a small download and does not need external power.
        let chargingRequiredForOnDeviceTranscriptions =
            await settingsActor.getAutomaticOnDeviceTranscriptionsRequiresCharging()
        guard Task.isCancelled == false else { return }
        let requiresCharging = automaticTranscriptionsEnabled
            && chargingRequiredForOnDeviceTranscriptions

        // Never cancel-and-resubmit a pending request. The app backgrounds many
        // times a day and every resubmit pushed `earliestBeginDate` out again, so
        // on a phone that gets picked up regularly the task kept sliding and
        // never became eligible.
        let pendingRequest = await BGTaskScheduler.shared.pendingTaskRequests().first {
            $0.identifier == BackgroundTaskConfiguration.automaticTranscriptionIdentifier
        }
        guard Task.isCancelled == false else { return }
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
        AppDiagnostics.log("schedule automaticTranscriptionProcessing")
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
            AppDiagnostics.log(error.localizedDescription)
        }
    }

    /// Adds a completed local download to the device-only alignment queue, then
    /// asks iOS for an opportunistic processing window while the device is idle.
    static func enqueuePublisherTranscriptSynchronization(for episodeURL: URL) async {
        guard let container = await ModelContainerManager.shared
            .prepareContainerForExternalEntryPoint() else { return }
        let settingsActor = PodcastSettingsModelActor(modelContainer: container)
        guard await settingsActor.getPublisherTranscriptSynchronizationEnabled() else { return }

        await TranscriptAlignmentStoreActor(modelContainer: container).enqueue(episodeURL: episodeURL)
        await schedulePublisherTranscriptSynchronizationIfNeeded()
    }

    /// Background analysis is independent from automatic transcript generation.
    /// It requires power, uses no network, and is scheduled only while the user
    /// has opted in and downloaded episodes are queued.
    static func schedulePublisherTranscriptSynchronizationIfNeeded() async {
        guard StoreRuntimeProjection.isLibraryBackfillPending == false else { return }
        guard let container = await ModelContainerManager.shared
            .prepareContainerForExternalEntryPoint() else { return }
        guard Task.isCancelled == false else { return }
        let settingsActor = PodcastSettingsModelActor(modelContainer: container)
        let queue = TranscriptAlignmentStoreActor(modelContainer: container)
        let enabled = await settingsActor.getPublisherTranscriptSynchronizationEnabled()
        guard Task.isCancelled == false else { return }
        guard enabled else {
            await queue.clearPendingJobs()
            guard Task.isCancelled == false else { return }
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: BackgroundTaskConfiguration.publisherTranscriptSynchronizationIdentifier
            )
            return
        }

        let hasPendingJobs = await queue.hasPendingJobs()
        guard Task.isCancelled == false else { return }
        guard hasPendingJobs else {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: BackgroundTaskConfiguration.publisherTranscriptSynchronizationIdentifier
            )
            return
        }

        let identifier = BackgroundTaskConfiguration.publisherTranscriptSynchronizationIdentifier
        let alreadyPending = await BGTaskScheduler.shared.pendingTaskRequests().contains {
            $0.identifier == identifier
        }
        guard Task.isCancelled == false else { return }
        guard alreadyPending == false else { return }

        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: BackgroundTaskConfiguration.publisherTranscriptSynchronizationInterval
        )
        do {
            try BGTaskScheduler.shared.submit(request)
            CrashBreadcrumbs.shared.record("publisher_transcript_sync_background_task_scheduled")
        } catch {
            CrashBreadcrumbs.shared.record(
                "publisher_transcript_sync_background_task_schedule_failed",
                details: error.localizedDescription
            )
            AppDiagnostics.log(error.localizedDescription)
        }
    }

    private func handlePublisherTranscriptSynchronization(task: BGProcessingTask) {
        beginBackgroundTaskDiagnostics(task)
        CrashBreadcrumbs.shared.record("publisher_transcript_sync_background_task_started")
        let processingTask = Task(priority: .utility) {
            guard Player.hasActivePlaybackInProcess == false else {
                await Self.schedulePublisherTranscriptSynchronizationIfNeeded()
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "publisher_transcript_sync",
                    requestedSuccess: true,
                    waitForExportQuiescence: true,
                    details: "skipped=playback_active"
                )
                return
            }

            guard let container = await ModelContainerManager.shared
                .prepareContainerForExternalEntryPoint(), Task.isCancelled == false else {
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "publisher_transcript_sync",
                    requestedSuccess: false,
                    waitForExportQuiescence: true,
                    details: "container_available=false"
                )
                return
            }
            let settingsActor = PodcastSettingsModelActor(modelContainer: container)
            let enabled = await settingsActor.getPublisherTranscriptSynchronizationEnabled()
            guard Task.isCancelled == false else {
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "publisher_transcript_sync",
                    requestedSuccess: false,
                    waitForExportQuiescence: true,
                    details: "cancelled_after_settings=true"
                )
                return
            }
            guard enabled else {
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "publisher_transcript_sync",
                    requestedSuccess: true,
                    waitForExportQuiescence: true,
                    details: "enabled=false"
                )
                return
            }
            await Self.schedulePublisherTranscriptSynchronizationIfNeeded()
            guard Task.isCancelled == false else {
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "publisher_transcript_sync",
                    requestedSuccess: false,
                    waitForExportQuiescence: true,
                    details: "cancelled_after_schedule=true"
                )
                return
            }
            await TranscriptSynchronizationService.shared.setEnabled(true)
            guard Task.isCancelled == false else {
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "publisher_transcript_sync",
                    requestedSuccess: false,
                    waitForExportQuiescence: true,
                    details: "cancelled_before_jobs=true"
                )
                return
            }
            let completedCount = await TranscriptSynchronizationService.shared.runQueuedBackgroundJobs(
                libraryContainer: container,
                episodeLimit: BackgroundTaskConfiguration.publisherTranscriptSynchronizationEpisodeLimit
            )
            guard Task.isCancelled == false else {
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "publisher_transcript_sync",
                    requestedSuccess: false,
                    waitForExportQuiescence: true,
                    details: "completed_count=\(completedCount)"
                )
                return
            }

            await Self.schedulePublisherTranscriptSynchronizationIfNeeded()
            CrashBreadcrumbs.shared.record(
                "publisher_transcript_sync_background_task_completed",
                details: "completed_count=\(completedCount)"
            )
            await self.finishBackgroundProcessingTask(
                task,
                operation: "publisher_transcript_sync",
                requestedSuccess: true,
                waitForExportQuiescence: true,
                details: "completed_count=\(completedCount)"
            )
        }

        task.expirationHandler = {
            processingTask.cancel()
            Task { await TranscriptSynchronizationService.shared.cancelAll() }
        }
    }

    private static func scheduleFeedProcessing() async {
        await FeedProcessingScheduler.schedule()
    }

    private func handleFeedProcessing(task: BGProcessingTask) {
        beginBackgroundTaskDiagnostics(task)
        CrashBreadcrumbs.shared.record("feed_processing_background_task_started")
        let processingTask = Task(priority: .utility) {
            await ModelContainerManager.shared.prepareContainer()
            guard let container = ModelContainerManager.shared.preparedContainer,
                  Task.isCancelled == false else {
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "feed_processing",
                    requestedSuccess: false,
                    waitForExportQuiescence: false,
                    details: "container_available=false"
                )
                return
            }

            await SubscriptionManager(modelContainer: container).bgupdateFeeds(reason: .processing)
            guard Task.isCancelled == false else {
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "feed_processing",
                    requestedSuccess: false,
                    waitForExportQuiescence: true,
                    details: "cancelled_after_feed_refresh=true"
                )
                return
            }
            await PredictedReleaseRefreshScheduler.schedule(using: container)
            guard Task.isCancelled == false else {
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "feed_processing",
                    requestedSuccess: false,
                    waitForExportQuiescence: true,
                    details: "cancelled_after_release_schedule=true"
                )
                return
            }

            // Feeds were just refreshed, so any transcript a podcast published
            // is known now. Importing those here costs a few small downloads and
            // spares the analyzer the episodes it never needed to run on.
            // `TranscriptionManager.shared` builds itself on the main actor, so
            // reach it from there: this task can be the first thing to touch it
            // in a background launch of the process.
            let importedTranscriptCount: Int
            if Player.hasActivePlaybackInProcess {
                importedTranscriptCount = 0
            } else {
                let transcriptionManager = await MainActor.run { TranscriptionManager.shared }
                guard Task.isCancelled == false else {
                    await self.finishBackgroundProcessingTask(
                        task,
                        operation: "feed_processing",
                        requestedSuccess: false,
                        waitForExportQuiescence: true,
                        details: "cancelled_before_transcript_import=true"
                    )
                    return
                }
                importedTranscriptCount = await transcriptionManager
                    .runAutomaticTranscriptionsFromPlaylists(
                        allowOnDeviceFallback: false,
                        episodeLimit: BackgroundTaskConfiguration.feedProcessingTranscriptImportLimit,
                        budget: BackgroundTaskConfiguration.feedProcessingTranscriptImportBudget
                    )
            }
            guard Task.isCancelled == false else {
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "feed_processing",
                    requestedSuccess: false,
                    waitForExportQuiescence: true,
                    details: "cancelled_after_transcript_import=true"
                )
                return
            }
            CrashBreadcrumbs.shared.record(
                "feed_processing_background_task_completed",
                details: "imported_transcripts=\(importedTranscriptCount)"
            )
            await self.finishBackgroundProcessingTask(
                task,
                operation: "feed_processing",
                requestedSuccess: true,
                waitForExportQuiescence: true,
                details: "imported_transcripts=\(importedTranscriptCount)"
            )
        }

        task.expirationHandler = {
            CrashBreadcrumbs.shared.record(
                "background_task_expired",
                details: "operation=feed_processing"
            )
            processingTask.cancel()
        }
    }

    private func handleAutomaticTranscriptionProcessing(task: BGProcessingTask) {
        beginBackgroundTaskDiagnostics(task)
        CrashBreadcrumbs.shared.record("automatic_transcription_background_task_started")
        let processingTask = Task(priority: .utility) {
            guard Player.hasActivePlaybackInProcess == false else {
                CrashBreadcrumbs.shared.record(
                    "automatic_transcription_background_task_skipped",
                    details: "playback_active"
                )
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "automatic_transcription",
                    requestedSuccess: true,
                    waitForExportQuiescence: false,
                    details: "skipped=playback_active"
                )
                return
            }
            await ModelContainerManager.shared.prepareContainer()
            guard ModelContainerManager.shared.preparedContainer != nil,
                  Task.isCancelled == false else {
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "automatic_transcription",
                    requestedSuccess: false,
                    waitForExportQuiescence: false,
                    details: "container_available=false"
                )
                return
            }

            await Self.scheduleAutomaticTranscriptionProcessingIfNeeded()
            guard Task.isCancelled == false else {
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "automatic_transcription",
                    requestedSuccess: false,
                    waitForExportQuiescence: true,
                    details: "cancelled_after_schedule=true"
                )
                return
            }

            // Work through several episodes per launch instead of one: iOS hands
            // out these windows sparingly, and a single episode left most of the
            // granted time unused.
            let transcriptionManager = await MainActor.run { TranscriptionManager.shared }
            guard Task.isCancelled == false else {
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "automatic_transcription",
                    requestedSuccess: false,
                    waitForExportQuiescence: true,
                    details: "cancelled_before_transcription=true"
                )
                return
            }
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
                await self.finishBackgroundProcessingTask(
                    task,
                    operation: "automatic_transcription",
                    requestedSuccess: false,
                    waitForExportQuiescence: true,
                    details: "processed_count=\(processedCount)"
                )
                return
            }

            // Re-arm again now that the launched request is definitely consumed.
            // No-ops when the request submitted at the start of the pass is still
            // pending, so this only covers the case where it was not.
            await Self.scheduleAutomaticTranscriptionProcessingIfNeeded()
            await self.finishBackgroundProcessingTask(
                task,
                operation: "automatic_transcription",
                requestedSuccess: true,
                waitForExportQuiescence: true,
                details: "processed_count=\(processedCount)"
            )
        }

        task.expirationHandler = {
            processingTask.cancel()
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == SkipProtectionNotification.undoActionIdentifier {
            let userInfo = response.notification.request.content.userInfo
            let undoID = (userInfo[SkipProtectionNotification.undoIDUserInfoKey] as? String)
                .flatMap(UUID.init(uuidString:))
            let expiresAt = (userInfo[SkipProtectionNotification.expiresAtUserInfoKey] as? Double)
                .map(Date.init(timeIntervalSince1970:))

            guard let undoID, let expiresAt, expiresAt > Date() else {
                Task {
                    await NotificationManager.shared.removeSkipProtectionUndoNotification()
                }
                completionHandler()
                return
            }

            Task { @MainActor in
                guard await ModelContainerManager.shared
                    .prepareContainerForExternalEntryPoint() != nil else {
                    return
                }
                await Player.shared.undoSkipProtection(undoID: undoID)
            }
            completionHandler()
            return
        }

        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo
        if let podcastFeed = userInfo["podcastFeed"] as? String,
           let liveItem = userInfo["liveItem"] as? String {
            NotificationCenter.default.post(
                name: .livePodcastNotificationTapped,
                object: nil,
                userInfo: ["podcastFeed": podcastFeed, "liveItem": liveItem]
            )
            return
        }

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
