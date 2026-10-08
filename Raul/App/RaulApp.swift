import SwiftUI
import SwiftData
import BackgroundTasks
import ESADesignKit
import TipKit
import CloudKitSyncMonitor

enum BackgroundTaskConfiguration {
    static let feedRefreshIdentifier = "checkFeedUpdates"
    static let predictedReleaseRefreshIdentifier = "refreshPredictedRelease"
    static let feedProcessingIdentifier = "processFeedUpdates"
    static let storageCleanupIdentifier = "storageCleanup"
    static let automaticTranscriptionIdentifier = "automaticTranscriptionProcessing"
    static let storeSplitMigrationIdentifier = "processStoreSplitMigration"
    static let feedRefreshInterval: TimeInterval = 60 * 60
    static let predictedReleaseRefreshOffset: TimeInterval = 5 * 60
    static let predictedReleaseRefreshMinimumScheduleDelay: TimeInterval = 60
    static let predictedReleaseRefreshRetryDelay: TimeInterval = 30 * 60
    static let predictedReleaseRefreshPodcastLimit = 5
    /// Floor for the overnight migration pass. `requiresExternalPower` already
    /// restricts it to charging, so a short floor just makes the request eligible
    /// sooner and lets iOS pick the moment. A multi-hour floor only delayed the
    /// first opportunity without buying anything.
    static let storeSplitMigrationInterval: TimeInterval = 60 * 15
    static let feedProcessingInterval: TimeInterval = 60 * 60
    static let nightlyStorageCleanupInterval: TimeInterval = 60 * 60 * 24
    static let weeklyStorageCleanupFallbackInterval: TimeInterval = 60 * 60 * 24 * 7
    /// Floor for the automatic transcription pass. The request is a floor, not a
    /// schedule — iOS still picks the moment — so a short one just makes the task
    /// eligible sooner and gets more episodes transcribed per day.
    static let automaticTranscriptionInterval: TimeInterval = 60 * 5
    /// Wall-clock budget for one background transcription pass. Checked before
    /// starting another episode, never mid-analysis.
    static let automaticTranscriptionBackgroundBudget: TimeInterval = 60 * 20
    /// Upper bound on episodes handled in one background pass.
    static let automaticTranscriptionBackgroundEpisodeLimit = 6
    /// Feed processing rides along by importing published transcripts for
    /// playlist episodes. Keep this short because it follows the feed refresh
    /// in the same BGProcessingTask; together they must yield well before the
    /// background CPU watchdog window rather than consuming the whole grant.
    static let feedProcessingTranscriptImportBudget: TimeInterval = 15
    static let feedProcessingTranscriptImportLimit = 3
    static let lastStorageCleanupKey = "LastStorageCleanup"
    static let lastForegroundDownloadCleanupKey = "LastForegroundDownloadCleanup"
    static let foregroundDownloadCleanupMinimumInterval: TimeInterval = 60 * 60 * 12
}

/// Submits the general feed-refresh background task.
///
/// Free-standing (rather than a method on `RaulApp`) so it can run off the main
/// actor: it reads the predicted refresh window for every subscribed podcast,
/// and doing that on the main actor during the `.background` transition held the
/// main thread past the 5s suspension deadline and got the app killed.
enum FeedRefreshScheduler {
    static func schedule(using container: ModelContainer?) async -> Date? {
#if os(iOS)
        CrashBreadcrumbs.shared.record("schedule_feed_refresh_requested")
        AppDiagnostics.log("schedule checkFeedUpdates")

        let earliestBeginDate = await predictedBeginDate(using: container)
        let request = BGAppRefreshTaskRequest(
            identifier: BackgroundTaskConfiguration.feedRefreshIdentifier
        )
        request.earliestBeginDate = earliestBeginDate

        do {
            try BGTaskScheduler.shared.submit(request)
            CrashBreadcrumbs.shared.record(
                "schedule_feed_refresh_submitted",
                details: earliestBeginDate.map { "earliest=\($0)" }
            )
        } catch {
            CrashBreadcrumbs.shared.record(
                "schedule_feed_refresh_failed",
                details: error.localizedDescription
            )
            AppDiagnostics.log(error.localizedDescription)
        }
        return earliestBeginDate
#else
        return nil
#endif
    }

    private static func predictedBeginDate(using container: ModelContainer?) async -> Date? {
        let fallback = Date(timeIntervalSinceNow: BackgroundTaskConfiguration.feedRefreshInterval)
        guard let container else { return fallback }
        guard let predicted = await SubscriptionManager(modelContainer: container)
            .nextPredictedFeedRefreshDate() else {
            return fallback
        }

        let minimumDelay = Date(timeIntervalSinceNow: 15 * 60)
        return min(max(predicted, minimumDelay), fallback)
    }
}

enum PredictedReleaseRefreshScheduler {
    static func schedule(using container: ModelContainer?) async {
#if os(iOS)
        CrashBreadcrumbs.shared.record("schedule_predicted_release_refresh_requested")
        AppDiagnostics.log("schedule refreshPredictedRelease")
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: BackgroundTaskConfiguration.predictedReleaseRefreshIdentifier
        )

        guard let container else {
            CrashBreadcrumbs.shared.record(
                "schedule_predicted_release_refresh_not_scheduled",
                details: "reason=model_container_unavailable"
            )
#if DEBUG
            await PredictedReleaseRefreshScheduleStore.shared.clear()
#endif
            return
        }

