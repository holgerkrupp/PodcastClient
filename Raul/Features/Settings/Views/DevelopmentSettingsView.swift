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
                Toggle("CloudKit for user-state store", isOn: $userStateCloudSyncEnabled)
            } header: {
                Text("Cloud Synchronization")
            } footer: {
                Text("The podcast cache store is always local-only. CloudKit choices are applied when their ModelContainers are created at launch.")
            }

            Section("Active Since Launch") {
                LabeledContent("Data architecture", value: launchConfiguration.mode.title)
                LabeledContent(
                    "Legacy CloudKit",
                    value: launchConfiguration.legacyCloudSyncEnabled ? "Enabled" : "Disabled"
                )
                LabeledContent(
                    "User-state CloudKit",
                    value: launchConfiguration.userStateCloudSyncEnabled ? "Enabled" : "Disabled"
                )
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

                Button("Republish Legacy State to CloudKit") {
                    republishLegacyState()
                }
                .disabled(isRunningSyncAction || isResetting)

                Button("Reset Local Split Stores on Next Launch") {
                    showLocalResetConfirmation = true
                }
                .disabled(isResetting || modelContainerManager.developmentResetRequiresRelaunch)

#if os(macOS)
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
#if os(macOS)
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
            "Synced subscriptions, episode state, playlists, queue entries, bookmarks, and AI content are projected onto the local podcast cache. Feed data still uses the normal local parser."
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

    private func republishLegacyState() {
        isRunningSyncAction = true
        resetMessage = nil
        Task {
            do {
                let result = try await modelContainerManager
                    .republishLegacyStateToCloudKit()
                resetMessage = "Republished \(result.subscriptions) subscriptions, \(result.episodeStates) episode states, \(result.playlists) playlists, \(result.bookmarks) bookmarks, and \(result.listeningSessions) listening sessions."
            } catch {
                resetMessage = error.localizedDescription
            }
            isRunningSyncAction = false
        }
    }
}
#endif
