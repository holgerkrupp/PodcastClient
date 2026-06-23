#if DEBUG
import SwiftUI

struct DevelopmentSettingsView: View {
    @ObservedObject private var modelContainerManager = ModelContainerManager.shared
    @AppStorage(StoreDevelopmentConfiguration.modeKey)
    private var storeMode = DevelopmentStoreMode.splitStores
    @AppStorage(StoreDevelopmentConfiguration.legacyCloudSyncEnabledKey)
    private var legacyCloudSyncEnabled = true
    @AppStorage(StoreDevelopmentConfiguration.userStateCloudSyncEnabledKey)
    private var userStateCloudSyncEnabled = false
    @AppStorage(StoreDevelopmentConfiguration.splitStoreWorkEnabledKey)
    private var splitStoreWorkEnabled = true
    @AppStorage(StoreDevelopmentConfiguration.migrationPausedKey)
    private var migrationPaused = false
    @AppStorage(StoreDevelopmentConfiguration.migrationAutoRunEnabledKey)
    private var migrationAutoRunEnabled = false

    @State private var launchConfiguration = StoreDevelopmentConfiguration.launch
    @State private var showLocalResetConfirmation = false
    @State private var showAllLocalStoresResetConfirmation = false
    @State private var showResetConfirmation = false
    @State private var isResetting = false
    @State private var isRunningSyncAction = false
    @State private var resetMessage: String?

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
                Toggle("CloudKit for legacy store", isOn: $legacyCloudSyncEnabled)
                    .disabled(
                        storeMode != .splitStores && storeMode != .splitStoreReads
                    )
                Toggle("CloudKit for user-state store", isOn: $userStateCloudSyncEnabled)
                    .disabled(
                        storeMode != .splitStores && storeMode != .splitStoreReads
                    )
            } header: {
                Text("Cloud Synchronization")
            } footer: {
                Text("The podcast cache store is always local-only. Use New-store reads with both CloudKit toggles enabled to test iPhone–Mac synchronization while continuing to dual-write the legacy and user-state stores. Disable migration and reconciliation if you need to inspect the stores without background projection work.")
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
                    Toggle("Auto-run migration (foreground)", isOn: $migrationAutoRunEnabled)

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
                    Text("Each slice migrates one bounded page with fresh model contexts and reports its memory footprint delta. Slices skip while audio plays or while CloudKit is still exporting. SharedDatabase.sqlite is only ever read by the migrator.")
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
                    Text("Release builds resolve this automatically at launch: existing users migrate under legacy reads, then switch to new-store reads; brand-new users go straight to new-store reads. In DEBUG the store-mode picker above stays authoritative — use these buttons to exercise the rollout manually.")
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
                Text("Automatic legacy migration is disabled for memory safety. Run it only when explicitly testing migration. Use the local reset to simulate a fresh device: the SQLite files are removed before SwiftData opens them, so CloudKit can download records again without receiving deletions. The CloudKit delete action is global and erases migrated records on every device.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Development")
        .platformInlineNavigationTitle()
        .onChange(of: storeMode) { _, mode in
            if mode == .legacyOnly || mode == .newStoresOnly {
                legacyCloudSyncEnabled = false
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
            "Only SharedDatabase.sqlite is opened. Split-store migration, imports, and dual writes are disabled."
        case .splitStores:
            "The app continues reading its podcast graph from the legacy store while preparing, migrating, and dual-writing the new user-state and cache stores."
        case .splitStoreReads:
            "Recommended cross-device test mode. The app dual-writes both stores, reads synchronized user state from UserState.sqlite, and projects it onto the legacy UI graph. CloudKit follows the two toggles above."
        case .newStoresOnly:
            "The new user-state store is authoritative for local testing, but CloudKit stays disabled. Legacy CloudKit and legacy-to-new migration are disabled. SharedDatabase.sqlite remains local-only as the temporary feed and UI projection until Podcast and Episode cache models move into PodcastCache.sqlite."
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
