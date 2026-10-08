#if DEBUG
import Foundation
import SwiftUI

struct DevelopmentSettingsView: View {
    @ObservedObject private var modelContainerManager = ModelContainerManager.shared
    @ObservedObject private var cloudKitActivity = StoreCloudKitActivityMonitor.shared
    @AppStorage(StoreDevelopmentConfiguration.modeKey)
    private var storeMode = DevelopmentStoreMode.splitStores
    @AppStorage(StoreDevelopmentConfiguration.legacyCloudSyncEnabledKey)
    private var legacyCloudSyncEnabled = StoreDevelopmentConfiguration
        .releaseLegacyCloudSyncEnabled
    @AppStorage(StoreDevelopmentConfiguration.userStateCloudSyncEnabledKey)
    private var userStateCloudSyncEnabled = StoreDevelopmentConfiguration
        .releaseUserStateCloudSyncEnabled
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

    private var remoteConfig: StoreSplitRemoteConfig {
        _ = remoteConfigRefreshToken
        return StoreSplitRemoteConfigStore.current
    }

    private var publicConfiguration: StoreDevelopmentConfiguration {
        StoreDevelopmentConfiguration.publicBaseline
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

    private var readAuthorityPreviewBinding: Binding<Bool> {
        Binding(
            get: { storeMode == .splitStoreReads },
            set: { enabled in
                storeMode = enabled
                    ? .splitStoreReads
                    : publicConfiguration.mode
                if enabled {
                    userStateCloudSyncEnabled = true
                    splitStoreWorkEnabled = true
                }
            }
        )
    }

    private var publicDifferences: [String] {
        var differences: [String] = []
        if selectedConfiguration.mode != publicConfiguration.mode {
            differences.append(
                "Read authority: \(selectedConfiguration.mode.title) (public: \(publicConfiguration.mode.title))"
            )
        }
        if selectedConfiguration.legacyCloudSyncEnabled
            != publicConfiguration.legacyCloudSyncEnabled {
            differences.append(
                "Legacy CloudKit: \(selectedConfiguration.legacyCloudSyncEnabled ? "enabled" : "disabled") (public: \(publicConfiguration.legacyCloudSyncEnabled ? "enabled" : "disabled"))"
            )
        } else if StoreDevelopmentConfiguration.legacyCloudSyncEnabled
            != publicConfiguration.legacyCloudSyncEnabled {
            differences.append(
                "Active legacy CloudKit: disabled by the re-attach guard (public: enabled)"
            )
        }
        if selectedConfiguration.userStateCloudSyncEnabled
            != publicConfiguration.userStateCloudSyncEnabled {
            differences.append(
                "User-state CloudKit: \(selectedConfiguration.userStateCloudSyncEnabled ? "enabled" : "disabled") (public: \(publicConfiguration.userStateCloudSyncEnabled ? "enabled" : "disabled"))"
            )
        }
        if selectedConfiguration.splitStoreWorkEnabled
            != publicConfiguration.splitStoreWorkEnabled {
            differences.append(
                "Migration and reconciliation: \(selectedConfiguration.splitStoreWorkEnabled ? "enabled" : "disabled") (public: enabled)"
            )
        }
        if migrationPaused {
            differences.append("Manual migration pause: enabled (public: not paused)")
        }
        return differences
    }

    var body: some View {
        Form {
            Section {
                Picker("Data architecture", selection: $storeMode) {
                    ForEach(DevelopmentStoreMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                LabeledContent(
                    "Active since launch",
                    value: launchConfiguration.mode.title
                )
            } header: {
                Text("Store Selection")
            } footer: {
                Text("Selected: \(storeModeDescription) Changes apply after relaunch. The cache projection mode is experimental and rebuilds the library graph from PodcastCache.sqlite.")
            }

            Section {
                Toggle(
                    "Next step: UserState read authority",
                    isOn: readAuthorityPreviewBinding
                )
                .tint(.orange)

                Text("DEBUG-only preview. Turning this on changes the read authority to UserState.sqlite after relaunch; the public build still reads the legacy library store until the release phase changes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Match Public Backfill Configuration") {
                    applyPublicConfiguration()
                }
                .disabled(publicDifferences.isEmpty)
            } header: {
                Text("Next Step Preview")
            } footer: {
                Text("Use the preview only after the backfill is complete and verified. Changing read authority requires a relaunch.")
            }

            Section("Compared with Public") {
                if publicDifferences.isEmpty {
                    Label(
                        "Matches the public dual-sync backfill configuration",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                } else {
                    Label(
                        "DEBUG settings differ from the public configuration",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    ForEach(publicDifferences, id: \.self) { difference in
                        Text(difference)
                            .font(.footnote)
                    }
                }
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
                Text("Public builds currently ship the \(StoreSplitReleasePhase.current == .dualSyncBackfill ? "dual-sync backfill" : "user-state authority") phase. In the backfill phase the legacy library store keeps its CloudKit mirror and stays the source of truth, while UserState.sqlite is populated one-way in the background and never read. The DEBUG next-step preview can intentionally change that after relaunch. PodcastCache.sqlite is always local-only.")
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

            Section("CloudKit Export Activity") {
                let legacyEventIDs = cloudKitActivity.activeExportIdentifiers(for: .legacy)
                let userStateEventIDs = cloudKitActivity.activeExportIdentifiers(for: .userState)
                LabeledContent(
                    "Legacy SharedDatabase",
                    value: cloudKitActivity.activeExportStatus(for: .legacy)
                )
                if legacyEventIDs.isEmpty == false {
                    Text("Events: " + legacyEventIDs.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                LabeledContent(
                    "Legacy mirror",
                    value: StoreDevelopmentConfiguration.legacyCloudMirrorQuarantined
                        ? "Quarantined (local-only)"
                        : "Attached by launch policy"
                )
                if StoreDevelopmentConfiguration.legacyCloudMirrorQuarantined == false {
                    Button(
                        "Quarantine Legacy Mirror for Next Launch",
                        role: .destructive
                    ) {
                        StoreDevelopmentConfiguration.quarantineLegacyCloudMirror(
                            reason: "manual_debug_action"
                        )
                        resetMessage = "Legacy CloudKit mirroring will remain detached on the next launch. The SQLite library file is preserved."
                    }
                }
                Text("A quarantined legacy store is never re-attached automatically. UserState remains CloudKit-backed; clear the quarantine only through an explicit development reset after deduplication and verification.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

            Section {
                if let cacheStatus {
                    LabeledContent(
                        "Automatic filling",
                        value: cacheStatus.automaticFillingEnabled ? "Enabled" : "Not active in this mode"
                    )
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
                    LabeledContent("Cached episodes", value: "\(cacheStatus.cachedEpisodeCount)")
                    LabeledContent("Cached transcript records", value: "\(cacheStatus.cachedTranscriptCount)")
                    LabeledContent("Cached transcript lines", value: "\(cacheStatus.cachedTranscriptLineCount)")
                    LabeledContent("Cached AI chapters", value: "\(cacheStatus.cachedChapterCount)")
                    LabeledContent(
                        "Cache status",
                        value: cacheStatus.isComplete
                            && cacheStatus.failedOrRetryableFeedCount == 0
                            ? "Ready for cutover"
                            : "Filling"
                    )
                    LabeledContent(
                        "Last successful progress",
                        value: cacheStatus.lastSuccessfulProgressAt?.formatted(
                            date: .abbreviated,
                            time: .shortened
                        ) ?? "Not recorded"
                    )
                    LabeledContent(
                        "Last cache pass",
                        value: cacheStatus.lastBootstrapAt?.formatted(
                            date: .abbreviated,
                            time: .shortened
                        ) ?? "Not run"
                    )
                    if let copied = cacheStatus.lastBootstrapCopied {
                        LabeledContent("Feeds copied last pass", value: "\(copied)")
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
                Text("The cache is filled automatically only in the Cache Projection architecture. It prioritizes feeds needed by playlists, then processes up to 15 feeds after launch/foreground and up to 200 during the overnight background pass. Each feed is complete when it reaches the current cache schema version; transcripts and chapters are included in that feed pass.")
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
                Text("Use the checkmarks and unique live destination counts to verify subscriptions, listening history, listening statistics, and AI transcripts/chapters. Tombstones remain physically stored for CloudKit deletion propagation but are excluded from these counts. Listening history may intentionally exceed the legacy raw-session count because old raw sessions are retention-limited. AI content has separate checkpoints and is not included in the regular slice percentage.")
            }

            if launchConfiguration.mode != .legacyOnly {
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
                            || launchConfiguration.splitStoreWorkEnabled == false
                            || modelContainerManager.isMigratingSplitStores
                    )

                    Toggle("Pause migration", isOn: $migrationPaused)

                    LabeledContent(
                        "Readiness",
                        value: modelContainerManager.migrationReadiness.title
                    )
                    LabeledContent(
                        "Blocker",
                        value: modelContainerManager.migrationBlocker ?? "No blocker recorded"
                    )

                    LabeledContent(
                        "Current phase",
                        value: modelContainerManager.migrationCurrentPhase ?? "No slice has run"
                    )
                    LabeledContent(
                        "Cursor",
                        value: modelContainerManager.migrationCursorSummary ?? "No cursor"
                    )
                    LabeledContent(
                        "Progress",
                        value: modelContainerManager.migrationProgressSummary ?? "No checkpoint yet"
                    )
                    LabeledContent(
                        "Memory footprint",
                        value: modelContainerManager.migrationFootprintSummary ?? "No slice has run"
                    )
                    LabeledContent(
                        "Last slice",
                        value: modelContainerManager.migrationLastSliceResult
                    )
                    LabeledContent(
                        "Last slice error",
                        value: modelContainerManager.migrationLastSliceError ?? "No error"
                    )
                } header: {
                    Text("Slice Migration")
                } footer: {
                    Text("Migration runs automatically: at launch, on returning to the foreground, and overnight while charging. Each slice is limited to 2 seconds. Runs are capped at 15 seconds foreground or 20 seconds in the background task, with separate active-work and memory limits plus proportional idle time between slices. SharedDatabase.sqlite is only ever read by the migrator.")
                }

                Section {
                    NavigationLink {
                        StoreSplitMigrationLogView()
                    } label: {
                        LabeledContent(
                            "Migration Log",
                            value: modelContainerManager.migrationLastSliceResult
                        )
                    }
                } footer: {
                    Text("When each run started and ended, which phases finished, and why a run stopped. Each finished phase also posts a local notification. DEBUG builds only.")
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
                    Text("Resolved automatically at launch in every configuration: existing users publish their state in bounded slices, then switch to new-store reads; brand-new users go straight to new-store reads. The development installation keeps the local library store as its read authority.")
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
                        || launchConfiguration.splitStoreWorkEnabled == false
                        || (launchConfiguration.mode != .splitStores && launchConfiguration.mode != .splitStoreReads)
                )

                Button("Import Available Cloud State Now") {
                    importAvailableCloudState()
                }
                .disabled(
                    isRunningSyncAction
                        || isResetting
                        || launchConfiguration.splitStoreWorkEnabled == false
                        || launchConfiguration.mode != .splitStoreReads
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
                Text("Migration Testing")
            } footer: {
                Text("Migration runs automatically; these buttons only force it to run now. Use the local reset to simulate a fresh device: the SQLite files are removed before SwiftData opens them, so CloudKit can download records again without receiving deletions. The CloudKit delete action is global and erases migrated records on every device.")
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
            || launchConfiguration.splitStoreWorkEnabled == false
            || launchConfiguration.mode == .legacyOnly
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
        let sourceCount = metricName.flatMap {
            objectCount(store: "SharedDatabase.sqlite", metric: $0)
        }
        let countsMustMatch = [
            "subscriptions", "playlists", "playlist_entries", "bookmarks",
            "episode_states", "ai_transcripts", "ai_chapters"
        ].contains(phase.id)
        let hasCountMismatch = countsMustMatch
            && sourceCount != nil
            && sourceCount != phase.activeDestinationCount
        let phaseIsComplete = phase.isComplete && hasCountMismatch == false

        return HStack(spacing: 10) {
            Image(
                systemName: phaseIsComplete
                    ? "checkmark.circle.fill"
                    : hasCountMismatch ? "exclamationmark.circle.fill" : "circle"
            )
            .foregroundStyle(
                phaseIsComplete ? .green : hasCountMismatch ? .orange : .secondary
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
            } else if hasCountMismatch {
                Text("Count mismatch")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if phaseIsComplete {
                Text("Complete")
                    .font(.caption)
                    .foregroundStyle(.green)
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

    private func applyPublicConfiguration() {
        let configuration = publicConfiguration
        storeMode = configuration.mode
        legacyCloudSyncEnabled = configuration.legacyCloudSyncEnabled
        userStateCloudSyncEnabled = configuration.userStateCloudSyncEnabled
        splitStoreWorkEnabled = configuration.splitStoreWorkEnabled
        migrationPaused = false
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
                resetMessage = "Recovered \(result.listeningHistoryApplied) sessions."
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
            } else if let blocker = modelContainerManager.migrationBlocker {
                resetMessage = "Migration not completed: \(blocker)"
            } else {
                resetMessage = modelContainerManager.isMigratingSplitStores
                    || ModelContainerManager.hasPendingMigrationWork
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
            let result = await modelContainerManager.runOneMigrationSliceForDevelopment()
            switch result {
            case let .advanced(phase, processed):
                resetMessage = "Advanced \(phase ?? "migration") by \(processed) item(s)."
            case let .phaseCompleted(phase, processed):
                resetMessage = "Completed \(phase ?? "phase") (\(processed) item(s))."
            case .allComplete:
                resetMessage = "All migration phases are complete."
            case let .deferred(reason):
                resetMessage = "Migration deferred: \(reason)"
            case let .failed(reason):
                resetMessage = "Migration failed: \(reason)"
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
