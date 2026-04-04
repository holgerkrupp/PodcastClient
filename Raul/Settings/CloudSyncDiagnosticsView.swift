import SwiftUI
import SwiftData
import CloudKit
import CloudKitSyncMonitor

struct CloudSyncDiagnosticsView: View {
    private enum Constants {
        static let containerID = "iCloud.de.holgerkrupp.PodcastClient"
    }

    @Environment(\.modelContext) private var context

    @State private var accountStatusText = "Unknown"
    @State private var accountAvailable = false
    @State private var accountError: String?

    @State private var kvsLibraryMarker = false
    @State private var sharedStorePath = "Unavailable"
    @State private var sharedStoreExists = false
    @State private var localSnapshot = CloudSyncExpectedSnapshot(
        deviceName: "Local",
        updatedAt: .distantPast,
        podcasts: 0,
        episodes: 0,
        upNextEntries: 0,
        inboxEpisodes: 0,
        chapters: 0,
        bookmarks: 0,
        transcriptLines: 0,
        transcriptionRecords: 0,
        playSessions: 0,
        playSessionSummaries: 0
    )
    @State private var expectedSnapshot: CloudSyncExpectedSnapshot?

    @State private var lastRefresh: Date?
    @ObservedObject private var syncMonitor = SyncMonitor.default