        guard let schedule = await predictedReleaseRefreshSchedule(using: container) else {
            CrashBreadcrumbs.shared.record(
                "schedule_predicted_release_refresh_not_scheduled",
                details: "reason=no_prediction"
            )
#if DEBUG
            await PredictedReleaseRefreshScheduleStore.shared.clear()
#endif
            return
        }

        let request = BGAppRefreshTaskRequest(
            identifier: BackgroundTaskConfiguration.predictedReleaseRefreshIdentifier
        )
        request.earliestBeginDate = schedule.earliestBeginDate

        do {
            try BGTaskScheduler.shared.submit(request)
            CrashBreadcrumbs.shared.record(
                "schedule_predicted_release_refresh_submitted",
                details: "earliest=\(schedule.earliestBeginDate)"
            )
#if DEBUG
            await PredictedReleaseRefreshScheduleStore.shared.record(
                PredictedReleaseRefreshSchedule(
                    scheduledAt: Date(),
                    title: schedule.target.title,
                    feedURL: schedule.target.feed.absoluteString,
                    releaseDate: schedule.target.releaseDate,
                    earliestBeginDate: schedule.earliestBeginDate
                )
            )
#endif
        } catch {
            CrashBreadcrumbs.shared.record(
                "schedule_predicted_release_refresh_failed",
                details: error.localizedDescription
            )
#if DEBUG
            await PredictedReleaseRefreshScheduleStore.shared.clear()
#endif
            AppDiagnostics.log(error.localizedDescription)
        }
#endif
    }

#if os(iOS)
    private static func predictedReleaseRefreshSchedule(
        using container: ModelContainer
    ) async -> (
        target: SubscriptionManager.PredictedReleaseRefreshTarget,
        earliestBeginDate: Date
    )? {
        guard let target = await SubscriptionManager(modelContainer: container)
            .nextPredictedReleaseRefreshTarget(
                releaseDelay: BackgroundTaskConfiguration.predictedReleaseRefreshOffset,
                retryDelay: BackgroundTaskConfiguration.predictedReleaseRefreshRetryDelay
            ) else {
            return nil
        }

        let predictedBeginDate = target.nextAttemptDate(
            releaseDelay: BackgroundTaskConfiguration.predictedReleaseRefreshOffset,
            retryDelay: BackgroundTaskConfiguration.predictedReleaseRefreshRetryDelay
        )
        let minimumBeginDate = Date(
            timeIntervalSinceNow: BackgroundTaskConfiguration.predictedReleaseRefreshMinimumScheduleDelay
        )
        return (target, max(predictedBeginDate, minimumBeginDate))
    }
#endif
}

@main
struct RaulApp: App {
    @StateObject private var modelContainerManager = ModelContainerManager.shared
    @StateObject private var syncMonitor = SyncMonitor.default
    @StateObject private var storeCloudKitMonitor = StoreCloudKitActivityMonitor.shared
    @State private var downloadedFilesManager = DownloadedFilesManager.shared
    @State private var settingsRequest = SettingsWindowRequest.global
    @State private var deferredStoreSplitTask: Task<Void, Never>?
    @State private var deferredForegroundFeedRefreshTask: Task<Void, Never>?
    @State private var cloudImportReconciliationTask: Task<Void, Never>?
    @State private var launchHealthTask: Task<Void, Never>?
    @State private var foregroundCleanupTask: Task<Void, Never>?
    @State private var foregroundStorageTask: Task<Void, Never>?
    @State private var foregroundTranscriptionTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var phase
#if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self)
    private var macAppDelegate

    @AppStorage(MacMenuBarPlayerPreferenceKeys.isEnabled)
    private var isMacMenuBarPlayerEnabled = true

    private var isMacMenuBarPlayerInserted: Binding<Bool> {
        Binding(
            get: {
                MacMenuBarPlayerSupport.isAvailable && isMacMenuBarPlayerEnabled
            },
            set: { newValue in
                guard MacMenuBarPlayerSupport.isAvailable else { return }
                isMacMenuBarPlayerEnabled = newValue
            }
        )
    }
#endif
#if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif

    init() {
        // Install the store-aware event observer before SwiftData opens either
        // mirrored container. The aggregate CloudKitSyncMonitor is UI-only and
        // can lose the legacy export when two stores overlap.
        _ = StoreCloudKitActivityMonitor.shared
        SiriShortcutVocabularyCoordinator.start()
        CrashBreadcrumbs.shared.record("raul_app_init_start")
        CrashBreadcrumbs.shared.record("raul_app_init_completed")
    }

