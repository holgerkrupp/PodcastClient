#if DEBUG
import SwiftUI

struct DevelopmentSettingsView: View {
    @ObservedObject private var modelContainerManager = ModelContainerManager.shared
    @AppStorage(StoreDevelopmentConfiguration.modeKey)
    private var storeMode = DevelopmentStoreMode.splitStores
    @AppStorage(StoreDevelopmentConfiguration.legacyCloudSyncEnabledKey)
    private var legacyCloudSyncEnabled = StoreDevelopmentConfiguration
        .releaseLegacyCloudSyncEnabled
    @AppStorage(StoreDevelopmentConfiguration.userStateCloudSyncEnabledKey)
    private var userStateCloudSyncEnabled = false
    @AppStorage(StoreDevelopmentConfiguration.splitStoreWorkEnabledKey)
    private var splitStoreWorkEnabled = true
    @AppStorage(StoreDevelopmentConfiguration.migrationPausedKey)
    private var migrationPaused = false

    @State private var launchConfiguration = StoreDevelopmentConfiguration.launch
    @State private var showLocalResetConfirmation = false
    @State private var showAllLocalStoresResetConfirmation = false
    @State private var showResetConfirmation = false
    @State private var isResetting = false
    @State private var isRunningSyncAction = false
    @State private var resetMessage: String?
    @State private var remoteConfigRefreshToken = 0
    @State private var reattachApprovalToken = 0
    @State private var playlistDiagnostics: String?
    @State private var showTombstoneRecoverySheet = false
    @State private var tombstoneRecoveryCutoff = Calendar.current.date(
        byAdding: .day,
        value: -7,
        to: Date()
    ) ?? Date()

    private var remoteConfig: StoreSplitRemoteConfig {
        _ = remoteConfigRefreshToken
        return StoreSplitRemoteConfigStore.current
    }

    private var selectedConfiguration: StoreDevelopmentConfiguration {
        StoreDevelopmentConfiguration(
            mode: storeMode,
            legacyCloudSyncEnabled: legacyCloudSyncEnabled,
            userStateCloudSyncEnabled: userStateCloudSyncEnabled,
            splitStoreWorkEnabled: splitStoreWorkEnabled
        )
    }

    private var requiresRelaunch: Bool {
        selectedConfiguration != launchConfiguration
    }

