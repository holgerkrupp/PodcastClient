#if DEBUG
import Foundation
import SwiftUI
import UIKit

struct DevelopmentSettingsView: View {
    @ObservedObject private var modelContainerManager = ModelContainerManager.shared
    @ObservedObject private var cloudKitActivity = StoreCloudKitActivityMonitor.shared
    @State private var showLocalResetConfirmation = false
    @State private var showAllLocalStoresResetConfirmation = false
    @State private var showResetConfirmation = false
    @State private var isResetting = false
    @State private var isRunningSyncAction = false
    @State private var resetMessage: String?
    @State private var playlistDiagnostics: String?
    @State private var breadcrumbsCopied = false
    @State private var showTombstoneRecoverySheet = false
    @State private var storeSizes: [DevelopmentStoreSize] = []
    @State private var storeObjectCounts: [StoreSplitDevelopmentDatabaseCounts] = []
    @State private var isLoadingStoreObjectCounts = false
    @State private var cacheStatus: StoreSplitCacheDevelopmentStatus?
    @State private var migrationStatus: StoreSplitMigrationStatus?
    @State private var tombstoneRecoveryCutoff = Calendar.current.date(
        byAdding: .day,
        value: -7,
        to: Date()
    ) ?? Date()

    @ViewBuilder
    private var storeObjectsSection: some View {
            Section {
                if isLoadingStoreObjectCounts {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading object counts…")
                    }
                } else if storeObjectCounts.isEmpty {
                    Text("No object counts loaded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(storeObjectCounts) { store in
                        DisclosureGroup {
                            if store.isAvailable {
                                ForEach(store.objects) { object in
                                    LabeledContent(object.name) {
                                        Text(object.displayValue)
                                            .monospacedDigit()
                                    }
                                }
                            } else {
                                Text("Not open in the active launch configuration.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            HStack {
                                Text(store.storeName)
                                Spacer()
                            }
                        }
                    }
                }

                Button("Refresh Object Counts") {
                    refreshStoreObjectCounts()
                }
                .disabled(isLoadingStoreObjectCounts)
            } header: {
                Text("Database / Store Objects")
            } footer: {
                Text("The same metrics appear in the same order for every store. Counts are unique logical objects; live UserState counts exclude tombstoned/deleted rows. A dash means that store does not own that kind of data; it is not the same as zero. SQLite may still contain tombstones and duplicate historical rows for CloudKit deletion propagation.")
            }
    }