    var body: some Scene {

        
#if os(macOS)
        // The Mac app has one primary window. Using `Window` instead of a
        // `WindowGroup` prevents multiple restored copies of the main window
        // from starting competing launch views.
        let mainWindow = Window("Up Next", id: AppWindowID.main) {
            RootWindowView(
                modelContainerManager: modelContainerManager,
                downloadedFilesManager: downloadedFilesManager,
                settingsRequest: $settingsRequest
            )
        }
#elseif os(iOS) && !targetEnvironment(macCatalyst)
        // SwiftUI may evaluate a WindowGroup's static content callback on its
        // async-renderer thread. Pass a genuinely nonisolated function value:
        // writing an equivalent trailing closure here makes Swift emit a main-
        // actor executor guard, which is the guard seen in the crash reports.
        let mainWindow = WindowGroup<RootWindowView>(
            "Up Next",
            id: AppWindowID.main,
            makeContent: RootWindowView.make
        )
#else
        let mainWindow = WindowGroup("Up Next", id: AppWindowID.main) {
            RootWindowView(
                modelContainerManager: modelContainerManager,
                downloadedFilesManager: downloadedFilesManager,
                settingsRequest: $settingsRequest
            )
        }
#endif
        mainWindow
#if os(macOS)
        .defaultLaunchBehavior(.presented)
#endif
#if os(macOS) || targetEnvironment(macCatalyst)
        .commands {
            AppCommands(
                settingsRequest: $settingsRequest,
                isPlayerReady: modelContainerManager.preparedContainer != nil
            )
        }
#endif
        .onChange(of: phase, {
            CrashBreadcrumbs.shared.record("scene_phase_changed", details: "\(phase)")
            switch phase {
            case .background:
                launchHealthTask?.cancel()
                launchHealthTask = nil
                foregroundCleanupTask?.cancel()
                foregroundCleanupTask = nil
                foregroundStorageTask?.cancel()
                foregroundStorageTask = nil
                foregroundTranscriptionTask?.cancel()
                foregroundTranscriptionTask = nil
                modelContainerManager.pauseSplitStoreWorkForBackground()
                deferredStoreSplitTask?.cancel()
                deferredStoreSplitTask = nil
                deferredForegroundFeedRefreshTask?.cancel()
                deferredForegroundFeedRefreshTask = nil
                // Armed by a CloudKit import that succeeded shortly before this
                // transition. Left running it fired 30s into the background and
                // started the full reconcile with no granted budget.
                cloudImportReconciliationTask?.cancel()
                cloudImportReconciliationTask = nil
                // Detached on purpose: both schedulers read the predicted
                // refresh window for every subscribed podcast, and running that
                // on the main actor during the suspension hand-off held the main
                // thread past the 5s deadline and got the app killed.
                let containerForScheduling = modelContainerManager.preparedContainer
                Task.detached(priority: .utility) {
                    _ = await FeedRefreshScheduler.schedule(using: containerForScheduling)
                    await PredictedReleaseRefreshScheduler.schedule(using: containerForScheduling)
                }
                scheduleFeedProcessing()
                scheduleStorageCleanup()
                guard modelContainerManager.preparedContainer != nil else {
                    CrashBreadcrumbs.shared.record(
                        "background_transition_deferred",
                        details: "reason=model_container_not_prepared"
                    )
                    return
                }
                Player.shared.enterBackgroundPlaybackMode()
#if canImport(UIKit)
                Task {
                    await AppDelegate.scheduleAutomaticTranscriptionProcessingIfNeeded()
                }
                AppDelegate.scheduleStoreSplitMigrationProcessingIfNeeded()
#endif
             
                
            case .active:
                launchHealthTask?.cancel()
                launchHealthTask = nil
                foregroundCleanupTask?.cancel()
                foregroundStorageTask?.cancel()
                foregroundTranscriptionTask?.cancel()
                guard modelContainerManager.preparedContainer != nil else { return }
                SiriShortcutVocabularyCoordinator.scheduleRefresh()
                modelContainerManager.resumeSplitStoreWorkForForeground()
                launchHealthTask = Task(priority: .utility) {
                    // Do not clear the launch-health marker during the exporter
                    // crash window. A healthy checkpoint requires the app to
                    // remain usable long enough for the launch-time exporter to
                    // prove it is not immediately exhausting the CPU budget.
                    try? await Task.sleep(for: .seconds(75))
                    guard Task.isCancelled == false else { return }
#if canImport(UIKit)
                    // `phase` belongs to the Scene value captured when this
                    // task was created; query the live application state.
                    guard UIApplication.shared.applicationState == .active else { return }
#else
                    guard phase == .active else { return }
#endif
                    StoreSplitLaunchHealth.markHealthy()
                    if storeCloudKitMonitor.activeExportEvents.allSatisfy({
                        $0.storeKind == .userState
                    }) {
                        LegacyCloudExportRecovery.clearAfterHealthyIdle()
                    }
                    CrashBreadcrumbs.shared.record("store_split_launch_marked_healthy")
                }
                refreshOnActive()
                scheduleStoreSplitMigration()
                Task(priority: .userInitiated) {
                    await Task.yield()
                    await Player.shared.enterForegroundPlaybackMode()
                    await Player.shared.reloadPlaybackStateFromPersistenceIfNeeded()
                }
                foregroundCleanupTask = Task(priority: .utility) {
                    try? await Task.sleep(for: .seconds(4))
                    guard Task.isCancelled == false,
                          isAppActiveForForegroundWork else { return }
                    await cleanUp()
                }
                foregroundStorageTask = Task(priority: .background) {
                    try? await Task.sleep(for: .seconds(8))
                    guard Task.isCancelled == false,
                          isAppActiveForForegroundWork else { return }
                    await runScheduledStorageCleanupIfNeeded(
                        minimumInterval: BackgroundTaskConfiguration.weeklyStorageCleanupFallbackInterval,
                        reason: "active fallback"
                    )
                }
                foregroundTranscriptionTask = Task(priority: .background) {
                    try? await Task.sleep(for: .seconds(10))
                    guard Task.isCancelled == false,
                          isAppActiveForForegroundWork else { return }
                    await RaulApp.runAutomaticTranscriptionSweep(reason: "active")
                }
          
                
            case .inactive:
                launchHealthTask?.cancel()
                launchHealthTask = nil
                foregroundCleanupTask?.cancel()
                foregroundCleanupTask = nil
                foregroundStorageTask?.cancel()
                foregroundStorageTask = nil
                foregroundTranscriptionTask?.cancel()
                foregroundTranscriptionTask = nil
            @unknown default: break
            }
        })
        .onChange(of: storeCloudKitMonitor.latestCompletedImport) { _, event in
            guard let event, event.succeeded else { return }
            scheduleStoreAwareCloudImportReconciliation(for: event.storeKind)
        }
        .onChange(of: storeCloudKitMonitor.isAnyStoreExporting) { _, exporting in
            guard exporting else { return }
            // An automatic transcript can add hundreds of related rows to the
            // legacy mirror. Stop it when Core Data starts draining history;
            // manual transcription remains under the user's control.
            Task {
                await TranscriptionManager.shared
                    .cancelAutomaticTranscriptionsForCloudKitExport()
            }
        }
        .onChange(of: syncMonitor.exportState) { _, state in
            switch state {
            case .notStarted:
                break
            case .inProgress:
                CrashBreadcrumbs.shared.record("cloudkit_export_started")
            case .succeeded:
                CrashBreadcrumbs.shared.record("cloudkit_export_succeeded")
                Task {
                    await StoreSplitWorkCoordinator.shared.resumeAfterCloudKitExport()
                }
            case .failed(_, _, let error):
                CrashBreadcrumbs.shared.record(
                    "cloudkit_export_failed",
                    details: error?.localizedDescription ?? "unknown error"
                )
                Task {
                    await StoreSplitWorkCoordinator.shared.resumeAfterCloudKitExport()
                }
            }
        }

#if os(iOS)
        .backgroundTask(.appRefresh(BackgroundTaskConfiguration.feedRefreshIdentifier)) { task in
            CrashBreadcrumbs.shared.record("feed_refresh_background_task_started")
            if await MainActor.run(body: { Player.hasActivePlaybackInProcess }) {
                // Re-arm without fetching subscription predictions or opening
                // a CloudKit-backed container during active audio playback.
                _ = await FeedRefreshScheduler.schedule(using: nil)
                CrashBreadcrumbs.shared.record(
                    "feed_refresh_background_task_skipped",
                    details: "playback_active"
                )
                return
            }
            await scheduleFeedRefresh()
            await schedulePredictedReleaseRefresh()
            await modelContainerManager.prepareContainer()

            guard let container = await MainActor.run(body: {
                modelContainerManager.preparedContainer
            }) else {
                CrashBreadcrumbs.shared.record(
                    "feed_refresh_background_task_aborted",
                    details: "reason=model_container_unavailable"
                )
                return
            }

            await SubscriptionManager(modelContainer: container).bgupdateFeeds(reason: .appRefresh)
            await schedulePredictedReleaseRefresh()
            _ = await StoreCloudKitActivityMonitor.shared
                .waitForExportQuiescence(maximumDuration: 8)
            CrashBreadcrumbs.shared.record("feed_refresh_background_task_completed")
        }
        .backgroundTask(.appRefresh(BackgroundTaskConfiguration.predictedReleaseRefreshIdentifier)) { task in
            CrashBreadcrumbs.shared.record("predicted_release_refresh_background_task_started")
            await modelContainerManager.prepareContainer()

            guard let container = await MainActor.run(body: {
                modelContainerManager.preparedContainer
            }) else {
                CrashBreadcrumbs.shared.record(
                    "predicted_release_refresh_background_task_aborted",
                    details: "reason=model_container_unavailable"
                )
                await schedulePredictedReleaseRefresh()
                return
            }

            let attemptedCount = await SubscriptionManager(modelContainer: container)
                .refreshNextPredictedReleasePodcasts(
                    limit: BackgroundTaskConfiguration.predictedReleaseRefreshPodcastLimit,
                    releaseDelay: BackgroundTaskConfiguration.predictedReleaseRefreshOffset
                )

            await schedulePredictedReleaseRefresh()
            _ = await StoreCloudKitActivityMonitor.shared
                .waitForExportQuiescence(maximumDuration: 8)
            CrashBreadcrumbs.shared.record(
                "predicted_release_refresh_background_task_completed",
                details: "attempted_count=\(attemptedCount)"
            )
        }
        .backgroundTask(.appRefresh(BackgroundTaskConfiguration.storageCleanupIdentifier)) { task in
            await scheduleStorageCleanup()
            CrashBreadcrumbs.shared.record("skip_storage_cleanup_in_background_task")
        }
#endif

#if os(macOS)
        Window("Now Playing", id: AppWindowID.player) {
            if let container = modelContainerManager.preparedContainer {
                MacPlayerWindowContent()
                    .modelContainer(container)
                    .environment(downloadedFilesManager)
                    .accentColor(.accent)
                    .withDeviceStyle()
                    .upNextVisualDesignRoot()
            } else {
                ModelContainerLaunchView(
                    errorMessage: modelContainerManager.initializationError,
                    retry: {
                        Task {
                            await modelContainerManager.prepareContainer()
                        }
                    }
                )
                .task {
                    await modelContainerManager.prepareContainer()
                }
            }
        }
        .defaultSize(width: 760, height: 820)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra(isInserted: isMacMenuBarPlayerInserted) {
            if let container = modelContainerManager.preparedContainer {
                MacMenuBarPlayerView()
                    .modelContainer(container)
                    .environment(downloadedFilesManager)
                    .accentColor(.accent)
                    .upNextVisualDesignRoot()
            } else {
                ModelContainerLaunchView(
                    errorMessage: modelContainerManager.initializationError,
                    retry: {
                        Task {
                            await modelContainerManager.prepareContainer()
                        }
                    }
                )
                .frame(width: 320, height: 240)
                .task {
                    await modelContainerManager.prepareContainer()
                }
            }
        } label: {
            MacMenuBarLabel(
                isPlayerReady: modelContainerManager.preparedContainer != nil
            )
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: SettingsWindowRequest.sceneID) {
            settingsSceneContent
        }
        .defaultSize(width: 820, height: 680)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
#elseif targetEnvironment(macCatalyst)
        WindowGroup("Now Playing", id: AppWindowID.player) {
            if let container = modelContainerManager.preparedContainer {
                MacPlayerWindowContent()
                    .modelContainer(container)
                    .environment(downloadedFilesManager)
                    .accentColor(.accent)
                    .withDeviceStyle()
                    .upNextVisualDesignRoot()
            } else {
                ModelContainerLaunchView(
                    errorMessage: modelContainerManager.initializationError,
                    retry: {
                        Task {
                            await modelContainerManager.prepareContainer()
                        }
                    }
                )
                .task {
                    await modelContainerManager.prepareContainer()
                }
            }
        }
        .defaultSize(width: 760, height: 820)

        WindowGroup("Settings", id: SettingsWindowRequest.sceneID) {
            settingsSceneContent
        }
        .defaultSize(width: 820, height: 680)
#else
        WindowGroup(
            "Settings",
            id: SettingsWindowRequest.sceneID,
            for: SettingsWindowRequest.self
        ) { request in
            if let container = modelContainerManager.preparedContainer {
                SettingsWindowContent(request: request.wrappedValue ?? .global)
                    .modelContainer(container)
                    .environment(downloadedFilesManager)
                    .accentColor(.accent)
                    .withDeviceStyle()
                    .upNextVisualDesignRoot()
            } else {
                ModelContainerLaunchView(
                    errorMessage: modelContainerManager.initializationError,
                    retry: {
                        Task {
                            await modelContainerManager.prepareContainer()
                        }
                    }
                )
                .task {
                    await modelContainerManager.prepareContainer()
                }
            }
        }
        .defaultSize(width: 680, height: 760)
#endif
    }

#if os(macOS) || targetEnvironment(macCatalyst)
    @ViewBuilder
    private var settingsSceneContent: some View {
        if let container = modelContainerManager.preparedContainer {
            SettingsWindowContent(
                request: settingsRequest,
                onOpenAllSettings: {
                    settingsRequest = .global
                }
            )
                .modelContainer(container)
                .environment(downloadedFilesManager)
                .accentColor(.accent)
                .withDeviceStyle()
                .upNextVisualDesignRoot()
        } else {
            ModelContainerLaunchView(
                errorMessage: modelContainerManager.initializationError,
                retry: {
                    Task {
                        await modelContainerManager.prepareContainer()
                    }
                }
            )
            .task {
                await modelContainerManager.prepareContainer()
            }
        }
    }
#endif
    



