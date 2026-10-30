import Foundation

/// Allows detached PodcastCache writers to observe playback transitions
/// synchronously, without touching MainActor-isolated Player from SwiftData.
final class StoreSplitCachePlaybackGate: @unchecked Sendable {
    static let shared = StoreSplitCachePlaybackGate()

    private let lock = NSLock()
    private var playbackActive = false

    var canRun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return playbackActive == false
    }

    func setPlaybackActive(_ active: Bool) {
        lock.lock()
        playbackActive = active
        lock.unlock()
    }
}

enum StoreSplitMaintenancePolicy {
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
            // Launch re-arms any pending import; it does not itself indicate
            // new CloudKit content or require restarting the dry run.
            ModelContainerManager.requestBackgroundUserStateImport(newGeneration: false)
        }
        // Launch never starts a maintenance runner; a pending import is
        // applied by the foreground reconcile or the background pass.
        await publishPendingState()
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

    /// A CloudKit import landed (or the app became active with one pending).
    /// The request is recorded durably first, so the background pass still
    /// picks it up; while the app is in the foreground the reconcile also runs
    /// here, because nothing else brings other devices' changes into the
    /// runtime graph. The ledger entry is cleared only by a completed
    /// reconcile (see `runLoop`).
    func scheduleCloudImportReconcile() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else { return }
        ModelContainerManager.requestBackgroundUserStateImport()
        enqueueReconcile(
            authoritativePlaylists: false,
            force: false,
            refreshMissingFeeds: true,
            reason: "cloud_import_foreground"
        )
        await publishPendingState()
        startRunnerIfNeeded()
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
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else { return }
        ModelContainerManager.requestBackgroundUserStateImport()
        enqueueReconcile(
            authoritativePlaylists: authoritativePlaylists,
            force: true,
            refreshMissingFeeds: true,
            reason: "manual"
        )
        await publishPendingState()
        startRunnerIfNeeded()
    }

    private func clearAllPendingWork(reason: String) async {
        pendingReconcile = nil
        pendingAIImport = false
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
            let admission = await MainActor.run {
                (
                    playbackActive: Player.shared.isPlaying,
                    exportActive: ModelContainerManager.shared.isCloudKitExportInProgress
                )
            }
            guard let maintenancePermit = StoreMaintenanceResourceBudget.shared.acquire(
                operation: nextJob.rawValue,
                playbackActive: admission.playbackActive,
                cloudKitExportActive: admission.exportActive
            ) else {
                await publishPendingState()
                nextHeavyWorkAllowedAt = Date().addingTimeInterval(30)
                continue
            }
            let startedAt = Date()
            let cpuStartedAt = SystemProcessCPUTimeSource().sample().cpuTime
            await publishCurrentJob(nextJob)

            switch nextJob {
            case .reconcile:
                guard let request = pendingReconcile else {
                    maintenancePermit.release()
                    await clearCurrentJob()
                    continue
                }
                pendingReconcile = nil
                // Taken before the pass: an import requested while it runs has
                // a newer generation and stays pending.
                let importRequest = StoreSplitPendingImportLedger.snapshot(
                    in: UserDefaults(suiteName: ModelContainerManager.appGroupID) ?? .standard
                )
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
                    if importRequest.pending {
                        ModelContainerManager.clearPendingBackgroundUserStateImport(
                            generation: importRequest.generation
                        )
                    }
                }
            case .aiImport:
                pendingAIImport = false
                await ModelContainerManager.shared.performSplitStoreAIImportIfPossible()
            }

            maintenancePermit.release()
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
            let runtimeState = await MainActor.run {
                (
                    playbackActive: Player.hasActivePlaybackInProcess,
                    backgroundProcessingActive: ModelContainerManager.shared.isRunningBackgroundProcessingTask
                )
            }
            let cpuDelta = max(
                0,
                SystemProcessCPUTimeSource().sample().cpuTime - cpuStartedAt
            )
            AppDiagnostics.log(
                "store_split_worker_finished operation=\(nextJob.rawValue) duration_ms=\(Int(duration * 1_000)) process_cpu_seconds_delta=\(String(format: "%.2f", cpuDelta)) playback_active=\(runtimeState.playbackActive) background_processing_active=\(runtimeState.backgroundProcessingActive)"
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
        }
        return nextPendingJob()
    }

    private func nextPendingJob() -> Job? {
        if pendingReconcile != nil { return .reconcile }
        if pendingAIImport { return .aiImport }
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
        while currentJob != nil || pendingReconcile != nil || pendingAIImport {
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
