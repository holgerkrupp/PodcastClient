#if DEBUG
import SwiftUI

struct DevelopmentSettingsView: View {
    @ObservedObject private var modelContainerManager = ModelContainerManager.shared
    @AppStorage(StoreDevelopmentConfiguration.modeKey)
    private var storeMode = DevelopmentStoreMode.splitStores
    @AppStorage(StoreDevelopmentConfiguration.legacyCloudSyncEnabledKey)
    private var legacyCloudSyncEnabled = true
    @AppStorage(StoreDevelopmentConfiguration.userStateCloudSyncEnabledKey)
    private var userStateCloudSyncEnabled = true

    @State private var launchConfiguration = StoreDevelopmentConfiguration.launch
    @State private var showLocalResetConfirmation = false
    @State private var showAllLocalStoresResetConfirmation = false
    @State private var showResetConfirmation = false
    @State private var isResetting = false
    @State private var isRunningSyncAction = false
    @State private var resetMessage: String?
    @State private var refreshHistory: [RefreshHistoryEntry] = []

    private var selectedConfiguration: StoreDevelopmentConfiguration {
        StoreDevelopmentConfiguration(
            mode: storeMode,
            legacyCloudSyncEnabled: legacyCloudSyncEnabled,
            userStateCloudSyncEnabled: userStateCloudSyncEnabled
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
                Toggle("CloudKit for legacy store", isOn: $legacyCloudSyncEnabled)
                    .disabled(storeMode != .splitStores)
                Toggle("CloudKit for user-state store", isOn: $userStateCloudSyncEnabled)
                    .disabled(storeMode != .splitStores)
            } header: {
                Text("Cloud Synchronization")
            } footer: {
                Text("The podcast cache store is always local-only. CloudKit for both legacy and user-state stores is only active in Split Stores mode. Split-read modes now force both stores local-only to keep test builds from being killed by background CloudKit import/export work.")
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
            }

            if StoreDevelopmentConfiguration.splitStoresEnabled {
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

            Section {
                if refreshHistory.isEmpty {
                    Text("No refresh history recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(refreshHistory) { entry in
                        DisclosureGroup {
                            ForEach(entry.checkedPodcasts) { check in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(check.title)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)

                                        Spacer()

                                        Text(check.result.title)
                                            .font(.caption)
                                            .foregroundStyle(resultColor(check.result))
                                    }

                                    Text(check.feedURL)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    if let message = check.result.message, message.isEmpty == false {
                                        Text(message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(entry.trigger.title)
                                        .font(.headline)

                                    Spacer()

                                    Text(entry.finishedAt, format: .dateTime.hour().minute().second())
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }

                                Text(entry.trigger.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(entry.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text("Duration \(entry.duration.formatted(.number.precision(.fractionLength(1))))s")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Refresh History")
                    Spacer()
                    if refreshHistory.isEmpty == false {
                        Button("Clear") {
                            clearRefreshHistory()
                        }
                        .font(.caption)
                    }
                }
            } footer: {
                Text("Recent development refresh runs stored locally on this device. This history is intentionally lightweight and limited to the latest entries.")
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
                Button("Import Available Cloud State Now") {
                    importAvailableCloudState()
                }
                .disabled(isRunningSyncAction || isResetting)

                Button("Republish Playlists") {
                    republishLegacyState(.playlists)
                }
                .disabled(isRunningSyncAction || isResetting)

                Button("Republish Bookmarks") {
                    republishLegacyState(.bookmarks)
                }
                .disabled(isRunningSyncAction || isResetting)

                Button("Republish Playback State") {
                    republishLegacyState(.episodeStates)
                }
                .disabled(isRunningSyncAction || isResetting)

                Button("Republish Subscriptions") {
                    republishLegacyState(.subscriptions)
                }
                .disabled(isRunningSyncAction || isResetting)

                Button("Republish Listening History (Heavy)") {
                    republishLegacyState(.listeningHistory)
                }
                .disabled(isRunningSyncAction || isResetting)

                Button("Show Local User-State Counts") {
                    loadSplitStoreCounts()
                }
                .disabled(isRunningSyncAction || isResetting)

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
                .disabled(isResetting || modelContainerManager.developmentResetRequiresRelaunch)

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
                Text("Use the local reset to simulate a fresh device: the SQLite files are removed before SwiftData opens them, so CloudKit can download the records again without receiving deletions. The CloudKit delete action is global and should only be used when you intend to erase migrated records on every device.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Development")
        .platformInlineNavigationTitle()
        .onChange(of: storeMode) { _, mode in
            if mode != .splitStores {
                legacyCloudSyncEnabled = false
                userStateCloudSyncEnabled = false
            }
        }
        .task {
            await loadRefreshHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshHistoryDidChange)) { _ in
            Task {
                await loadRefreshHistory()
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
            "Reads from the split stores and projects user state onto the local legacy UI store, but keeps CloudKit disabled so self-test builds stay local and memory-safe."
        case .newStoresOnly:
            "The new user-state store is authoritative for local testing, but CloudKit stays disabled. Legacy CloudKit and legacy-to-new migration are disabled. SharedDatabase.sqlite remains local-only as the temporary feed and UI projection until Podcast and Episode cache models move into PodcastCache.sqlite."
        }
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

    private func loadRefreshHistory() async {
        refreshHistory = await RefreshHistoryStore.shared.entries()
    }

    private func clearRefreshHistory() {
        Task {
            await RefreshHistoryStore.shared.clear()
            await loadRefreshHistory()
        }
    }

    private func resultColor(_ result: RefreshHistoryPodcastResult) -> Color {
        switch result.kind {
        case .feedNotUpdated:
            .secondary
        case .refreshed:
            .green
        case .refreshFailed, .timedOut:
            .red
        case .cancelled:
            .orange
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