    func refreshOnActive(){
        guard let container = modelContainerManager.preparedContainer else { return }
        deferredForegroundFeedRefreshTask?.cancel()
        deferredForegroundFeedRefreshTask = Task(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard Task.isCancelled == false,
                  isAppActiveForForegroundWork else { return }

            WatchSyncCoordinator.refreshSoon()
            await PlayNextWidgetSync.refresh(using: container)
            await CloudSyncProgressReferenceStore.publish(modelContainer: container)

            if let lastRefresh = getLastRefreshDate(),
               lastRefresh >= Date().addingTimeInterval(-BackgroundTaskConfiguration.feedRefreshInterval) {
                CrashBreadcrumbs.shared.record(
                    "foreground_feed_refresh_skipped",
                    details: "reason=recent_refresh"
                )
                await MainActor.run {
                    deferredForegroundFeedRefreshTask = nil
                }
                return
            }

            guard Player.hasActivePlaybackInProcess == false else {
                CrashBreadcrumbs.shared.record(
                    "foreground_feed_refresh_skipped",
                    details: "reason=playback_active"
                )
                deferredForegroundFeedRefreshTask = nil
                return
            }

            CrashBreadcrumbs.shared.record("foreground_feed_refresh_scheduled")
            await SubscriptionManager(modelContainer: container).bgupdateFeeds(reason: .foregroundQuiet)
            await MainActor.run {
                deferredForegroundFeedRefreshTask = nil
            }
        }
    }

