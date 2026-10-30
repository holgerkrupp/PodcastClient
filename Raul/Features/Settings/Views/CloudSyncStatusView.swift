import SwiftUI
import SwiftData
import CloudKit
#if canImport(UIKit)
import UIKit
#endif
import CloudKitSyncMonitor

struct CloudSyncStatusView: View {
    let modelContainer: ModelContainer

    @StateObject private var syncMonitor = SyncMonitor.default
    @StateObject private var storeMonitor = StoreCloudKitActivityMonitor.shared
    @ObservedObject private var portableWriteFailures = PortableWriteFailureMonitor.shared
    @State private var localRecordCount = 0
    @State private var reference: CloudSyncProgressReference?
    @State private var isRefreshing = false

    private var estimatedProgress: Double? {
        guard let reference, reference.recordCount > 0 else { return nil }
        let progress = Double(localRecordCount) / Double(reference.recordCount)
        return min(progress, syncMonitor.syncStateSummary.isInProgress ? 0.95 : 1)
    }

    private var showsRecentPortableRecovery: Bool {
        guard portableWriteFailures.state.status == .recovered,
              let recoveredAt = portableWriteFailures.state.lastSuccessfulRepairAt else { return false }
        return Date().timeIntervalSince(recoveredAt) < 15
    }

