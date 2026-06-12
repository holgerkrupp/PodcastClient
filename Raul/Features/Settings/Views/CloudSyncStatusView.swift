import SwiftUI
import SwiftData
import CloudKit
import CloudKitSyncMonitor

struct CloudSyncStatusView: View {
    let modelContainer: ModelContainer

    @StateObject private var syncMonitor = SyncMonitor.default
    @State private var localRecordCount = 0
    @State private var reference: CloudSyncProgressReference?
    @State private var isRefreshing = false

    private var estimatedProgress: Double? {
        guard let reference, reference.recordCount > 0 else { return nil }
        let progress = Double(localRecordCount) / Double(reference.recordCount)
        return min(progress, syncMonitor.syncStateSummary.isInProgress ? 0.95 : 1)
    }

    private var statusTitle: LocalizedStringKey {
        switch syncMonitor.syncStateSummary {
        case .noNetwork:
            return "Offline"
        case .accountNotAvailable:
            return "iCloud Unavailable"
        case .error:
            return "Sync Error"
        case .notSyncing:
            return "Not Syncing"
        case .notStarted:
            return "Waiting to Sync"
        case .inProgress:
            return "Syncing"
        case .succeeded:
            return "Synced"
        case .unknown:
            return "Status Unknown"
        }
    }

    private var statusColor: Color {
        switch syncMonitor.syncStateSummary {
        case .error, .notSyncing, .unknown:
            return .red
        case .noNetwork, .accountNotAvailable:
            return .orange
        case .succeeded:
            return .green
        default:
            return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: syncMonitor.syncStateSummary.symbolName)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .symbolEffect(
                        .rotate,
                        options: .repeating,
                        isActive: syncMonitor.syncStateSummary.isInProgress
                    )
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Database")
                        .font(.headline)
                    Text(statusTitle)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                }

                Spacer()