    func scheduleStoreSplitMigration() {
        deferredStoreSplitTask?.cancel()
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false,
              StoreDevelopmentConfiguration.splitStoresEnabled else {
            deferredStoreSplitTask = nil
            return
        }
        deferredStoreSplitTask = Task {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            if StoreDevelopmentConfiguration.userStateImportEnabled {
                await StoreSplitWorkCoordinator.shared.scheduleCloudImportReconcile()
            }
            // Foreground activation only arms the system request. The durable
            // worker runs when iOS grants a charging background-processing
            // window; an active session never owns the migration loop.
            await ModelContainerManager.shared.scheduleStoreSplitMigrationIfNeeded()
            await MainActor.run {
                deferredStoreSplitTask = nil
            }
        }
    }

    func scheduleStoreAwareCloudImportReconciliation(
        for storeKind: StoreCloudKitActivityMonitor.StoreKind
    ) {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false,
              storeKind != .other else { return }
        cloudImportReconciliationTask?.cancel()
        cloudImportReconciliationTask = Task {
            do {
                // Coalesce the setup/import bursts emitted while two mirrored
                // stores are opening, without delaying queue convergence by a
                // full foreground debounce interval.
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            if StoreSplitReleasePhase.current == .dualSyncBackfill,
               StoreDevelopmentConfiguration.legacyCloudSyncEnabled,
               storeKind == .legacy {
                await modelContainerManager.reconcileLegacyStoreAfterCloudKitImport()
            }
            if StoreDevelopmentConfiguration.userStateImportEnabled,
               storeKind == .userState {
                await StoreSplitWorkCoordinator.shared.scheduleCloudImportReconcile()
            }
            await MainActor.run {
                cloudImportReconciliationTask = nil
            }
        }
    }
    
    
    func cleanUp() async {
        guard isAppActiveForForegroundWork,
              Player.hasActivePlaybackInProcess == false else { return }
        guard let container = modelContainerManager.preparedContainer else { return }
        if let lastCleanup = getLastForegroundDownloadCleanupDate(),
           Date().timeIntervalSince(lastCleanup) < BackgroundTaskConfiguration.foregroundDownloadCleanupMinimumInterval {
            return
        }

        await CleanUpActor(modelContainer: container).cleanUpOldDownloads()
        guard Task.isCancelled == false else { return }
        setLastForegroundDownloadCleanupDate()
    }

    private var isAppActiveForForegroundWork: Bool {
#if canImport(UIKit)
        UIApplication.shared.applicationState == .active
#else
        phase == .active
#endif
    }

    func setLastRefreshDate(){
        UserDefaults.standard.setValue(Date().RFC1123String(), forKey: "LastBackgroundRefresh")
    }
    
    func getLastRefreshDate() -> Date? {
        let lastDate = Date.dateFromRFC1123(dateString: UserDefaults.standard.string(forKey: "LastBackgroundRefresh") ?? "")
        return lastDate
    }
    
    func setLastprocessDate(){
        UserDefaults.standard.setValue(Date().formatted(), forKey: "LastBackgroundProcess")
    }
    

    func scheduleFeedRefresh() async {
#if os(iOS)
        let container = modelContainerManager.preparedContainer
        _ = await FeedRefreshScheduler.schedule(using: container)
#endif
    }

    func schedulePredictedReleaseRefresh() async {
#if os(iOS)
        let container = await MainActor.run(body: { modelContainerManager.preparedContainer })
        await PredictedReleaseRefreshScheduler.schedule(using: container)
#endif
    }

    func scheduleFeedProcessing() {
#if os(iOS)
        CrashBreadcrumbs.shared.record("schedule_feed_processing_requested")
        AppDiagnostics.log("schedule processFeedUpdates")
        let request = BGProcessingTaskRequest(identifier: BackgroundTaskConfiguration.feedProcessingIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundTaskConfiguration.feedProcessingInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            CrashBreadcrumbs.shared.record("schedule_feed_processing_submitted")
        } catch {
            CrashBreadcrumbs.shared.record("schedule_feed_processing_failed", details: error.localizedDescription)
            AppDiagnostics.log(error.localizedDescription)
        }
#endif
    }

    func scheduleStorageCleanup() {
#if os(iOS)
        CrashBreadcrumbs.shared.record("schedule_storage_cleanup_requested")
        AppDiagnostics.log("schedule storageCleanup")
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskConfiguration.storageCleanupIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundTaskConfiguration.nightlyStorageCleanupInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            CrashBreadcrumbs.shared.record("schedule_storage_cleanup_submitted")
        } catch {
            CrashBreadcrumbs.shared.record("schedule_storage_cleanup_failed", details: error.localizedDescription)
            AppDiagnostics.log(error.localizedDescription)
        }
#endif
    }