    private var statusTitle: LocalizedStringKey {
        switch portableWriteFailures.state.status {
        case .pending: return "Playback Sync Pending"
        case .recovering: return "Recovering Playback Data"
        case .requiresAttention: return "Playback Recovery Needs Attention"
        case .recovered:
            if showsRecentPortableRecovery { return "Playback Data Recovered" }
        case .idle: break
        }
        let stores = storeMonitor.storeDiagnostics.filter(\.isAttached)
        if stores.contains(where: { $0.hasUnresolvedExportFailure }) {
            return "Sync Error"
        }
        if stores.contains(where: { $0.importStatus == .syncing }) {
            return "Syncing user data"
        }
        if stores.contains(where: { $0.importStatus == .failed }) {
            return "Sync Error"
        }
        if stores.contains(where: { $0.importStatus == .notObserved }) {
            return "Waiting for Store Import"
        }
        if stores.isEmpty == false {
            return "Store Imports Complete"
        }
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
        switch portableWriteFailures.state.status {
        case .pending: return .orange
        case .recovering: return .secondary
        case .requiresAttention: return .orange
        case .recovered:
            if showsRecentPortableRecovery { return .green }
        case .idle: break
        }
        let stores = storeMonitor.storeDiagnostics.filter(\.isAttached)
        if stores.contains(where: { $0.hasUnresolvedExportFailure }) {
            return .red
        }
        if stores.contains(where: { $0.importStatus == .syncing }) {
            return .secondary
        }
        if stores.contains(where: { $0.importStatus == .failed }) {
            return .red
        }
        if stores.contains(where: { $0.importStatus == .notObserved }) {
            return .orange
        }
        if stores.isEmpty == false {
            return .green
        }
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
            if portableWriteFailures.state.repairNeeded || showsRecentPortableRecovery {
                Label(
                    showsRecentPortableRecovery
                        ? "Playback data was recovered on this device. iCloud may still be syncing."
                        : (portableWriteFailures.state.requiresReconstruction
                        ? "Playback data needs attention. Keep Up Next installed. It keeps retrying while the app is open."
                        : (portableWriteFailures.state.pendingOperations.isEmpty
                            ? "Up Next is retrying a playback data update. Keep using the app; check back here if this status persists."
                            : "Playback data is being recovered on this device. Keep Up Next installed while recovery finishes.")),
                    systemImage: showsRecentPortableRecovery
                        ? "checkmark.circle"
                        : (portableWriteFailures.state.requiresReconstruction
                            ? "exclamationmark.triangle"
                            : "arrow.triangle.2.circlepath")
                )
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
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

            ForEach(storeMonitor.storeDiagnostics.filter(\.isAttached)) { diagnostic in
                StoreCloudKitDiagnosticRow(diagnostic: diagnostic)
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
    @StateObject private var storeMonitor = StoreCloudKitActivityMonitor.shared
    @StateObject private var supportDiagnostics = SupportDiagnosticsRecorder.shared
    @State private var expandedErrorDetails = false
    @State private var isCapturingSupportSnapshot = false

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

    private func describe(_ error: Error) -> CloudKitErrorDetail {
        let report = CloudKitFailureAnalyzer.analyze(error)
        return CloudKitErrorDetail(
            summary: error.localizedDescription,
            report: report
        )
    }

    var body: some View {
        List {
            Section("Current Status") {
                CloudSyncStatusView(modelContainer: modelContainer)
            }

            Section("Environment") {
                LabeledContent("Store Split Release") {
                    Text("User State authority")
                }

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

            Section("Mirrored Stores") {
                ForEach(storeMonitor.storeDiagnostics.filter(\.isAttached)) { diagnostic in
                    StoreCloudKitDiagnosticRow(diagnostic: diagnostic, expanded: true)
                }
            }

            Section("Aggregate Monitor") {
                Text("These package-level phases describe the latest CloudKit event from any store. Store convergence is reported above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            Section("Support Diagnostics") {
                Text("Install this build without reinstalling or resetting data. Capture a snapshot as soon as Up Next is empty, wait for entries to return or at least three minutes, then capture again. Review the preview before sharing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    guard isCapturingSupportSnapshot == false else { return }
                    isCapturingSupportSnapshot = true
                    Task { @MainActor in
                        await supportDiagnostics.capture(
                            manager: ModelContainerManager.shared,
                            modelContainer: modelContainer,
                            networkStatus: networkDescription,
                            accountStatus: accountDescription,
                            aggregateErrorCategories: reportedErrors.flatMap { item in
                                CloudKitFailureAnalyzer.analyze(item.error).groups.prefix(6).map {
                                    "\(item.title): \($0.displayName) × \($0.count)"
                                }
                            },
                            storeMonitor: storeMonitor
                        )
                        isCapturingSupportSnapshot = false
                    }
                } label: {
                    if isCapturingSupportSnapshot {
                        Label("Capturing Snapshot…", systemImage: "hourglass")
                    } else {
                        Label("Capture Snapshot", systemImage: "camera")
                    }
                }
                .disabled(isCapturingSupportSnapshot)
                .accessibilityHint("Adds a timestamped local-state snapshot to the support report")

                HStack {
                    Button("Copy Report", systemImage: "doc.on.doc") {
#if canImport(UIKit)
                        UIPasteboard.general.string = supportDiagnostics.reportText
#endif
                    }
                    .disabled(supportDiagnostics.snapshots.isEmpty)

                    ShareLink(
                        item: supportDiagnostics.reportText,
                        subject: Text("Up Next Support Diagnostics")
                    ) {
                        Label("Share Report", systemImage: "square.and.arrow.up")
                    }
                    .disabled(supportDiagnostics.snapshots.isEmpty)
                }

                ScrollView {
                    Text(supportDiagnostics.reportText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 280)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Support diagnostics report preview")
            }

            if reportedErrors.isEmpty == false {
                Section("Errors") {
                    ForEach(Array(reportedErrors.enumerated()), id: \.offset) { _, item in
                        let detail = describe(item.error)

                        VStack(alignment: .leading, spacing: 6) {
                            Label(item.title, systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.red)

                            Text(detail.summary)
                                .font(.callout)
                                .textSelection(.enabled)

                            Text("Store: unknown (aggregate sync monitor)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(detail.report.summary)
                                .font(.subheadline.weight(.medium))
                                .textSelection(.enabled)

                            if detail.report.groups.isEmpty == false {
                                DisclosureGroup(
                                    expandedErrorDetails ? "Error categories" : "Show error categories",
                                    isExpanded: $expandedErrorDetails
                                ) {
                                    ForEach(detail.report.groups) { group in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(group.count) × \(group.displayName)")
                                                .font(.caption.monospaced())
                                                .textSelection(.enabled)
                                            if let reason = group.reason {
                                                Text(reason)
                                                    .font(.caption)
                                                    .textSelection(.enabled)
                                            }
                                            if let retryAfter = group.retryAfterSeconds {
                                                Text("Retry after \(retryAfter.formatted(.number.precision(.fractionLength(0...1)))) seconds")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.vertical, 3)
                                    }
                                    if detail.report.wasTruncated {
                                        Text("Additional nested errors were omitted from this bounded report.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("About Sync Progress") {
                Text("The progress bar compares this device's local SwiftData record count with a lightweight reference shared through iCloud.")

                Text("CloudKit does not expose exact transfer progress, so the displayed percentage is an estimate. A store is only marked complete after that store's own import event succeeds; an unrelated store's completed import does not mark the queue current.")
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

private struct StoreCloudKitDiagnosticRow: View {
    let diagnostic: StoreCloudKitActivityMonitor.StoreDiagnostics
    var expanded = false

    private var statusText: String {
        guard diagnostic.isAttached else { return "Not attached" }
        switch diagnostic.importStatus {
        case .notObserved: return "No import event observed"
        case .syncing: return "Syncing…"
        case .complete: return "Import complete"
        case .failed:
            if let code = diagnostic.lastImportErrorCode {
                return "Failed (error \(code))"
            }
            return "Failed"
        }
    }

    private var statusColor: Color {
        guard diagnostic.isAttached else { return .secondary }
        switch diagnostic.importStatus {
        case .notObserved: return .orange
        case .syncing: return .secondary
        case .complete: return .green
        case .failed: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: diagnostic.importStatus == .syncing
                    ? "arrow.triangle.2.circlepath"
                    : "externaldrive.connected.to.line.below")
                    .foregroundStyle(statusColor)
                Text(diagnostic.storeKind.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            if let lastSuccessfulImportAt = diagnostic.lastSuccessfulImportAt {
                Text("Last successful import \(lastSuccessfulImportAt, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if diagnostic.activeExportCount > 0 {
                Text("Upload: \(diagnostic.activeExportCount) active")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let lastSuccessfulExportAt = diagnostic.lastSuccessfulExportAt {
                Text("Last successful upload \(lastSuccessfulExportAt, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if diagnostic.hasUnresolvedExportFailure {
                Label(
                    "Last upload failed: \(diagnostic.lastExportFailureReport?.summary ?? "Error details unavailable")",
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Text("Store-attributed failure · \(diagnostic.failedExportCount) failed upload event(s) in recent history")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let primary = diagnostic.lastExportFailureReport?.groups.first {
                    Text(primary.displayName + (primary.reason.map { ": \($0)" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let retryAfter = primary.retryAfterSeconds {
                        Text("CloudKit retry hint: \(Int(ceil(retryAfter))) seconds")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if diagnostic.activeExportCount == 0,
                      diagnostic.lastExportEndedAt == nil {
                Text("No completed upload event observed in this session/history. This does not confirm synchronization.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if expanded {
                if let before = diagnostic.lastImportCountsBefore,
                   let after = diagnostic.lastImportCountsAfter {
                    if diagnostic.storeKind == .legacy,
                       let beforeCount = before.legacyPlaylistEntryCount,
                       let afterCount = after.legacyPlaylistEntryCount {
                        Text("Playlist entries: \(beforeCount) → \(afterCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if diagnostic.storeKind == .userState,
                              let beforeCount = before.userStateQueueEntryCount,
                              let afterCount = after.userStateQueueEntryCount {
                        Text("User State queue entries: \(beforeCount) → \(afterCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let reconciliation = diagnostic.lastReconciliation {
                    Label {
                        Text(reconciliation.summary)
                            .lineLimit(3)
                    } icon: {
                        Image(systemName: reconciliation.succeeded
                            ? "checkmark.circle"
                            : "exclamationmark.triangle")
                    }
                    .font(.caption2)
                    .foregroundStyle(
                        reconciliation.succeeded ? Color.secondary : Color.red
                    )
                }
            }
        }
        .padding(.vertical, expanded ? 4 : 2)
    }
}

private struct CloudKitErrorDetail {
    let summary: String
    let report: CloudKitFailureAnalyzer.Report
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
