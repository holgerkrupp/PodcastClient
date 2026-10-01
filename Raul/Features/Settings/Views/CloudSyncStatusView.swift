import SwiftUI
import SwiftData
import CloudKit
import CloudKitSyncMonitor

struct CloudSyncStatusView: View {
    let modelContainer: ModelContainer

    @StateObject private var syncMonitor = SyncMonitor.default
    @StateObject private var storeMonitor = StoreCloudKitActivityMonitor.shared
    @State private var localRecordCount = 0
    @State private var reference: CloudSyncProgressReference?
    @State private var isRefreshing = false

    private var estimatedProgress: Double? {
        guard let reference, reference.recordCount > 0 else { return nil }
        let progress = Double(localRecordCount) / Double(reference.recordCount)
        return min(progress, syncMonitor.syncStateSummary.isInProgress ? 0.95 : 1)
    }

    private var statusTitle: LocalizedStringKey {
        let stores = storeMonitor.storeDiagnostics.filter(\.isAttached)
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
            return "Stores Synced"
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
        let stores = storeMonitor.storeDiagnostics.filter(\.isAttached)
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

    /// Flattens a sync error into something a human can read. CloudKit reports
    /// a bulk export rejection as `CKError.partialFailure` (CKErrorDomain 2),
    /// which hides the real reason inside `partialErrorsByItemID`. CoreData also
    /// tends to wrap the `CKError` under `NSUnderlyingErrorKey`, so we dig for it.
    private func describe(_ error: Error) -> CloudKitErrorDetail {
        let ckError = Self.firstCKError(in: error as NSError)
        var partials: [CloudKitErrorDetail.PartialFailure] = []

        if let map = ckError?.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            for (itemID, subError) in map {
                partials.append(
                    CloudKitErrorDetail.PartialFailure(
                        itemID: String(describing: itemID),
                        reason: subError.localizedDescription,
                        code: Self.ckCodeDescription(for: subError as NSError)
                    )
                )
            }
            partials.sort { $0.itemID < $1.itemID }
        }

        return CloudKitErrorDetail(
            summary: error.localizedDescription,
            code: Self.ckCodeDescription(for: ckError ?? error as NSError),
            partialFailures: partials
        )
    }

    /// Walks the `NSUnderlyingErrorKey` chain to find the first CloudKit error.
    private static func firstCKError(in nsError: NSError) -> NSError? {
        if nsError.domain == CKErrorDomain {
            return nsError
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return firstCKError(in: underlying)
        }
        return nil
    }

    private static func ckCodeDescription(for nsError: NSError) -> String? {
        guard nsError.domain == CKErrorDomain else { return nil }

        let name: String
        switch CKError.Code(rawValue: nsError.code) {
        case .internalError: name = "internalError"
        case .partialFailure: name = "partialFailure"
        case .networkUnavailable: name = "networkUnavailable"
        case .networkFailure: name = "networkFailure"
        case .badContainer: name = "badContainer"
        case .serviceUnavailable: name = "serviceUnavailable"
        case .requestRateLimited: name = "requestRateLimited"
        case .missingEntitlement: name = "missingEntitlement"
        case .notAuthenticated: name = "notAuthenticated"
        case .permissionFailure: name = "permissionFailure"
        case .unknownItem: name = "unknownItem"
        case .invalidArguments: name = "invalidArguments"
        case .serverRecordChanged: name = "serverRecordChanged"
        case .serverRejectedRequest: name = "serverRejectedRequest"
        case .assetFileNotFound: name = "assetFileNotFound"
        case .assetFileModified: name = "assetFileModified"
        case .incompatibleVersion: name = "incompatibleVersion"
        case .constraintViolation: name = "constraintViolation"
        case .operationCancelled: name = "operationCancelled"
        case .changeTokenExpired: name = "changeTokenExpired"
        case .batchRequestFailed: name = "batchRequestFailed"
        case .zoneBusy: name = "zoneBusy"
        case .badDatabase: name = "badDatabase"
        case .quotaExceeded: name = "quotaExceeded"
        case .zoneNotFound: name = "zoneNotFound"
        case .limitExceeded: name = "limitExceeded"
        case .userDeletedZone: name = "userDeletedZone"
        case .accountTemporarilyUnavailable: name = "accountTemporarilyUnavailable"
        default: name = "code \(nsError.code)"
        }

        return "CKError \(nsError.code) — \(name)"
    }

    var body: some View {
        List {
            Section("Current Status") {
                CloudSyncStatusView(modelContainer: modelContainer)
            }

            Section("Environment") {
                LabeledContent("Store Split Release") {
                    Text(StoreSplitReleasePhase.current == .dualSyncBackfill
                        ? "Dual sync backfill"
                        : "User State authority")
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
                ForEach(storeMonitor.storeDiagnostics) { diagnostic in
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

                            if let code = detail.code {
                                Text(code)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            if detail.partialFailures.isEmpty == false {
                                Divider()

                                Text("\(detail.partialFailures.count) rejected record(s):")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                ForEach(detail.partialFailures.prefix(25)) { failure in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(failure.itemID)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)

                                        Text(failure.reason)
                                            .font(.caption2)
                                            .textSelection(.enabled)

                                        if let code = failure.code {
                                            Text(code)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .padding(.leading, 8)
                                }

                                if detail.partialFailures.count > 25 {
                                    Text("+ \(detail.partialFailures.count - 25) more")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
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
        case .notObserved: return "Waiting for first import event"
        case .syncing: return "Syncing…"
        case .complete: return "Complete"
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
                Text("Upload: (diagnostic.activeExportCount) active")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let lastSuccessfulExportAt = diagnostic.lastSuccessfulExportAt {
                Text("Last successful upload \(lastSuccessfulExportAt, format: .relative(presentation: .named))")
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
    let code: String?
    let partialFailures: [PartialFailure]

    struct PartialFailure: Identifiable {
        let id = UUID()
        let itemID: String
        let reason: String
        let code: String?
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