    var body: some View {
        Form {
            Section("Crash Diagnostics") {
                Button(breadcrumbsCopied ? "Breadcrumbs Copied" : "Copy Persisted Breadcrumbs") {
                    UIPasteboard.general.string = CrashBreadcrumbs.shared.recentSummary(limit: 80)
                    breadcrumbsCopied = true
                }

                Text("Includes recent operations and any operation without a matching completion event. Entries contain operation IDs, predicate labels, counts, and timing; no feed URLs or content.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Active Runtime") {
                LabeledContent(
                    "Data architecture",
                    value: modelContainerManager.runtimeProjectsFromCache
                        ? "UserState + PodcastCache"
                        : "UserState + local SharedDatabase"
                )
                LabeledContent(
                    "User-state CloudKit",
                    value: StoreDevelopmentConfiguration.userStateCloudSyncEnabled
                        ? "Enabled"
                        : "Disabled"
                )
                LabeledContent(
                    "Legacy library CloudKit",
                    value: "Off"
                )
            }

            Section("CloudKit Export Activity") {
                let userStateEventIDs = cloudKitActivity.activeExportIdentifiers(for: .userState)
                LabeledContent(
                    "UserState",
                    value: cloudKitActivity.activeExportStatus(for: .userState)
                )
                if userStateEventIDs.isEmpty == false {
                    Text("Events: " + userStateEventIDs.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(
                    "Scheduler blocker",
                    value: cloudKitActivity.isAnyStoreExporting
                        ? "CloudKit export in progress"
                        : "None"
                )
            }

            Section {
                ForEach(storeSizes) { store in
                    LabeledContent(store.name, value: store.displayValue)
                }

                if storeSizes.contains(where: \.isAvailable) {
                    LabeledContent("Total store footprint") {
                        Text(storeSizes.reduce(into: Int64(0)) { total, store in
                            total += store.bytes
                        }.formattedAsStorage)
                        .monospacedDigit()
                    }
                }

                Button("Refresh Store Sizes") {
                    refreshStoreSizes()
                }
            } header: {
                Text("Database / Store Sizes")
            } footer: {
                Text("Includes each SQLite file and its -wal, -shm, and -journal sidecars. Sizes use allocated disk space and show Not created when a store has not been opened yet.")
            }

            storeObjectsSection

            Section {
                if let cacheStatus {
                    LabeledContent(
                        "Cache schema",
                        value: "v\(cacheStatus.cacheSchemaVersion)"
                    )
                    LabeledContent(
                        "Feeds cached",
                        value: "\(cacheStatus.cachedFeedCount) / \(cacheStatus.sourceFeedCount)"
                    )
                    LabeledContent("Pending feeds", value: "\(cacheStatus.pendingFeedCount)")
                    LabeledContent(
                        "Failed / retryable feeds",
                        value: "\(cacheStatus.failedOrRetryableFeedCount)"
                    )
                    LabeledContent(
                        "Pending feeds recoverable from RSS",
                        value: "\(cacheStatus.rssRecoverablePendingFeedCount)"
                    )
                    LabeledContent(
                        "Feeds with unverified recovery",
                        value: "\(cacheStatus.unverifiedRecoverabilityFeedCount)"
                    )
                    LabeledContent("Cached episodes", value: "\(cacheStatus.cachedEpisodeCount)")
                    LabeledContent("Cached transcript records", value: "\(cacheStatus.cachedTranscriptCount)")
                    LabeledContent("Cached transcript lines", value: "\(cacheStatus.cachedTranscriptLineCount)")
                    LabeledContent("Cached AI chapters", value: "\(cacheStatus.cachedChapterCount)")
                    LabeledContent(
                        "Cache status",
                        value: cacheStatus.readinessStatusDescription
                    )
                    if let failureStage = cacheStatus.readinessFailureStage {
                        LabeledContent("Readiness failure stage", value: failureStage)
                    }
                    LabeledContent(
                        "Last successful progress",
                        value: cacheStatus.lastSuccessfulProgressAt?.formatted(
                            date: .abbreviated,
                            time: .shortened
                        ) ?? "Not recorded"
                    )
                    LabeledContent(
                        "Last feed refresh cache attempt",
                        value: cacheStatus.lastRefreshProjectionAt?.formatted(
                            date: .abbreviated,
                            time: .shortened
                        ) ?? "Not recorded"
                    )
                    LabeledContent(
                        "Last feed refresh cache result",
                        value: cacheStatus.lastRefreshProjectionStatus ?? "Not recorded"
                    )
                    if let projected = cacheStatus.lastRefreshProjectionEpisodes {
                        LabeledContent(
                            "Episodes processed by last refresh",
                            value: "\(projected)"
                        )
                    }
                } else {
                    Text("Cache status is not available until the split stores are opened.")
                        .foregroundStyle(.secondary)
                }

                Button("Refresh Cache Status") {
                    refreshStoreObjectCounts()
                }
                .disabled(isLoadingStoreObjectCounts)
            } header: {
                Text("Podcast Cache Filling")
            } footer: {
                Text("Every successful normal podcast refresh attempts to update PodcastCache. The cache result above distinguishes a completed write from playback, cancellation, deadline and database errors. Background processing repairs older or interrupted feeds; its timestamp does not change during an ordinary single-podcast refresh.")
            }

            Section {
                if let migrationStatus {
                    LabeledContent(
                        "Overall",
                        value: migrationOverallTitle(migrationStatus)
                    )
                    LabeledContent(
                        "Regular slices",
                        value: "\(migrationStatus.completedPhaseCount) of \(migrationStatus.totalPhaseCount) complete"
                    )
                    if migrationStatus.failedItemCount > 0 {
                        LabeledContent(
                            "Failed items",
                            value: "\(migrationStatus.failedItemCount)"
                        )
                        .foregroundStyle(.red)
                    }
                    if let blocker = migrationStatus.blocker {
                        LabeledContent("Blocker", value: blocker)
                            .foregroundStyle(.orange)
                    }

                    ForEach(migrationStatus.phases) { phase in
                        migrationPhaseRow(phase)
                    }

                    if migrationStatus.supplementalPhases.isEmpty == false {
                        Divider()
                        Text("AI content checkpoints")
                            .font(.subheadline.weight(.semibold))
                        ForEach(migrationStatus.supplementalPhases) { phase in
                            migrationPhaseRow(phase)
                        }
                    }
                } else {
                    Text("Migration status is not available until the split stores are opened.")
                        .foregroundStyle(.secondary)
                }

                Button("Refresh Migration Completeness") {
                    refreshStoreObjectCounts()
                }
                .disabled(isLoadingStoreObjectCounts)
            } header: {
                Text("Migration Completeness")
            } footer: {
                Text("Checkpoints show bounded backfill progress. Counts are informational: identities, CloudKit membership, retention, and aggregation can differ, so count equality is not proof of completeness. Completed rows say Backfilled while semantic verification is pending. Tombstones remain stored for CloudKit deletion propagation and are excluded from active counts.")
            }

            Section("Split-Store Work") {
                LabeledContent(
                    "Current job",
                    value: modelContainerManager.currentSplitStoreJobDescription ?? "No active job"
                )
                LabeledContent(
                    "Pending work",
                    value: modelContainerManager.pendingSplitStoreWorkReason ?? "No pending work"
                )
                LabeledContent(
                    "Last reconcile",
                    value: modelContainerManager.lastSplitStoreReconcileSummary ?? "No reconcile has run"
                )
                LabeledContent(
                    "Reconciled at",
                    value: modelContainerManager.lastSplitStoreReconcileAt?
                        .formatted(date: .abbreviated, time: .shortened) ?? "No reconcile has run"
                )
                LabeledContent(
                    "Readiness",
                    value: modelContainerManager.migrationReadiness.title
                )
                LabeledContent(
                    "Blocker",
                    value: modelContainerManager.migrationBlocker ?? "No blocker recorded"
                )
            }

            Section {
                NavigationLink {
                    StoreSplitMigrationLogView()
                } label: {
                    Label("Store Sync Log", systemImage: "list.bullet.rectangle")
                }
            } footer: {
                Text("When each background pass started and ended and why it stopped. DEBUG builds only.")
            }

            Section {
                NavigationLink {
                    StoreSplitAutomaticChecksView()
                } label: {
                    Label("Automatic Migration Checks", systemImage: "checkmark.seal")
                }
            } footer: {
                Text("Runs deterministic store-split scenarios in temporary in-memory stores. Results marked Partial identify conditions that need a real background-processing or multi-device CloudKit test.")
            }

            Section {
                Button("Import Available Cloud State Now") {
                    importAvailableCloudState()
                }
                .disabled(splitStoreActionDisabled)

                Button("Recover Cache-Only Library Data") {
                    recoverCacheOnlyLibraryData()
                }
                .disabled(splitStoreActionDisabled)

                Button("Simulate Background Pass") {
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

                Button("Rebuild Analytics from Raw Sessions") {
                    rebuildAnalyticsFromRawSessions()
                }
                .disabled(isRunningSyncAction || isResetting)

                Button("Capture Listening Baseline") {
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
                Text("Store Maintenance")
            } footer: {
                Text("Use the local reset to simulate a fresh device: the SQLite files are removed before SwiftData opens them, so CloudKit can download records again without receiving deletions. The CloudKit delete action is global and erases migrated records on every device.")
            }
        }
        .formStyle(.grouped)
        .tint(.blue)
        .navigationTitle("Development")
        .platformInlineNavigationTitle()
        .task {
            refreshStoreSizes()
            refreshMigrationStatus()
            refreshStoreObjectCounts()
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

    private var splitStoreActionDisabled: Bool {
        isRunningSyncAction || isResetting
    }

    private func refreshStoreSizes() {
        storeSizes = DevelopmentStoreSize.all()
    }

    private func refreshStoreObjectCounts() {
        guard isLoadingStoreObjectCounts == false else { return }
        isLoadingStoreObjectCounts = true
        Task {
            do {
                storeObjectCounts = try await modelContainerManager
                    .splitStoreDevelopmentObjectCounts()
                cacheStatus = try? await modelContainerManager
                    .splitStoreCacheDevelopmentStatus()
                migrationStatus = modelContainerManager.storeSplitMigrationStatus()
            } catch {
                resetMessage = "Could not read store object counts: \(error.localizedDescription)"
            }
            isLoadingStoreObjectCounts = false
        }
    }

    private func refreshMigrationStatus() {
        migrationStatus = modelContainerManager.storeSplitMigrationStatus()
    }

    private func migrationPhaseRow(
        _ phase: StoreSplitMigrationPhaseStatus
    ) -> some View {
        let metricName = migrationMetricName(for: phase.id)
        // These counters have different identity filters, retention rules and
        // CloudKit membership. They are useful diagnostics, never a completeness
        // predicate. A checkpoint means backfilled; semantic verification is a
        // separate gate and must not be implied by count equality.
        let phaseIsComplete = phase.isComplete && phase.failedCount == 0

        return HStack(spacing: 10) {
            Image(
                systemName: phaseIsComplete
                    ? "checkmark.circle"
                    : phase.failedCount > 0 ? "exclamationmark.circle.fill" : "circle"
            )
            .foregroundStyle(
                phase.failedCount > 0 ? .red : .secondary
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(phase.title)
                if let metricName {
                    Text(
                        "Legacy \(displayedObjectCount(store: "SharedDatabase.sqlite", metric: metricName)) → "
                            + "\(destinationStoreName(for: phase.id)) "
                            + (phase.id.hasPrefix("ai_")
                                ? displayedObjectCount(
                                    store: destinationStoreName(for: phase.id),
                                    metric: metricName
                                )
                                : String(phase.activeDestinationCount))
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("\(phase.activeDestinationCount) destination records")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if phase.failedCount > 0 {
                Text("\(phase.failedCount) failed")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if phaseIsComplete {
                Text("Backfilled · verification pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func migrationMetricName(for phaseID: String) -> String? {
        switch phaseID {
        case "subscriptions": "Subscribed podcasts"
        case "playlists": "Playlists"
        case "playlist_entries": "Playlist entries"
        case "bookmarks": "Bookmarks"
        case "episode_states": "Playback state"
        case "listening_summaries": "Listening statistics"
        case "listening_history": "Listening history"
        case "ai_transcripts": "AI transcripts"
        case "ai_chapters": "AI chapters"
        default: nil
        }
    }

    private func migrationOverallTitle(
        _ status: StoreSplitMigrationStatus
    ) -> String {
        guard status.isComplete else { return status.readiness.title }
        if status.supplementalPhases.contains(where: { $0.failedCount > 0 }) {
            return "AI content has failures"
        }
        if status.supplementalPhases.contains(where: { $0.isComplete == false }) {
            return "Regular slices complete; AI pending"
        }
        return "Complete"
    }

    private func destinationStoreName(for phaseID: String) -> String {
        phaseID.hasPrefix("ai_") ? "PodcastCache.sqlite" : "UserState.sqlite"
    }

    private func displayedObjectCount(store: String, metric: String) -> String {
        objectCount(store: store, metric: metric).map(String.init) ?? "—"
    }

    private func objectCount(store: String, metric: String) -> Int? {
        storeObjectCounts
            .first(where: { $0.storeName == store })?
            .objects
            .first(where: { $0.name == metric })?
            .count
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
            await modelContainerManager.runStoreSplitBackgroundPass()
            resetMessage = "Background pass finished. Check the store sync log."
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
                resetMessage = "Recovered \(result.listeningHistoryApplied) sessions."
                    + (result.failed > 0 ? " \(result.failed) failures." : "")
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

private struct DevelopmentStoreSize: Identifiable {
    let name: String
    let bytes: Int64
    let isAvailable: Bool

    var id: String { name }

    var displayValue: String {
        isAvailable ? bytes.formattedAsStorage : "Not created"
    }

    static func all() -> [DevelopmentStoreSize] {
        [
            make(name: "SharedDatabase.sqlite", url: ModelContainerManager.sharedStoreURL),
            make(name: "UserState.sqlite", url: ModelContainerManager.userStateStoreURL),
            make(name: "PodcastCache.sqlite", url: ModelContainerManager.cacheStoreURL)
        ]
    }

    private static func make(name: String, url: URL?) -> DevelopmentStoreSize {
        guard let url else {
            return DevelopmentStoreSize(name: name, bytes: 0, isAvailable: false)
        }

        let fileManager = FileManager.default
        let urls = [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm"),
            URL(fileURLWithPath: url.path + "-journal")
        ]
        var bytes: Int64 = 0
        var isAvailable = false

        for fileURL in urls where fileManager.fileExists(atPath: fileURL.path) {
            let values = try? fileURL.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey
            ])
            bytes += Int64(
                values?.totalFileAllocatedSize
                    ?? values?.fileAllocatedSize
                    ?? values?.fileSize
                    ?? 0
            )
            isAvailable = true
        }

        return DevelopmentStoreSize(name: name, bytes: bytes, isAvailable: isAvailable)
    }
}

private extension Int64 {
    var formattedAsStorage: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

private struct StoreSplitAutomaticChecksView: View {
    @State private var results: [StoreSplitAutomaticCheck] = []
    @State private var isRunning = false
    @State private var lastRunAt: Date?

    var body: some View {
        List {
            Section {
                Text("These checks use synthetic data and in-memory SwiftData stores. They do not read or change the active library and do not contact CloudKit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await runChecks() }
                } label: {
                    if isRunning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Running migration checks…")
                        }
                    } else {
                        Label("Run Checks Again", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRunning)

                if let lastRunAt {
                    LabeledContent(
                        "Last run",
                        value: lastRunAt.formatted(date: .abbreviated, time: .standard)
                    )
                }
            } footer: {
                Text("Partial means the local scenario passed but cannot prove a release condition such as BGProcessing expiration, CloudKit delivery order, or exporter throughput.")
            }

            Section("Results") {
                if results.isEmpty {
                    ContentUnavailableView(
                        "Checks have not run",
                        systemImage: "checkmark.seal",
                        description: Text("The checks start automatically when this screen opens.")
                    )
                } else {
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(result.title)
                                    .font(.headline)
                                Spacer(minLength: 8)
                                Text(result.status.rawValue.capitalized)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(statusColor(result.status))
                            }
                            Text("Issue #\(result.id)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(result.details)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Migration Checks")
        .platformInlineNavigationTitle()
        .task {
            if results.isEmpty { await runChecks() }
        }
    }

    private func runChecks() async {
        guard isRunning == false else { return }
        isRunning = true
        results = await Task.detached(priority: .utility) {
            await StoreSplitAutomaticChecks.runAll()
        }.value
        lastRunAt = .now
        isRunning = false
    }

    private func statusColor(_ status: StoreSplitAutomaticCheck.Status) -> Color {
        switch status {
        case .passed: .green
        case .partial: .orange
        case .failed: .red
        }
    }
}
#endif
