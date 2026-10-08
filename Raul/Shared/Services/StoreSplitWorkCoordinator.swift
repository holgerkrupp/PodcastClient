import Foundation

enum StoreMaintenanceExecutionContext: Equatable, Sendable {
    case foreground
    case systemBackgroundProcessing
    case test
}

enum StoreSplitMaintenancePolicy {
    static func allowsHeavyMaintenance(
        in context: StoreMaintenanceExecutionContext
    ) -> Bool {
        context != .foreground
    }

    static func shouldYieldForCloudKitExport(
        exportInProgress: Bool
    ) -> Bool {
        exportInProgress
    }
}

actor StoreSplitWorkCoordinator {
    static let shared = StoreSplitWorkCoordinator()

    enum Job: String, Sendable {
        case reconcile = "Reconcile user state"
        case aiImport = "Import AI content"
        case migration = "Migrate split stores"
        case feedCachePrewarm = "Prewarm PodcastCache"
    }

    private struct ReconcileRequest: Sendable {
        var authoritativePlaylists: Bool
        var force: Bool
        var refreshMissingFeeds: Bool
        var reason: String

        mutating func merge(
            authoritativePlaylists: Bool,
            force: Bool,
            refreshMissingFeeds: Bool,
            reason: String
        ) {
            self.authoritativePlaylists = self.authoritativePlaylists || authoritativePlaylists
            self.force = self.force || force
            self.refreshMissingFeeds = self.refreshMissingFeeds || refreshMissingFeeds
            if self.reason.isEmpty || self.reason == "idle" {
                self.reason = reason
            } else if self.reason.contains(reason) == false {
                self.reason += ", \(reason)"
            }
        }
    }

    private var currentJob: Job?
    private var pendingReconcile: ReconcileRequest?
    private var pendingAIImport = false
    private var pendingMigration = false
    private var pendingFeedCachePrewarm = false
    private var pendingPlaybackIdleReconcile = false
    private var runnerTask: Task<Void, Never>?
    private var nextHeavyWorkAllowedAt = Date.distantPast
    private var backoffSeconds: TimeInterval = 0.25
    private var cloudKitCoolDownUntil = Date.distantPast

    func resumeAfterCloudKitExport() async {
        cloudKitCoolDownUntil = Date().addingTimeInterval(5)
        nextHeavyWorkAllowedAt = max(nextHeavyWorkAllowedAt, cloudKitCoolDownUntil)
        await publishPendingState()
        startRunnerIfNeeded()
    }

    func scheduleLaunchWork() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            await clearAllPendingWork(reason: "paused for stability")
            return
        }
        if StoreDevelopmentConfiguration.userStateImportEnabled {
            ModelContainerManager.requestBackgroundUserStateImport()
        }
        // Bulk migration, reconciliation and feed-cache bootstrap are armed by
        // BGProcessingTask. Launch never starts a maintenance runner.
        await publishPendingState()
    }

    func scheduleFeedCachePrewarming() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false,
              StoreDevelopmentConfiguration.feedCachePrewarmingEnabled else {
            return
        }
        pendingFeedCachePrewarm = true
        await publishPendingState()
        startRunnerIfNeeded()
    }

    func waitForBackgroundPassToDrain() async {
        await waitForIdle()
    }

    func pauseForBackground() async {
        runnerTask?.cancel()
        runnerTask = nil
        currentJob = nil
        await publishPendingState()
    }

    func scheduleCloudImportReconcile() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else { return }
        ModelContainerManager.requestBackgroundUserStateImport()
        await publishPendingState()
    }

    func scheduleForegroundMigration() async {
        // Kept for older callers during rollout. Foreground callers only arm
        // the system request; the coordinator is not a migration executor.
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false,
              StoreDevelopmentConfiguration.legacyMigrationEnabled else { return }
#if canImport(UIKit)
        await MainActor.run {
            AppDelegate.scheduleStoreSplitMigrationProcessingIfNeeded()
        }
#endif
    }

    func notePlaybackActivityChanged(isPlaying: Bool) async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else { return }
        guard isPlaying == false else { return }
        if pendingPlaybackIdleReconcile {
            pendingPlaybackIdleReconcile = false
            enqueueReconcile(
                authoritativePlaylists: false,
                force: true,
                refreshMissingFeeds: true,
                reason: "playback_idle"
            )
        }
        await publishPendingState()
        startRunnerIfNeeded()
    }

    func runManualReconcile(authoritativePlaylists: Bool) async {
        _ = authoritativePlaylists
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else { return }
        ModelContainerManager.requestBackgroundUserStateImport()
        await publishPendingState()
    }

    func runManualMigration() async {
        await scheduleForegroundMigration()
    }

    private func clearAllPendingWork(reason: String) async {
        pendingReconcile = nil
        pendingAIImport = false
        pendingMigration = false
        pendingFeedCachePrewarm = false
        pendingPlaybackIdleReconcile = false
        currentJob = nil
        await MainActor.run {
            ModelContainerManager.shared.updateSplitStoreCoordinatorState(
                currentJob: nil,
                pendingReason: reason
            )
        }
    }

    private func enqueueReconcile(
        authoritativePlaylists: Bool,
        force: Bool,
        refreshMissingFeeds: Bool,
        reason: String
    ) {
        if var pendingReconcile {
            pendingReconcile.merge(
                authoritativePlaylists: authoritativePlaylists,
                force: force,
                refreshMissingFeeds: refreshMissingFeeds,
                reason: reason
            )
            self.pendingReconcile = pendingReconcile
        } else {
            pendingReconcile = ReconcileRequest(
                authoritativePlaylists: authoritativePlaylists,
                force: force,
                refreshMissingFeeds: refreshMissingFeeds,
                reason: reason
            )
        }
    }

    private func startRunnerIfNeeded() {
        guard runnerTask == nil else { return }
        runnerTask = Task {
            await self.runLoop()
        }
    }

    private func runLoop() async {
        while let nextJob = await nextRunnableJob() {
            if nextHeavyWorkAllowedAt > .now {
                do {
                    try await Task.sleep(for: .milliseconds(
                        Int(max(1, nextHeavyWorkAllowedAt.timeIntervalSinceNow * 1_000)
                    )))
                } catch {
                    return
                }
                guard Task.isCancelled == false else { return }
            }
            let startedAt = Date()
            await publishCurrentJob(nextJob)

            switch nextJob {
            case .reconcile:
                guard let request = pendingReconcile else { continue }
                pendingReconcile = nil
                let result = await ModelContainerManager.shared.performSplitStoreReconcile(
                    authoritativePlaylists: request.authoritativePlaylists,
                    force: request.force,
                    refreshMissingFeeds: request.refreshMissingFeeds,
                    reason: request.reason
                )
                if case .deferredForPlayback = result {
                    pendingPlaybackIdleReconcile = true
                } else if case .completed = result {
                    pendingAIImport = true
                }
            case .aiImport:
                pendingAIImport = false
                await ModelContainerManager.shared.performSplitStoreAIImportIfPossible()
            case .migration:
                pendingMigration = false
                let result = await ModelContainerManager.shared
                    .performSplitStoreMigrationIfNeeded()
                switch result {
                case .completed, .progressed, .deferred:
                    break
                case let .blocked(reason), let .failed(reason):
                    // The manager records the blocker and schedules a delayed
                    // retry when the cause can recover (store preparation,
                    // CloudKit export, or a transient save failure). Keep the
                    // coordinator queue clear here so a blocked launch cannot
                    // spin at full speed.
                    await MainActor.run {
                        ModelContainerManager.shared.updateSplitStoreCoordinatorState(
                            currentJob: nil,
                            pendingReason: reason
                        )
                    }
                }
            case .feedCachePrewarm:
                pendingFeedCachePrewarm = false
                await ModelContainerManager.shared.performFeedCachePrewarmIfPossible(
                    feedLimit: 200
                )
            }

            await clearCurrentJob()
            let duration = Date().timeIntervalSince(startedAt)
            if duration > 1 {
                backoffSeconds = min(8, max(0.25, duration * 0.25))
                nextHeavyWorkAllowedAt = Date().addingTimeInterval(backoffSeconds)
            } else {
                backoffSeconds = max(0.25, backoffSeconds * 0.5)
                nextHeavyWorkAllowedAt = Date().addingTimeInterval(backoffSeconds)
            }
            CrashBreadcrumbs.shared.record(
                "store_split_heavy_job_finished",
                details: "operation=\(nextJob.rawValue),duration_ms=\(Int(duration * 1_000)),next_retry_ms=\(Int(backoffSeconds * 1_000))"
            )
        }

        runnerTask = nil
    }

    private func nextRunnableJob() async -> Job? {
        let appState = await MainActor.run {
            (
                isPlaying: Player.shared.isPlaying,
                mayRunHeavyWork: ModelContainerManager.shared.heavyStoreWorkMayRunInCurrentAppState,
                cloudKitExportInProgress: ModelContainerManager.shared.isCloudKitExportInProgress
            )
        }
        if appState.isPlaying {
            await publishPendingState()
            return nil
        }
        // Backgrounded without a metered `BGProcessingTask`. Leave the queue
        // intact and stop the runner: the work is re-armed on the next `.active`
        // transition rather than spending the process's background CPU budget.
        guard appState.mayRunHeavyWork else {
            await publishPendingState()
            return nil
        }
        guard appState.cloudKitExportInProgress == false else {
            await MainActor.run {
                ModelContainerManager.shared.updateSplitStoreCoordinatorState(
                    currentJob: nil,
                    pendingReason: "waiting for CloudKit export to drain"
                )
            }
            return nil
        }
        if cloudKitCoolDownUntil > .now {
            let cooldownDescription = cloudKitCoolDownUntil.formatted(
                date: .omitted,
                time: .shortened
            )
            await MainActor.run {
                ModelContainerManager.shared.updateSplitStoreCoordinatorState(
                    currentJob: nil,
                    pendingReason: "CloudKit export cool-down until \(cooldownDescription)"
                )
            }
            return pendingMigration || pendingReconcile != nil || pendingAIImport
                || pendingFeedCachePrewarm
                ? nextPendingJobWithoutExportCheck()
                : nil
        }

        // During the legacy-authoritative release, finish the backfill and its
        // deletion cleanup before importing UserState back into the legacy graph.
        // Otherwise stale destination rows could be reintroduced as source data
        // immediately before the authoritative pass runs.
        if pendingMigration,
           StoreSplitReleasePhase.current == .dualSyncBackfill {
            return .migration
        }
        if pendingFeedCachePrewarm {
            return .feedCachePrewarm
        }
        if pendingReconcile != nil {
            return .reconcile
        }
        if pendingAIImport {
            return .aiImport
        }
        if pendingMigration {
            return .migration
        }
        return nil
    }

    private func nextPendingJobWithoutExportCheck() -> Job? {
        if pendingMigration, StoreSplitReleasePhase.current == .dualSyncBackfill {
            return .migration
        }
        if pendingFeedCachePrewarm { return .feedCachePrewarm }
        if pendingReconcile != nil { return .reconcile }
        if pendingAIImport { return .aiImport }
        if pendingMigration { return .migration }
        return nil
    }

    /// Waits for the queue to drain, but only while a runner is actually
    /// draining it.
    ///
    /// `nextRunnableJob()` deliberately stops the runner with the queue intact
    /// when playback is running or the app is backgrounded, so the wait
    /// condition can stay true forever. Combined with `try?` swallowing the
    /// `CancellationError` from `Task.sleep` — which makes the sleep return
    /// instantly once the caller's task is cancelled, e.g. when the view that
    /// asked for the reconcile goes away — this spun the actor's executor at
    /// 100% CPU until iOS killed the process on the 80%-over-60s limit.
    private func waitForIdle() async {
        while currentJob != nil || pendingReconcile != nil || pendingAIImport
            || pendingMigration || pendingFeedCachePrewarm {
            // Nobody left to drain the queue: the work stays queued for the
            // next `.active` transition, and this caller stops waiting.
            guard runnerTask != nil else { return }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
    }

    private func publishCurrentJob(_ job: Job) async {
        currentJob = job
        await MainActor.run {
            ModelContainerManager.shared.updateSplitStoreCoordinatorState(
                currentJob: job.rawValue,
                pendingReason: nil
            )
        }
    }

    private func clearCurrentJob() async {
        currentJob = nil
        await publishPendingState()
    }

    private func publishPendingState() async {
        let pendingReason: String?
        let currentJobDescription = currentJob?.rawValue
        if let pendingReconcile {
            pendingReason = pendingReconcile.reason
        } else if pendingPlaybackIdleReconcile {
            pendingReason = "waiting for playback to stop"
        } else if pendingAIImport {
            pendingReason = "ai import"
        } else if pendingMigration {
            pendingReason = "migration"
        } else if pendingFeedCachePrewarm {
            pendingReason = "PodcastCache prewarming"
        } else {
            pendingReason = nil
        }

        await MainActor.run {
            ModelContainerManager.shared.updateSplitStoreCoordinatorState(
                currentJob: currentJobDescription,
                pendingReason: pendingReason
            )
        }
    }
}