    static func runAutomaticTranscriptionSweep(reason: String) async {
        let isPlaying = await MainActor.run {
            Player.shared.isPlaying || Player.shared.currentEpisode != nil
        }
        guard isPlaying == false else {
            CrashBreadcrumbs.shared.record(
                "automatic_transcription_sweep_skipped",
                details: "\(reason):player_active"
            )
            return
        }
        CrashBreadcrumbs.shared.record("automatic_transcription_sweep_started", details: reason)
        let startedEpisodeURL = await TranscriptionManager.shared
            .processNextAutomaticTranscriptionFromPlaylists()
        if let startedEpisodeURL {
            CrashBreadcrumbs.shared.record("automatic_transcription_sweep_started_episode", details: startedEpisodeURL.redactedPodcastURLString)
            AppDiagnostics.log("automatic transcription sweep (\(reason)) started for \(startedEpisodeURL.redactedPodcastURLString)")
        } else {
            CrashBreadcrumbs.shared.record("automatic_transcription_sweep_idle", details: reason)
        }
    }

    func setLastStorageCleanupDate(_ date: Date = Date()) {
        UserDefaults.standard.setValue(date.timeIntervalSince1970, forKey: BackgroundTaskConfiguration.lastStorageCleanupKey)
    }

    func getLastStorageCleanupDate() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: BackgroundTaskConfiguration.lastStorageCleanupKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func runScheduledStorageCleanupIfNeeded(minimumInterval: TimeInterval, reason: String) async {
        guard let container = modelContainerManager.preparedContainer else { return }
        guard Player.hasActivePlaybackInProcess == false else {
            CrashBreadcrumbs.shared.record(
                "storage_cleanup_skipped",
                details: "\(reason):playback_active"
            )
            return
        }
        CrashBreadcrumbs.shared.record("storage_cleanup_check_started", details: reason)
        if let lastCleanup = getLastStorageCleanupDate(),
           Date().timeIntervalSince(lastCleanup) < minimumInterval {
            CrashBreadcrumbs.shared.record("storage_cleanup_skipped_recent", details: reason)
            return
        }

        do {
            let result = try await StorageManagementService(modelContainer: container)
                .deleteFilesOutsideUpNext()
            let chapterImageResult = await EpisodeActor(modelContainer: container)
                .maintainChapterImageStorage()
            setLastStorageCleanupDate()
            downloadedFilesManager.rescanDownloadedFiles()
            CrashBreadcrumbs.shared.record(
                "storage_cleanup_completed",
                details: "\(reason):deleted=\(result.deletedFileCount),kept=\(result.keptUpNextFileCount),chapter_images_optimized=\(chapterImageResult.optimizedImageCount)"
            )
            AppDiagnostics.log(
                "storage cleanup (\(reason)) deleted \(result.deletedFileCount) files, kept \(result.keptUpNextFileCount) Up Next files, optimized \(chapterImageResult.optimizedImageCount) chapter images saving \(chapterImageResult.optimizedBytesSaved) bytes, restored \(chapterImageResult.restoredImageCount) Up Next chapter images"
            )
        } catch {
            CrashBreadcrumbs.shared.record("storage_cleanup_failed", details: "\(reason):\(error.localizedDescription)")
            AppDiagnostics.log("storage cleanup failed (\(reason)): \(error.localizedDescription)")
        }
    }

