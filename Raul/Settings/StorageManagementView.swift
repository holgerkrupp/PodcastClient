import SwiftUI
import SwiftData

struct StorageManagementView: View {
    let modelContainer: ModelContainer

    @Environment(DownloadedFilesManager.self) private var filesManager

    @State private var report: StorageUsageReport?
    @State private var isLoading = false
    @State private var loadingProgress = 0.0
    @State private var loadingMessage = "Preparing storage scan…"
    @State private var isDeleting = false
    @State private var presentedAlert: StorageAlert?

    var body: some View {
        List {
            if let report {
                overviewSection(report)

                if report.databaseArtifacts.isEmpty == false {
                    databaseArtifactsSection(report)
                }

                if report.databaseBreakdown.isEmpty == false {
                    databaseBreakdownSection(report)
                }

                podcastsSection(report)
                fileActionsSection(report)
                fileSections(report)
            } else if isLoading {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(loadingMessage)
                            .font(.headline)

                        ProgressView(value: loadingProgress, total: 1)
                            .progressViewStyle(.linear)

                        Text("\(Int((loadingProgress * 100).rounded()))% complete")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Text("Scanning the database and stored files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
            } else {
                ContentUnavailableView(
                    "No Storage Report",
                    systemImage: "internaldrive",
                    description: Text("Pull to refresh to calculate the app's current storage usage.")
                )
            }
        }
        .navigationTitle("Storage")
        .refreshable {
            await reload()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await reload()
                    }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading || isDeleting)
            }
        }
        .task {
            guard report == nil else { return }
            await reload()
        }
        .alert(item: $presentedAlert) { alert in
            switch alert {
            case .deletion(let deletion):
                Alert(
                    title: Text(deletion.title),
                    message: Text(deletion.message),
                    primaryButton: .destructive(Text("Delete")) {
                        Task {
                            await performDeletion(deletion)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .error(let message):
                Alert(
                    title: Text("Storage Error"),
                    message: Text(message),
                    dismissButton: .cancel(Text("OK"))
                )
            }
        }
    }

    @ViewBuilder
    private func overviewSection(_ report: StorageUsageReport) -> some View {
        Section("Overview") {
            LabeledContent("Total Used") {
                Text(report.totalStorageBytes.formattedAsStorage)
                    .monospacedDigit()
            }

            LabeledContent("Database") {
                Text(report.databaseBytes.formattedAsStorage)
                    .monospacedDigit()
            }

            LabeledContent("Files") {
                Text(report.fileBytes.formattedAsStorage)
                    .monospacedDigit()
            }

            LabeledContent("Stored Files") {
                Text("\(report.files.count)")
                    .monospacedDigit()
            }

            if report.unattributedFileBytes > 0 {
                LabeledContent("Unattributed Files") {
                    Text(report.unattributedFileBytes.formattedAsStorage)
                        .monospacedDigit()
                }
            }

            Text("The database total uses the real SQLite files on disk. The podcast and data-type breakdowns below estimate each record's share and scale that estimate to the actual database size.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func databaseArtifactsSection(_ report: StorageUsageReport) -> some View {
        Section("Database Files") {
            ForEach(report.databaseArtifacts) { artifact in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(artifact.name)
                            .font(.body.monospaced())
                            .lineLimit(1)

                        Spacer()

                        Text(artifact.size.formattedAsStorage)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text(artifact.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func databaseBreakdownSection(_ report: StorageUsageReport) -> some View {
        Section {
            ForEach(report.databaseBreakdown) { usage in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(usage.category.title)
                        Text("\(usage.count) item\(usage.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(usage.bytes.formattedAsStorage)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Database Breakdown")
        } footer: {
            if report.unattributedDatabaseBytes > 0 {
                Text("\(report.unattributedDatabaseBytes.formattedAsStorage) is shared metadata or SQLite overhead that can’t be tied to a single podcast.")
            }
        }
    }

    @ViewBuilder
    private func podcastsSection(_ report: StorageUsageReport) -> some View {
        Section("By Podcast") {
            if report.podcasts.isEmpty {
                ContentUnavailableView(
                    "No Podcast Storage Yet",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Podcast-attributed storage will appear here once content is stored locally.")
                )
            } else {
                ForEach(report.podcasts) { usage in
                    NavigationLink {
                        PodcastStorageDetailView(
                            usage: usage,
                            files: report.files.filter { $0.podcastID == usage.id }
                        )
                    } label: {
                        PodcastStorageRow(usage: usage)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fileActionsSection(_ report: StorageUsageReport) -> some View {
        let outsideUpNextFiles = filesOutsideUpNext(report)

        Section("File Cleanup") {
            if report.files.isEmpty {
                ContentUnavailableView(
                    "No Stored Files",
                    systemImage: "trash.slash",
                    description: Text("Downloaded audio and cache files will appear here when they exist.")
                )
            } else {
                if outsideUpNextFiles.isEmpty == false {
                    Button(role: .destructive) {
                        presentedAlert = .deletion(
                            .outsideUpNext(
                                fileCount: outsideUpNextFiles.count,
                                bytes: outsideUpNextFiles.totalBytes
                            )
                        )
                    } label: {
                        Label("Delete Files Not in Up Next", systemImage: "text.line.last.and.arrowtriangle.forward")
                    }
                    .disabled(isDeleting)
                }

                Button(role: .destructive) {
                    presentedAlert = .deletion(.allFiles)
                } label: {
                    Label("Delete All Stored Files", systemImage: "trash")
                }
                .disabled(isDeleting)

                if report.upNextProtectedFileCount > 0 {
                    Text("\(report.upNextProtectedFileCount) file\(report.upNextProtectedFileCount == 1 ? "" : "s") (\(report.upNextProtectedFileBytes.formattedAsStorage)) are currently protected because their episodes are in Up Next.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if outsideUpNextFiles.isEmpty == false {
                    Text("\(outsideUpNextFiles.count) file\(outsideUpNextFiles.count == 1 ? "" : "s") (\(outsideUpNextFiles.totalBytes.formattedAsStorage)) can be removed without deleting downloads needed for the current Up Next queue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("This removes downloaded media and cache files, but keeps your SwiftData database, subscriptions, and playback history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func fileSections(_ report: StorageUsageReport) -> some View {
        if report.files.isEmpty == false {
            ForEach(StorageFileRoot.allCases) { root in
                let rootFiles = report.files.filter { $0.root == root }

                if rootFiles.isEmpty == false {
                    Section {
                        ForEach(rootFiles) { file in
                            StorageFileRow(
                                file: file,
                                isProtectedByUpNext: isProtectedByUpNext(file, report: report)
                            )
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        presentedAlert = .deletion(.file(file))
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Label(root.title, systemImage: root.systemImage)
                            Spacer()
                            Text(rootFiles.totalBytes.formattedAsStorage)
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("\(rootFiles.count) file\(rootFiles.count == 1 ? "" : "s")")
                    }
                }
            }
        }
    }

    private func reload() async {
        isLoading = true
        loadingProgress = 0.03
        loadingMessage = "Preparing storage scan…"
        defer {
            isLoading = false
            loadingProgress = 0
        }

        do {
            report = try await StorageManagementService(modelContainer: modelContainer).makeReport { progress in
                await MainActor.run {
                    loadingProgress = progress.fractionCompleted
                    loadingMessage = progress.message
                }
            }
        } catch {
            presentedAlert = .error(error.localizedDescription)
        }
    }

    private func performDeletion(_ deletion: PendingDeletion) async {
        isDeleting = true
        defer {
            isDeleting = false
        }

        do {
            switch deletion {
            case .file(let file):
                await StorageManagementService(modelContainer: modelContainer).delete(file: file)
            case .outsideUpNext:
                _ = try await StorageManagementService(modelContainer: modelContainer).deleteFilesOutsideUpNext()
            case .allFiles:
                await StorageManagementService(modelContainer: modelContainer).deleteAll(files: report?.files ?? [])
            }

            filesManager.rescanDownloadedFiles()
            await reload()
        } catch {
            presentedAlert = .error(error.localizedDescription)
        }
    }

    private func filesOutsideUpNext(_ report: StorageUsageReport?) -> [StorageFileEntry] {
        guard let report else { return [] }

        return StorageManagementService.filesOutsideUpNext(in: report)
    }

    private func isProtectedByUpNext(_ file: StorageFileEntry, report: StorageUsageReport) -> Bool {
        StorageManagementService.isProtectedByUpNext(file, in: report)
    }
}

private struct PodcastStorageRow: View {
    let usage: PodcastStorageUsage

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(usage.podcastTitle)
                    .lineLimit(2)

                Text(metadataLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(usage.totalBytes.formattedAsStorage)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                if usage.fileBytes > 0 {
                    Text("Files \(usage.fileBytes.formattedAsStorage)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var metadataLine: String {
        var parts = [
            "\(usage.episodeCount) episode\(usage.episodeCount == 1 ? "" : "s")"
        ]

        if usage.transcriptLineCount > 0 {
            parts.append("\(usage.transcriptLineCount) transcript lines")
        }

        if usage.chapterCount > 0 {
            parts.append("\(usage.chapterCount) chapters")
        }

        if usage.bookmarkCount > 0 {
            parts.append("\(usage.bookmarkCount) bookmarks")
        }

        if usage.transcriptionRecordCount > 0 {
            parts.append("\(usage.transcriptionRecordCount) transcription records")
        }

        return parts.joined(separator: " • ")
    }
}

private struct StorageFileRow: View {
    let file: StorageFileEntry
    var isProtectedByUpNext: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(file.displayName)
                    .lineLimit(1)

                if isProtectedByUpNext {
                    Text("Up Next")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }

                Spacer()

                Text(file.size.formattedAsStorage)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let podcastTitle = file.podcastTitle {
                Text(file.episodeTitle.map { "\(podcastTitle) • \($0)" } ?? podcastTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(file.relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

private struct PodcastStorageDetailView: View {
    let usage: PodcastStorageUsage
    let files: [StorageFileEntry]

    var body: some View {
        List {
            Section("Overview") {
                LabeledContent("Total") {
                    Text(usage.totalBytes.formattedAsStorage)
                        .monospacedDigit()
                }

                LabeledContent("Database Estimate") {
                    Text(usage.estimatedDatabaseBytes.formattedAsStorage)
                        .monospacedDigit()
                }

                LabeledContent("Stored Files") {
                    Text(usage.fileBytes.formattedAsStorage)
                        .monospacedDigit()
                }

                if usage.fileCount > 0 {
                    LabeledContent("File Count") {
                        Text("\(usage.fileCount)")
                            .monospacedDigit()
                    }
                }
            }

            if usage.typeBreakdown.isEmpty == false {
                Section("Database Estimate by Type") {
                    ForEach(usage.typeBreakdown) { type in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(type.category.title)
                                Text("\(type.count) item\(type.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(type.bytes.formattedAsStorage)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Counts") {
                LabeledContent("Episodes") {
                    Text("\(usage.episodeCount)")
                        .monospacedDigit()
                }
                LabeledContent("Transcript Lines") {
                    Text("\(usage.transcriptLineCount)")
                        .monospacedDigit()
                }
                LabeledContent("Chapters") {
                    Text("\(usage.chapterCount)")
                        .monospacedDigit()
                }
                LabeledContent("Bookmarks") {
                    Text("\(usage.bookmarkCount)")
                        .monospacedDigit()
                }
                if usage.transcriptionRecordCount > 0 {
                    LabeledContent("Transcription Records") {
                        Text("\(usage.transcriptionRecordCount)")
                            .monospacedDigit()
                    }
                }
            }

            Section("Stored Files") {
                if files.isEmpty {
                    ContentUnavailableView(
                        "No Files for This Podcast",
                        systemImage: "waveform.badge.minus",
                        description: Text("This podcast currently has no standalone files stored outside the database.")
                    )
                } else {
                    ForEach(files) { file in
                        StorageFileRow(file: file)
                    }
                }
            }
        }
        .navigationTitle(usage.podcastTitle)
    }
}

private enum PendingDeletion: Identifiable {
    case file(StorageFileEntry)
    case outsideUpNext(fileCount: Int, bytes: Int64)
    case allFiles

    var id: String {
        switch self {
        case .file(let file):
            "file:\(file.id)"
        case .outsideUpNext:
            "outsideUpNext"
        case .allFiles:
            "allFiles"
        }
    }

    var title: String {
        switch self {
        case .file(let file):
            "Delete \(file.displayName)?"
        case .outsideUpNext:
            "Delete files not in Up Next?"
        case .allFiles:
            "Delete all stored files?"
        }
    }

    var message: String {
        switch self {
        case .file:
            "This removes the selected file from local storage."
        case .outsideUpNext(let fileCount, let bytes):
            "This removes \(fileCount) file\(fileCount == 1 ? "" : "s") (\(bytes.formattedAsStorage)) while keeping files for episodes that are still in Up Next."
        case .allFiles:
            "This removes all listed files from local storage but keeps the database."
        }
    }
}

private enum StorageAlert: Identifiable {
    case deletion(PendingDeletion)
    case error(String)

    var id: String {
        switch self {
        case .deletion(let deletion):
            "deletion:\(deletion.id)"
        case .error(let message):
            "error:\(message)"
        }
    }
}

private extension Int64 {
    var formattedAsStorage: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

private extension Array where Element == StorageFileEntry {
    var totalBytes: Int64 {
        reduce(into: Int64(0)) { partialResult, entry in
            partialResult += entry.size
        }
    }
}

#Preview {
    NavigationStack {
        StorageManagementView(modelContainer: ModelContainerManager.shared.container)
            .environment(DownloadedFilesManager(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!))
    }
}
