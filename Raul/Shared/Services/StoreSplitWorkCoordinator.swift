import Foundation

actor StoreSplitWorkCoordinator {
    static let shared = StoreSplitWorkCoordinator()

    enum Job: String, Sendable {
        case reconcile = "Reconcile user state"
        case aiImport = "Import AI content"
        case migration = "Migrate split stores"
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
    private var pendingPlaybackIdleReconcile = false
    private var runnerTask: Task<Void, Never>?

    func scheduleLaunchWork() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            await clearAllPendingWork(reason: "paused for stability")
            return
        }
        if StoreDevelopmentConfiguration.newStoreReadsEnabled {
            // Not forced: respect the recency debounce so a quick relaunch doesn't
            // re-run a full heavy reconcile (which holds the shared-container DB
            // lock). The projection from the previous run is already persisted.
            enqueueReconcile(
                authoritativePlaylists: false,
                force: false,
                refreshMissingFeeds: true,
                reason: "launch"
            )
        }
        await publishPendingState()
        startRunnerIfNeeded()
    }

    func pauseForBackground() async {
        runnerTask?.cancel()
        runnerTask = nil
        pendingReconcile = nil
        pendingAIImport = false
        pendingMigration = false
        pendingPlaybackIdleReconcile = false
        currentJob = nil
        await publishPendingState()
    }

    func scheduleCloudImportReconcile() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else { return }
        enqueueReconcile(
            authoritativePlaylists: false,
            force: false,
            refreshMissingFeeds: true,
            reason: "cloud_import"
        )
        await publishPendingState()
        startRunnerIfNeeded()
    }

    func scheduleForegroundMigration() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else { return }
        guard StoreDevelopmentConfiguration.legacyMigrationEnabled else { return }
        pendingMigration = true
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
        enqueueReconcile(
            authoritativePlaylists: authoritativePlaylists,
            force: true,
            refreshMissingFeeds: true,
            reason: "manual"
        )
        await publishPendingState()
        startRunnerIfNeeded()
        if await MainActor.run(body: { Player.shared.isPlaying }) {
            return
        }
        await waitForIdle()
    }

    func runManualMigration() async {
        guard StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            return
        }
        guard StoreDevelopmentConfiguration.legacyMigrationEnabled else { return }
        pendingMigration = true
        await publishPendingState()
        startRunnerIfNeeded()
        if await MainActor.run(body: { Player.shared.isPlaying }) {
            return
        }
        await waitForIdle()
    }

    private func clearAllPendingWork(reason: String) async {
        pendingReconcile = nil
        pendingAIImport = false
        pendingMigration = false
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
                await ModelContainerManager.shared.performSplitStoreMigrationIfNeeded()
            }

            await clearCurrentJob()
        }

        runnerTask = nil
    }

    private func nextRunnableJob() async -> Job? {
        if await MainActor.run(body: { Player.shared.isPlaying }) {
            await publishPendingState()
            return nil
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

    private func waitForIdle() async {
        while currentJob != nil || pendingReconcile != nil || pendingAIImport || pendingMigration {
            try? await Task.sleep(for: .milliseconds(100))
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