    func setLastForegroundDownloadCleanupDate(_ date: Date = Date()) {
        UserDefaults.standard.setValue(date.timeIntervalSince1970, forKey: BackgroundTaskConfiguration.lastForegroundDownloadCleanupKey)
    }

    func getLastForegroundDownloadCleanupDate() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: BackgroundTaskConfiguration.lastForegroundDownloadCleanupKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

}


/// Root window content.
///
/// The container-gating lives here — inside a real `View` that observes
/// `ModelContainerManager` — rather than directly in `RaulApp`'s
/// `WindowGroup` content closure. That closure was being classified by
/// SwiftUI as a `StaticBody` and re-evaluated on its off-main async-renderer
/// thread; reading `@MainActor` `ModelContainerManager` state there trapped on
/// the main-actor isolation check (EXC_BREAKPOINT /
/// swift_task_isCurrentExecutorWithFlagsImpl). Observing the object here makes
/// SwiftUI treat the read as a tracked dynamic dependency and update on the
/// main actor. On iOS, `make()` also keeps the `WindowGroup` callback itself
/// nonisolated so the async renderer can safely invoke it.
private struct RootWindowView: View {
#if os(iOS) && !targetEnvironment(macCatalyst)
    @StateObject private var modelContainerManager = ModelContainerManager.shared
    @State private var downloadedFilesManager = DownloadedFilesManager.shared
    @State private var settingsRequest = SettingsWindowRequest.global
    @State private var didScheduleLaunchWork = false

    nonisolated init() {}

    nonisolated static func make() -> RootWindowView {
        RootWindowView()
    }
#else
    @ObservedObject var modelContainerManager: ModelContainerManager
    let downloadedFilesManager: DownloadedFilesManager
    @Binding var settingsRequest: SettingsWindowRequest
    @State private var didScheduleLaunchWork = false
#endif