    var body: some View {
        List {
            Section("CloudKit Account") {
                compactRow(
                    symbol: "person.crop.circle.badge.checkmark",
                    title: "Account",
                    value: accountStatusText,
                    tint: accountAvailable ? .green : .secondary
                )
                compactRow(
                    symbol: "externaldrive.badge.icloud",
                    title: "Container",
                    value: Constants.containerID
                )
                if let accountError {
                    compactRow(symbol: "exclamationmark.triangle", title: "Error", value: accountError, tint: .red)
                }
            }

            Section("Expected Snapshot") {
                if let expectedSnapshot {
                    compactRow(symbol: "iphone.gen3", title: "Source Device", value: expectedSnapshot.deviceName)
                    compactRow(
                        symbol: "clock",
                        title: "Updated",
                        value: expectedSnapshot.updatedAt.formatted(date: .numeric, time: .standard)
                    )
                } else {
                    compactRow(
                        symbol: "icloud.slash",
                        title: "Status",
                        value: "No expected snapshot in iCloud KVS yet.",
                        tint: .secondary
                    )
                }
            }

            Section("Data Sync Progress") {
                progressRow("Podcasts", local: localSnapshot.podcasts, expected: expectedSnapshot?.podcasts)
                progressRow("Episodes", local: localSnapshot.episodes, expected: expectedSnapshot?.episodes)
                progressRow("Up Next Entries", local: localSnapshot.upNextEntries, expected: expectedSnapshot?.upNextEntries)
                progressRow("Inbox Episodes", local: localSnapshot.inboxEpisodes, expected: expectedSnapshot?.inboxEpisodes)
                progressRow("Chapters", local: localSnapshot.chapters, expected: expectedSnapshot?.chapters)
                progressRow("Bookmarks", local: localSnapshot.bookmarks, expected: expectedSnapshot?.bookmarks)
                progressRow("Transcript Lines", local: localSnapshot.transcriptLines, expected: expectedSnapshot?.transcriptLines)
                progressRow("Transcription Records", local: localSnapshot.transcriptionRecords, expected: expectedSnapshot?.transcriptionRecords)
                progressRow("Play Sessions", local: localSnapshot.playSessions, expected: expectedSnapshot?.playSessions)
                progressRow("Play Session Summaries", local: localSnapshot.playSessionSummaries, expected: expectedSnapshot?.playSessionSummaries)
            }

            Section("Sync Signals") {
                compactRow(symbol: "checkmark.icloud", title: "KVS Marker", value: kvsLibraryMarker ? "true" : "false")
                compactRow(symbol: "internaldrive", title: "Shared Store Exists", value: sharedStoreExists ? "Yes" : "No")
                compactRow(symbol: "folder", title: "Shared Store Path", value: sharedStorePath)
            }

            Section("CloudKitSyncMonitor") {
                compactRow(
                    symbol: syncMonitor.syncStateSummary.symbolName,
                    title: "Summary",
                    value: summaryText,
                    tint: syncMonitor.syncStateSummary.symbolColor
                )

                monitorStateRow(symbol: "tray", title: "Setup", state: syncMonitor.setupState)
                monitorStateRow(symbol: "tray.and.arrow.down", title: "Import", state: syncMonitor.importState)
                monitorStateRow(symbol: "tray.and.arrow.up", title: "Export", state: syncMonitor.exportState)
            }

            Section("Actions") {
                Button("Refresh Diagnostics") {
                    Task { await refreshDiagnostics() }
                }

                Button("Publish Expected Snapshot to iCloud") {
                    CloudSyncExpectationStore.publishExpectedSnapshot(using: context)
                    expectedSnapshot = CloudSyncExpectationStore.loadExpectedSnapshot()
                    kvsLibraryMarker = CloudSyncExpectationStore.hasExpectedRemoteData()
                }
            }

            if let lastRefresh {
                Section("Last Refresh") {
                    Text(lastRefresh.formatted(date: .numeric, time: .standard))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Cloud Sync Diagnostics")
        .onAppear {
            syncMonitor.startMonitoring()
        }
        .task {
            await refreshDiagnostics()
        }
    }

    @ViewBuilder
    private func compactRow(symbol: String, title: String, value: String, tint: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func monitorStateRow(symbol: String, title: String, state: SyncMonitor.SyncState) -> some View {
        let details = describe(state)
        let inlineError = stateErrorText(for: title)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(syncMonitor.syncStateSummary.symbolColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(details.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if details.startedAtText != "-" {
                    Text("Started: \(details.startedAtText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if details.endedAtText != "-" {
                    Text("Ended: \(details.endedAtText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let inlineError {
                    Text("Error: \(inlineError)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private var summaryText: String {
        if syncMonitor.hasSyncError {
            return "\(syncMonitor.syncStateSummary.description) (Error)"
        }
        return syncMonitor.syncStateSummary.description
    }

    private func stateErrorText(for title: String) -> String? {
        switch title {
        case "Setup":
            return syncMonitor.setupError?.localizedDescription
        case "Import":
            return syncMonitor.importError?.localizedDescription
        case "Export":
            return syncMonitor.exportError?.localizedDescription
        default:
            return nil
        }
    }

    private func refreshDiagnostics() async {
        await refreshCloudKitStatus()
        localSnapshot = CloudSyncExpectationStore.makeSnapshot(using: context)
        refreshSyncSignals()
        lastRefresh = Date()
    }

    private func refreshCloudKitStatus() async {
        let container = CKContainer(identifier: Constants.containerID)
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                accountStatusText = "Available"
                accountAvailable = true
                accountError = nil
            case .noAccount:
                accountStatusText = "No iCloud Account"
                accountAvailable = false
                accountError = nil
            case .restricted:
                accountStatusText = "Restricted"
                accountAvailable = false
                accountError = nil
            case .couldNotDetermine:
                accountStatusText = "Could Not Determine"
                accountAvailable = false
                accountError = nil
            case .temporarilyUnavailable:
                accountStatusText = "Temporarily Unavailable"
                accountAvailable = false
                accountError = nil
            @unknown default:
                accountStatusText = "Unknown"
                accountAvailable = false
                accountError = nil
            }
        } catch {
            accountStatusText = "Error"
            accountAvailable = false
            accountError = error.localizedDescription
        }
    }

    private func refreshSyncSignals() {
        expectedSnapshot = CloudSyncExpectationStore.loadExpectedSnapshot()
        kvsLibraryMarker = CloudSyncExpectationStore.hasExpectedRemoteData()

        if let storeURL = ModelContainerManager.sharedStoreURL {
            sharedStorePath = storeURL.path
            sharedStoreExists = FileManager.default.fileExists(atPath: storeURL.path)
        } else {
            sharedStorePath = "Unavailable"
            sharedStoreExists = false
        }
    }

    private struct SyncStateDescription {
        let label: String
        let startedAtText: String
        let endedAtText: String
    }

    private func describe(_ state: SyncMonitor.SyncState) -> SyncStateDescription {
        switch state {
        case .notStarted:
            return SyncStateDescription(label: "Not Started", startedAtText: "-", endedAtText: "-")
        case .inProgress(let started):
            return SyncStateDescription(
                label: "In Progress",
                startedAtText: started.formatted(date: .numeric, time: .standard),
                endedAtText: "-"
            )
        case .succeeded(let started, let ended):
            return SyncStateDescription(
                label: "Succeeded",
                startedAtText: started.formatted(date: .numeric, time: .standard),
                endedAtText: ended.formatted(date: .numeric, time: .standard)
            )
        case .failed(let started, let ended, _):
            return SyncStateDescription(
                label: "Failed",
                startedAtText: started.formatted(date: .numeric, time: .standard),
                endedAtText: ended.formatted(date: .numeric, time: .standard)
            )
        }
    }

    @ViewBuilder
    private func progressRow(_ title: String, local: Int, expected: Int?) -> some View {
        let expectedValue = max(expected ?? 0, 0)
        let localValue = max(local, 0)
        let ratio: Double = expectedValue > 0 ? min(Double(localValue) / Double(expectedValue), 1.0) : 0
        let percentText = expectedValue > 0 ? "\(Int((ratio * 100).rounded()))%" : "n/a"

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(localValue) / \(expectedValue == 0 ? 0 : expectedValue) (\(percentText))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if expectedValue > 0 {
                ProgressView(value: ratio, total: 1.0)
                    .progressViewStyle(.linear)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        CloudSyncDiagnosticsView()
            .modelContainer(ModelContainerManager.shared.container)
    }
}