    var body: some View {
        Form {
            Section {
                Picker("Data architecture", selection: $storeMode) {
                    ForEach(DevelopmentStoreMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                Text("Store Selection")
            } footer: {
                Text(storeModeDescription)
            }

            Section {
                Toggle("Enable migration and reconciliation", isOn: $splitStoreWorkEnabled)
                    .disabled(storeMode == .legacyOnly)
                Toggle("CloudKit for legacy library store", isOn: $legacyCloudSyncEnabled)
                if StoreDevelopmentConfiguration.legacyCloudReattachBlocked {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Re-attach blocked")
                            .font(.footnote.bold())
                        Text("This store ran with CloudKit off. Turning mirroring back on re-imports the zone and duplicates every row written meanwhile. Deduplicate first, then allow it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Allow Legacy CloudKit Re-attach", role: .destructive) {
                            StoreDevelopmentConfiguration.approveLegacyCloudReattach()
                            reattachApprovalToken += 1
                        }
                    }
                }
                Toggle("CloudKit for user-state store", isOn: $userStateCloudSyncEnabled)
                    .disabled(
                        storeMode != .splitStores && storeMode != .splitStoreReads
                    )
            } header: {
                Text("Cloud Synchronization")
            } footer: {
                Text("This build ships the \(StoreSplitReleasePhase.current == .dualSyncBackfill ? "dual-sync backfill" : "user-state authority") phase. In the backfill phase the legacy library store keeps its CloudKit mirror and stays the source of truth, while UserState.sqlite is populated one-way in the background and never read. PodcastCache.sqlite is always local-only.")
            }

            Section("Active Since Launch") {
                LabeledContent("Data architecture", value: launchConfiguration.mode.title)
                LabeledContent(
                    "Legacy CloudKit",
                    value: StoreDevelopmentConfiguration.legacyCloudSyncEnabled
                        ? "Enabled"
                        : "Disabled"
                )
                LabeledContent(
                    "User-state CloudKit",
                    value: StoreDevelopmentConfiguration.userStateCloudSyncEnabled
                        ? "Enabled"
                        : "Disabled"
                )
                LabeledContent(
                    "Migration and reconciliation",
                    value: StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused
                        ? "Paused"
                        : "Enabled"
                )
            }

            if launchConfiguration.mode != .legacyOnly {
                Section("Split-Store Work") {
                    LabeledContent(
                        "Current job",
                        value: modelContainerManager.currentSplitStoreJobDescription ?? "Idle"
                    )
                    LabeledContent(
                        "Pending work",
                        value: modelContainerManager.pendingSplitStoreWorkReason ?? "None"
                    )
                    LabeledContent(
                        "Last reconcile",
                        value: modelContainerManager.lastSplitStoreReconcileSummary ?? "None"
                    )
                    LabeledContent(
                        "Reconciled at",
                        value: modelContainerManager.lastSplitStoreReconcileAt?
                            .formatted(date: .abbreviated, time: .shortened) ?? "Never"
                    )
                }
            }

            if launchConfiguration.mode != .legacyOnly {
                Section {
                    Button("Run One Migration Slice") {
                        runOneMigrationSlice()
                    }
                    .disabled(
                        isRunningSyncAction
                            || isResetting
                            || splitStoreWorkEnabled == false
                            || modelContainerManager.isMigratingSplitStores
                    )

                    Toggle("Pause migration", isOn: $migrationPaused)

                    LabeledContent(
                        "Current phase",
                        value: modelContainerManager.migrationCurrentPhase ?? "Idle"
                    )
                    LabeledContent(
                        "Cursor",
                        value: modelContainerManager.migrationCursorSummary ?? "—"
                    )
                    LabeledContent(
                        "Progress",
                        value: modelContainerManager.migrationProgressSummary ?? "—"
                    )
                    LabeledContent(
                        "Memory footprint",
                        value: modelContainerManager.migrationFootprintSummary ?? "—"
                    )
                    LabeledContent(
                        "Last slice error",
                        value: modelContainerManager.migrationLastSliceError ?? "None"
                    )
                } header: {
                    Text("Slice Migration")
                } footer: {
                    Text("Migration runs automatically: at launch, on returning to the foreground, and overnight while charging. Each run is budgeted (25s foreground, 120s in the background task) with idle time between slices, and stops on playback or backgrounding, so it can never saturate the CPU. SharedDatabase.sqlite is only ever read by the migrator.")
                }

                Section {
                    NavigationLink {
                        StoreSplitMigrationLogView()
                    } label: {
                        LabeledContent(
                            "Migration Log",
                            value: modelContainerManager.migrationCurrentPhase ?? "Idle"
                        )
                    }
                } footer: {
                    Text("When each run started and ended, which phases finished, and why a run stopped. Each finished phase also posts a local notification. DEBUG builds only.")
                }

                Section {
                    LabeledContent(
                        "Rollout state",
                        value: modelContainerManager.storeSplitRolloutStateDescription
                    )
                    Button("Resolve Rollout Now") {
                        resolveRollout()
                    }
                    .disabled(isRunningSyncAction || isResetting)
                    Button("Reset Rollout State") {
                        modelContainerManager.resetStoreSplitRolloutForDevelopment()
                    }
                    .disabled(isRunningSyncAction || isResetting)
                } header: {
                    Text("Rollout")
                } footer: {
                    Text("Resolved automatically at launch in every configuration: existing users publish their state in bounded slices, then switch to new-store reads; brand-new users go straight to new-store reads. The store-mode picker above still decides read authority in DEBUG — these buttons only let you re-run the resolution by hand.")
                }

                Section {
                    LabeledContent("Migration enabled", value: remoteConfig.migrationEnabled ? "yes" : "NO (paused)")
                    LabeledContent("Force legacy reads", value: remoteConfig.forceLegacyReads ? "YES" : "no")
                    LabeledContent("Min supported build", value: "\(remoteConfig.minSupportedBuild)")
                    LabeledContent(
                        "Last fetched",
                        value: StoreSplitRemoteConfigStore.lastFetchedAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "never"
                    )
                    Button("Refresh Remote Config Now") {
                        refreshRemoteConfig()
                    }
                    .disabled(isRunningSyncAction || isResetting)
                    Button("Clear Cached Remote Config", role: .destructive) {
                        StoreSplitRemoteConfigStore.resetCacheForDevelopment()
                        remoteConfigRefreshToken += 1
                    }
                    .disabled(isRunningSyncAction || isResetting)
                } header: {
                    Text("Remote Kill Switch")
                } footer: {
                    Text("Published from CloudKit Dashboard as the public-database record \"\(StoreSplitRemoteConfigStore.recordName)\" (type \(StoreSplitRemoteConfigStore.recordType)). migrationEnabled=0 pauses all split-store work live; forceLegacyReads=1 reverts reads to legacy on next launch. To lift a kill, set the fields back to permissive — do not delete the record.")
                }
            }

            if requiresRelaunch {
                Section {
                    Label(
                        "Quit and relaunch Up Next to apply these database settings.",
                        systemImage: "arrow.clockwise.circle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section {
                Button("Run Legacy Migration Now") {
                    runMigrationNow()
                }
                .disabled(
                    isRunningSyncAction
                        || isResetting
                        || splitStoreWorkEnabled == false
                        || (storeMode != .splitStores && storeMode != .splitStoreReads)
                )

                Button("Import Available Cloud State Now") {
                    importAvailableCloudState()
                }
                .disabled(
                    isRunningSyncAction
                        || isResetting
                        || splitStoreWorkEnabled == false
                        || storeMode != .splitStoreReads
                )

                Button("Recover Cache-Only Library Data") {
                    recoverCacheOnlyLibraryData()
                }
                .disabled(splitStoreActionDisabled)

                Button("Simulate Overnight Background Pass") {
                    simulateBackgroundPass()
                }
                .disabled(splitStoreActionDisabled)

                Button("Recover Listening History from Split Stores") {
                    recoverListeningHistory()
                }
                .disabled(splitStoreActionDisabled)

                Button("Preview Deduplication (no changes)") {
                    deduplicate(dryRun: true)
                }
                .disabled(isRunningSyncAction || isResetting)

                Button("Run Deduplication", role: .destructive) {
                    deduplicate(dryRun: false)
                }
                .disabled(isRunningSyncAction || isResetting)

                Button("Export Databases for Backup") {
                    exportDatabases()
                }
                .disabled(isRunningSyncAction || isResetting)

                // Read-only, so it stays available in the store modes that
                // disable the write actions — those are exactly the modes worth
                // diagnosing.
                Button("Show Playlist Diagnostics") {
                    showPlaylistTombstones()
                }
                .disabled(isRunningSyncAction || isResetting)

                if let playlistDiagnostics {
                    Text(playlistDiagnostics)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }

                Button("Restore Playlist Entries Deleted Since…") {
                    showTombstoneRecoverySheet = true
                }
                .disabled(splitStoreActionDisabled)

                Button("Republish Playlists") {
                    republishLegacyState(.playlists)
                }
                .disabled(splitStoreActionDisabled)

                Button("Republish Bookmarks") {
                    republishLegacyState(.bookmarks)
                }
                .disabled(splitStoreActionDisabled)

                Button("Republish Playback State") {
                    republishLegacyState(.episodeStates)
                }
                .disabled(splitStoreActionDisabled)

                Button("Republish Subscriptions") {
                    republishLegacyState(.subscriptions)
                }
                .disabled(splitStoreActionDisabled)

                Button("Republish Listening History (Heavy)") {
                    republishLegacyState(.listeningHistory)
                }
                .disabled(splitStoreActionDisabled)

                Button("Rebuild Analytics from Raw Sessions") {
                    rebuildAnalyticsFromRawSessions()
                }
                .disabled(isRunningSyncAction || isResetting)

                Button("Rebuild Listening Summaries") {
                    rebuildListeningSummaries()
                }
                .disabled(splitStoreActionDisabled)

                Button("Show Local User-State Counts") {
                    loadSplitStoreCounts()
                }
                .disabled(splitStoreActionDisabled)

                Button("Reset Local Split Stores on Next Launch") {
                    showLocalResetConfirmation = true
                }
                .disabled(isResetting || modelContainerManager.developmentResetRequiresRelaunch)

#if os(macOS) || targetEnvironment(macCatalyst)
                Button("Reset All Local Stores on Next Launch", role: .destructive) {
                    showAllLocalStoresResetConfirmation = true
                }
                .disabled(isResetting || modelContainerManager.developmentResetRequiresRelaunch)
#endif

                Button("Delete Split-Store Data from CloudKit", role: .destructive) {
                    showResetConfirmation = true
                }
                .disabled(
                    splitStoreActionDisabled
                        || modelContainerManager.developmentResetRequiresRelaunch
                )

                if isResetting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Deleting migrated data…")
                    }
                } else if isRunningSyncAction {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Updating split-store data…")
                    }
                } else if let resetMessage {
                    Text(resetMessage)
                        .font(.caption)
                        .foregroundStyle(
                            modelContainerManager.developmentResetRequiresRelaunch
                                ? .orange
                                : .secondary
                        )
                }
            } header: {
                Text("Migration Testing")
            } footer: {
                Text("Migration runs automatically; these buttons only force it to run now. Use the local reset to simulate a fresh device: the SQLite files are removed before SwiftData opens them, so CloudKit can download records again without receiving deletions. The CloudKit delete action is global and erases migrated records on every device.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Development")
        .platformInlineNavigationTitle()
        .onChange(of: storeMode) { _, mode in
            if mode == .legacyOnly || mode == .newStoresOnly {
                userStateCloudSyncEnabled = false
            }
            if mode == .legacyOnly {
                splitStoreWorkEnabled = false
            }
        }
        .confirmationDialog(
            "Reset only this device's split stores?",
            isPresented: $showLocalResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset on Next Launch", role: .destructive) {
                modelContainerManager.scheduleLocalSplitStoreReset()
                resetMessage = "Local reset scheduled. Quit Up Next completely and relaunch it to download the user-state store from CloudKit."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SharedDatabase.sqlite and CloudKit records are preserved. UserState.sqlite and PodcastCache.sqlite will be removed locally before SwiftData opens them on the next launch.")
        }
#if os(macOS) || targetEnvironment(macCatalyst)
        .confirmationDialog(
            "Reset every local database on this Mac?",
            isPresented: $showAllLocalStoresResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset All on Next Launch", role: .destructive) {
                modelContainerManager.scheduleAllLocalStoreReset()
                resetMessage = "Full local reset scheduled. Quit Up Next completely and relaunch it. CloudKit records can then download into empty stores."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SharedDatabase.sqlite, UserState.sqlite, and PodcastCache.sqlite will be removed from this Mac before SwiftData opens them. CloudKit records, downloaded audio, and settings are not deleted.")
        }
#endif
        .sheet(isPresented: $showTombstoneRecoverySheet) {
            NavigationStack {
                Form {
                    DatePicker(
                        "Deleted on or after",
                        selection: $tombstoneRecoveryCutoff,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Section {
                        Button("Restore Entries") {
                            showTombstoneRecoverySheet = false
                            restorePlaylistTombstones(since: tombstoneRecoveryCutoff)
                        }
                    } footer: {
                        Text("Clears the deleted flag on playlist and queue records removed on or after this moment, then re-imports so the local playlists are rebuilt from them. Removals you made yourself before this moment stay removed — check \"Show Playlist Tombstones\" first to pick the right cutoff.")
                    }
                }
                .navigationTitle("Restore Playlist Entries")
                .platformInlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showTombstoneRecoverySheet = false }
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete split-store data from CloudKit?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete from All Devices", role: .destructive) {
                resetMigratedData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the user-state records through SwiftData. With CloudKit enabled, those deletions propagate to every device. The legacy database remains available for rebuilding afterward.")
        }
    }

    private var storeModeDescription: String {
        switch storeMode {
        case .legacyOnly:
            "Only the local library store is opened. Split-store migration, imports, and dual writes are disabled."
        case .splitStores:
            StoreSplitReleasePhase.current == .dualSyncBackfill
                ? "Shipping backfill mode. The legacy library store is the source of truth and keeps syncing through CloudKit exactly as before. UserState.sqlite is filled one-way in the background and is never read."
                : "The app reads the durable local library store and dual-writes user state into UserState.sqlite. Migration publishes the remaining local state; UserState is not yet the read authority."
        case .splitStoreReads:
            "Recommended cross-device test mode. The durable local library store serves the UI, and UserState.sqlite is the authority for subscriptions, playback state, playlists, and bookmarks. CloudKit follows the two toggles above."
        case .newStoresOnly:
            "Experimental. The library graph is rebuilt in memory from PodcastCache at every launch and nothing on disk backs it. Expect a slow, initially empty launch; reset the cache before switching in."
        }
    }

    private var splitStoreActionDisabled: Bool {
        isRunningSyncAction
            || isResetting
            || splitStoreWorkEnabled == false
            || storeMode == .legacyOnly
    }

    private func resetMigratedData() {
        isResetting = true
        resetMessage = nil
        Task {
            do {
                let result = try await modelContainerManager
                    .resetSplitStoreDevelopmentData()
                resetMessage = "Deleted \(result.userStateRecordsDeleted) user-state and \(result.cacheRecordsDeleted) cache records. Quit and relaunch to migrate again."
            } catch {
                resetMessage = error.localizedDescription
            }
            isResetting = false
        }
    }

    private func importAvailableCloudState() {
        isRunningSyncAction = true
        resetMessage = nil
        Task {
            do {
                try await modelContainerManager.importAvailableSplitStoreStateNow()
                resetMessage = "Imported the user-state records currently available on this device."
            } catch {
                resetMessage = error.localizedDescription
            }
            isRunningSyncAction = false
        }
    }

    /// Copies podcasts and episodes that exist only in PodcastCache back into the
    /// durable library store. Needed on a device that spent time in the
    /// experimental cache-projection mode; restricted to actively subscribed
    /// feeds so it cannot resurrect a deleted podcast.
    private func recoverCacheOnlyLibraryData() {
        isRunningSyncAction = true
        resetMessage = nil
        Task {
            let result = await modelContainerManager
                .recoverCacheOnlyLibraryDataForDevelopment()
            resetMessage = result.failed > 0
                ? "Recovered \(result.podcasts) podcasts and \(result.episodes) episodes with \(result.failed) failures."
                : "Recovered \(result.podcasts) podcasts and \(result.episodes) episodes from the cache."
            isRunningSyncAction = false
        }
    }

    /// Runs exactly what the `BGProcessingTask` runs, including the
    /// background-processing window, so the overnight path can be verified
    /// without waiting on iOS to schedule the real task.
    private func simulateBackgroundPass() {
        isRunningSyncAction = true
        resetMessage = nil
        Task {
            StoreSplitMigrationDebugLog.record("background pass simulated from settings")
            await modelContainerManager.runStoreSplitMigrationBackgroundPass()
            resetMessage = "Background pass finished. Check the migration log."
            isRunningSyncAction = false
        }
    }

    /// Projects `ListeningHistorySync` back into legacy play sessions. Needed on
    /// a device that recorded sessions while the runtime graph lived in memory —
    /// those never reached SharedDatabase.sqlite. Deduplicates against existing
    /// sessions, so running it twice does not inflate the statistics.
    private func recoverListeningHistory() {
        isRunningSyncAction = true
        resetMessage = nil
        Task {
            do {
                let result = try await modelContainerManager
                    .recoverListeningHistoryForDevelopment()
                resetMessage = "Recovered \(result.listeningHistoryApplied) sessions and \(result.listeningSummariesApplied) summaries."
                    + (result.failed > 0 ? " \(result.failed) failures." : "")
            } catch {
                resetMessage = error.localizedDescription
            }
            isRunningSyncAction = false
        }
    }

    private func runMigrationNow() {
        isRunningSyncAction = true
        resetMessage = nil
        Task {
            await modelContainerManager.runStoreSplitMigrationNowForDevelopment()
            if let error = modelContainerManager.migrationError {
                resetMessage = error
            } else {
                resetMessage = modelContainerManager.isMigratingSplitStores
                    || modelContainerManager.pendingSplitStoreWorkReason == "migration"
                    ? "Legacy migration is queued and will run when playback is idle."
                    : "Legacy migration completed."
            }
            isRunningSyncAction = false
        }
    }

    private func resolveRollout() {
        isRunningSyncAction = true
        resetMessage = nil
        Task {
            await modelContainerManager.resolveStoreSplitRolloutForDevelopment()
            resetMessage = "Rollout state: \(modelContainerManager.storeSplitRolloutStateDescription)."
            isRunningSyncAction = false
        }
    }

    private func refreshRemoteConfig() {
        isRunningSyncAction = true
        resetMessage = nil
        Task {
            let result = await StoreSplitRemoteConfigStore.refresh()
            remoteConfigRefreshToken += 1
            resetMessage = result == nil
                ? "Remote config fetch failed (cache unchanged)."
                : "Remote config refreshed."
            isRunningSyncAction = false
        }
    }

    private func runOneMigrationSlice() {
        isRunningSyncAction = true
        resetMessage = nil
        Task {
            await modelContainerManager.runOneMigrationSliceForDevelopment()
            if let error = modelContainerManager.migrationLastSliceError {
                resetMessage = error
            } else if let progress = modelContainerManager.migrationProgressSummary {
                resetMessage = "Slice complete. \(progress)."
            } else {
                resetMessage = "Slice complete."
            }
            isRunningSyncAction = false
        }
    }

    private func republishLegacyState(
        _ scope: StoreSplitDevelopmentRepublishScope
    ) {
        isRunningSyncAction = true
        resetMessage = nil
        Task {
            do {
                let result = try await modelContainerManager
                    .republishLegacyStateToCloudKit(scope: scope)
                resetMessage = "\(scope.title) complete. Source: \(result.sourceSummary). New store: \(result.storedCounts.summary)."
            } catch {
                resetMessage = error.localizedDescription
            }
            isRunningSyncAction = false
        }
    }

    private func deduplicate(dryRun: Bool) {
        isRunningSyncAction = true
        playlistDiagnostics = nil
        Task {
            do {
                let report = try await modelContainerManager
                    .deduplicateLibrary(dryRun: dryRun)
                playlistDiagnostics = report.summary
            } catch {
                playlistDiagnostics = error.localizedDescription
            }
            isRunningSyncAction = false
        }
    }

    private func exportDatabases() {
        isRunningSyncAction = true
        playlistDiagnostics = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DatabaseBackupExporter.exportStores()
            }.value
            playlistDiagnostics = result.summary
            isRunningSyncAction = false
        }
    }

    private func showPlaylistTombstones() {
        isRunningSyncAction = true
        playlistDiagnostics = nil
        Task {
            do {
                let lines = try await modelContainerManager.playlistTombstoneReport()
                playlistDiagnostics = lines.joined(separator: "\n")
            } catch {
                playlistDiagnostics = "Failed: \(error.localizedDescription)"
            }
            isRunningSyncAction = false
        }
    }

    private func restorePlaylistTombstones(since cutoff: Date) {
        isRunningSyncAction = true
        resetMessage = nil
        Task {
            do {
                let result = try await modelContainerManager
                    .restorePlaylistTombstones(deletedOnOrAfter: cutoff)
                resetMessage = result.summary
            } catch {
                resetMessage = error.localizedDescription
            }
            isRunningSyncAction = false
        }
    }

    private func rebuildAnalyticsFromRawSessions() {
        isRunningSyncAction = true
        playlistDiagnostics = nil
        Task {
            do {
                try await modelContainerManager.rebuildAnalyticsFromRawSessions()
                playlistDiagnostics =
                    "Hourly stats and summaries recomputed from raw play sessions."
            } catch {
                playlistDiagnostics = error.localizedDescription
            }
            isRunningSyncAction = false
        }
    }

    private func rebuildListeningSummaries() {
        isRunningSyncAction = true
        resetMessage = nil
        Task {
            do {
                let result = try await modelContainerManager
                    .rebuildListeningSummariesForDevelopment()
                resetMessage = "Listening summaries rebuilt (incl. forever rollups). Scanned \(result.scanned), inserted \(result.inserted), updated \(result.updated), skipped \(result.skipped)."
            } catch {
                resetMessage = error.localizedDescription
            }
            isRunningSyncAction = false
        }
    }

    private func loadSplitStoreCounts() {
        isRunningSyncAction = true
        resetMessage = nil
        Task {
            do {
                let counts = try await modelContainerManager
                    .splitStoreDevelopmentCounts()
                resetMessage = "Local user-state store: \(counts.summary)."
            } catch {
                resetMessage = error.localizedDescription
            }
            isRunningSyncAction = false
        }
    }

}

private extension StoreSplitDevelopmentRepublishScope {
    var title: String {
        switch self {
        case .subscriptions:
            "Subscriptions"
        case .episodeStates:
            "Playback state"
        case .playlists:
            "Playlists"
        case .bookmarks:
            "Bookmarks"
        case .listeningHistory:
            "Listening history"
        }
    }
}

private extension StoreSplitDevelopmentRepublishResult {
    var sourceSummary: String {
        "subscriptions \(subscriptions), states \(episodeStates), playlists \(playlists), bookmarks \(bookmarks), history \(listeningSessions)"
    }
}
#endif