    var body: some View {
        if let container = modelContainerManager.preparedContainer {
            AppLaunchContainerView {
                ContentView()
#if DEBUG
                .coverHeroHarnessOverride()
#endif
                .modelContainer(container)
                .environment(downloadedFilesManager)
                .accentColor(.accent)
                .withDeviceStyle()
                .hostsSettingsPresentation(
                    modelContainer: container,
                    settingsRequest: $settingsRequest
                )

                .onAppear {
                    CrashBreadcrumbs.shared.record("root_view_on_appear")
                    guard didScheduleLaunchWork == false else { return }
                    didScheduleLaunchWork = true
                    let managerReference = DownloadedFilesManagerReference(manager: downloadedFilesManager)

#if canImport(UIKit)
                    UIDevice.current.isBatteryMonitoringEnabled = true
#endif

                    // Play-session recovery is self-throttling and schedules
                    // its own startup delay, so it must not queue behind the
                    // deferred service bootstrap (TipKit + CloudKit monitor).
                    Player.shared.startRecoveryIfNeeded()
                    Task(priority: .userInitiated) {
                        try? await Task.sleep(for: .milliseconds(250))
                        await modelContainerManager.waitUntilApplicationQueriesReady()
                        guard Task.isCancelled == false else { return }
                        await DeferredLaunchServiceBootstrap.shared.start()
                    }
                    Task(priority: .utility) {
                        try? await Task.sleep(for: .milliseconds(500))
                        await modelContainerManager.waitUntilApplicationQueriesReady()
                        guard Task.isCancelled == false else { return }
                        await DownloadManager.shared.injectDownloadedFilesManager(managerReference)
                    }
                    Task(priority: .utility) {
                        try? await Task.sleep(for: .seconds(1))
                        await modelContainerManager.waitUntilApplicationQueriesReady()
                        guard Task.isCancelled == false else { return }
                        await AutoDownloadNetworkCoordinator.shared.startMonitoringIfNeeded(
                            modelContainer: container
                        )
                        let enabled = UserDefaults.standard.bool(
                            forKey: SideloadingConfiguration.enabledKey
                        )
                        do {
                            try await SideloadingCoordinator.shared.syncEnabledState(enabled)
                        } catch {
                            AppDiagnostics.log(
                                "Failed to restore sideloading state: \(error.localizedDescription)"
                            )
                        }
                    }
                    Task(priority: .utility) {
                        try? await Task.sleep(for: .seconds(2))
                        await modelContainerManager.waitUntilApplicationQueriesReady()
                        guard Task.isCancelled == false else { return }
                        WatchSyncCoordinator.activate()
                        await CloudSyncProgressReferenceStore.publish(modelContainer: container)
                        await PlayNextWidgetSync.refresh(using: container)
                        WatchSyncCoordinator.refreshSoon()
                        PlaylistAutoDownloadCoordinator.scheduleAll(modelContainer: container)
                    }
                    Task(priority: .utility) {
                        try? await Task.sleep(for: .seconds(3))
                        await modelContainerManager.waitUntilApplicationQueriesReady()
                        guard Task.isCancelled == false else { return }
                        _ = await SubscriptionManifestSync.restoreSubscriptionsAndBootstrap(
                            modelContainer: container
                        )
                    }
                    Task(priority: .utility) {
                        try? await Task.sleep(for: .seconds(5))
                        await modelContainerManager.waitUntilApplicationQueriesReady()
                        guard Task.isCancelled == false else { return }
                        let actor = EpisodeActor(modelContainer: container)
                        await actor.migrateLegacyBackCatalogSuppressionIfNeeded()
                    }
                    TranscriptSearchLegacyStoreCleanup.removeObsoleteStore()
                    Task(priority: .background) {
                        try? await Task.sleep(for: .seconds(8))
                        await modelContainerManager.waitUntilApplicationQueriesReady()
                        guard Task.isCancelled == false else { return }
                        await RaulApp.runAutomaticTranscriptionSweep(reason: "launch")
#if canImport(UIKit)
                        // Arm the background pass at launch instead of waiting
                        // for the first background transition. It leaves an
                        // already pending request alone.
                        await AppDelegate.scheduleAutomaticTranscriptionProcessingIfNeeded()
#endif
                    }
                }
                .task {
                    await modelContainerManager.waitUntilApplicationQueriesReady()
                    try? await Task.sleep(for: .seconds(15))
                    guard Task.isCancelled == false else { return }
                    await modelContainerManager.runLaunchStoreMaintenance()
                }

#if canImport(UIKit)
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
                    CrashBreadcrumbs.shared.record("battery_state_changed")
                    Task {
                        await RaulApp.runAutomaticTranscriptionSweep(reason: "power state changed")
                    }
                }
#endif
            }
            .upNextVisualDesignRoot()
        } else {
            ModelContainerLaunchView(
                errorMessage: modelContainerManager.initializationError,
                retry: {
                    Task {
                        await modelContainerManager.prepareContainer()
                    }
                }
            )
            .task {
                await modelContainerManager.prepareContainer()
            }
        }
    }
}

private actor DeferredLaunchServiceBootstrap {
    static let shared = DeferredLaunchServiceBootstrap()

    private var didStart = false

    func start() async {
        guard didStart == false else { return }
        didStart = true

        async let tipConfiguration: Void = Task.detached(priority: .utility) {
            try? Tips.configure([
                .displayFrequency(.weekly),
                .datastoreLocation(.applicationDefault)
            ])
        }.value

        await MainActor.run {
            SyncMonitor.default.startMonitoring()
        }
        _ = await tipConfiguration
    }
}



extension DeviceUIStyle {
    var sfSymbolName: String {
        switch self {
        case .iphoneHomeButton: return "iphone.gen1"
        case .iphoneNotch: return "iphone.gen2"
        case .iphoneDynamicIsland: return "iphone.gen3"
        case .ipadHomeButton: return "ipad.gen1"
        case .ipadNoHomeButton: return "ipad.gen2"
        case .appleWatch: return "applewatch"
        case .visionPro: return "visionpro"
        case .macLaptop: return "macbook"
        case .macMini: return "macmini"
        case .macPro: return "macpro.gen3"
        case .macDesktop: return "desktopcomputer"
        @unknown default: return "questionmark.square.dashed"
        }
    }
    
    var currencySFSymbolName: String {
        let code = Locale.current.currency?.identifier  ?? ""
        
        // Map ISO currency codes to SF Symbol currency names
        let map: [String: String] = [
            "USD": "dollarsign",
            "EUR": "eurosign",
            "JPY": "yensign",
            "GBP": "sterlingsign",
            "KRW": "wonsign",
            "INR": "indianrupeesign",
            "RUB": "rublesign",
            "TRY": "turkishlirasign",
            "VND": "vietnamesedongsign",
            "ILS": "shekelsign",
            "THB": "bahtsign",
            "PLN": "zlotysign",
            "CZK": "czechkorunasign",
            "HUF": "forintsign",
            "NGN": "nairasign",
            "BRL": "brazilsign",
            "ZAR": "randsign",
            "PHP": "philippinepesosign",
            "MXN": "pesosign"
        ]
        
        let symbolBase = map[code] ?? "creditcard"
        return "\(symbolBase).circle"
    }
}