                Button {
                    Task {
                        await refresh()
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh iCloud sync status")
            }

            if let estimatedProgress, let reference {
                ProgressView(value: estimatedProgress)
                    .progressViewStyle(.linear)

                Text("\(localRecordCount.formatted()) local records of about \(reference.recordCount.formatted())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if syncMonitor.syncStateSummary.isInProgress {
                ProgressView()
                    .progressViewStyle(.linear)

                Text("\(localRecordCount.formatted()) local records")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("\(localRecordCount.formatted()) local records")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                phaseLabel("Setup", state: syncMonitor.setupState)
                phaseLabel("Download", state: syncMonitor.importState)
                phaseLabel("Upload", state: syncMonitor.exportState)
            }

            if let reference {
                Text("Reference updated \(reference.updatedAt, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("No record-count reference has been received from another device yet.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .task {
            while !Task.isCancelled {
                await refresh(showActivity: false)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func phaseLabel(
        _ title: LocalizedStringKey,
        state: SyncMonitor.SyncState
    ) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: state.phaseSymbolName)
                .foregroundStyle(state.phaseColor)
        }
        .font(.caption)
    }

    @MainActor
    private func refresh(showActivity: Bool = true) async {
        if showActivity {
            isRefreshing = true
        }

        reference = CloudSyncProgressReferenceStore.load()
        localRecordCount = await CloudSyncProgressReferenceStore.localRecordCount(
            modelContainer: modelContainer
        )

        if showActivity {
            isRefreshing = false
        }
    }
}

struct CloudSyncStatusDetailView: View {
    let modelContainer: ModelContainer

    @StateObject private var syncMonitor = SyncMonitor.default

    private var reportedErrors: [(title: String, error: Error)] {
        var errors: [(String, Error)] = []

        if let error = syncMonitor.setupError {
            errors.append(("Setup Error", error))
        }
        if let error = syncMonitor.importError {
            errors.append(("Download Error", error))
        }
        if let error = syncMonitor.exportError {
            errors.append(("Upload Error", error))
        }
        if errors.isEmpty, let error = syncMonitor.lastSyncError {
            errors.append(("Last Reported Error", error))
        }
        if let error = syncMonitor.iCloudAccountStatusError {
            errors.append(("Account Status Error", error))
        }

        return errors
    }

    var body: some View {
        List {
            Section("Current Status") {
                CloudSyncStatusView(modelContainer: modelContainer)
            }

            Section("Environment") {
                LabeledContent("Network") {
                    Label(
                        networkDescription,
                        systemImage: syncMonitor.isNetworkAvailable == false
                            ? "wifi.slash"
                            : "wifi"
                    )
                    .foregroundStyle(
                        syncMonitor.isNetworkAvailable == false
                            ? AnyShapeStyle(.orange)
                            : AnyShapeStyle(.secondary)
                    )
                }

                LabeledContent("iCloud Account") {
                    Label(
                        accountDescription,
                        systemImage: syncMonitor.iCloudAccountStatus == .available
                            ? "person.crop.circle.badge.checkmark"
                            : "person.crop.circle.badge.exclamationmark"
                    )
                    .foregroundStyle(
                        syncMonitor.iCloudAccountStatus == .available
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.orange)
                    )
                }

                LabeledContent("Should Be Syncing") {
                    Text(syncMonitor.shouldBeSyncing ? "Yes" : "No")
                        .foregroundStyle(
                            syncMonitor.shouldBeSyncing
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(.orange)
                        )
                }

                LabeledContent("Monitor State") {
                    Text(syncMonitor.isNotSyncing ? "Unexpectedly idle" : "Normal")
                        .foregroundStyle(
                            syncMonitor.isNotSyncing
                                ? AnyShapeStyle(.red)
                                : AnyShapeStyle(.secondary)
                        )
                }
            }

            Section("CloudKit Events") {
                SyncPhaseDetailRow(
                    title: "Setup",
                    systemImage: "tray",
                    state: syncMonitor.setupState
                )

                SyncPhaseDetailRow(
                    title: "Download",
                    systemImage: "tray.and.arrow.down",
                    state: syncMonitor.importState
                )

                SyncPhaseDetailRow(
                    title: "Upload",
                    systemImage: "tray.and.arrow.up",
                    state: syncMonitor.exportState
                )
            }

            if reportedErrors.isEmpty == false {
                Section("Errors") {
                    ForEach(Array(reportedErrors.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.title, systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.red)

                            Text(item.error.localizedDescription)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("About Sync Progress") {
                Text("The progress bar compares this device's local SwiftData record count with a lightweight reference shared through iCloud.")

                Text("CloudKit does not expose exact transfer progress, so the displayed percentage is an estimate. CloudKit's import status determines when synchronization is complete.")
            }
        }
        .navigationTitle("iCloud Sync")
        .platformInlineNavigationTitle()
    }

    private var networkDescription: String {
        switch syncMonitor.isNetworkAvailable {
        case true:
            return "Available"
        case false:
            return "Unavailable"
        case nil:
            return "Checking"
        }
    }

    private var accountDescription: String {
        guard let status = syncMonitor.iCloudAccountStatus else {
            return "Checking"
        }

        switch status {
        case .available:
            return "Available"
        case .noAccount:
            return "No Account"
        case .restricted:
            return "Restricted"
        case .couldNotDetermine:
            return "Could Not Determine"
        case .temporarilyUnavailable:
            return "Temporarily Unavailable"
        @unknown default:
            return "Unknown"
        }
    }
}

private struct SyncPhaseDetailRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let state: SyncMonitor.SyncState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(state.phaseColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)

                    Spacer()

                    Label(state.shortDescription, systemImage: state.phaseSymbolName)
                        .font(.caption)
                        .foregroundStyle(state.phaseColor)
                }

                Text(state.detailedDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let duration = state.duration {
                    Text("Duration: \(duration.formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private extension SyncMonitor.SyncState {
    var phaseSymbolName: String {
        switch self {
        case .notStarted:
            return "circle"
        case .inProgress:
            return "arrow.clockwise.circle"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }

    var phaseColor: Color {
        switch self {
        case .notStarted:
            return .secondary
        case .inProgress:
            return .accentColor
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }

    var shortDescription: LocalizedStringKey {
        switch self {
        case .notStarted:
            return "Not Started"
        case .inProgress:
            return "In Progress"
        case .succeeded:
            return "Succeeded"
        case .failed:
            return "Failed"
        }
    }

    var detailedDescription: String {
        switch self {
        case .notStarted:
            return "CloudKit has not reported this event during the current app session."
        case .inProgress(let started):
            return "Started \(started.formatted(date: .abbreviated, time: .standard))."
        case .succeeded(_, let ended):
            return "Completed \(ended.formatted(date: .abbreviated, time: .standard))."
        case .failed(_, let ended, let error):
            if let error {
                return "Failed \(ended.formatted(date: .abbreviated, time: .standard)): \(error.localizedDescription)"
            }
            return "Failed \(ended.formatted(date: .abbreviated, time: .standard))."
        }
    }

    var duration: Duration? {
        let interval: TimeInterval

        switch self {
        case .notStarted:
            return nil
        case .inProgress(let started):
            interval = Date().timeIntervalSince(started)
        case .succeeded(let started, let ended),
             .failed(let started, let ended, _):
            interval = ended.timeIntervalSince(started)
        }

        return .seconds(max(interval, 0))
    }
}
