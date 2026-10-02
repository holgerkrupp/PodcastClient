import SwiftUI
import SwiftData

struct TranscriptSearchMaintenanceView: View {
    let modelContainer: ModelContainer
    @State private var status: TranscriptSearchIndexStatus?
    @State private var isRebuilding = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("On-Device Index") {
                if let status {
                    LabeledContent("Indexed episodes", value: "\(status.indexedEpisodes)")
                    LabeledContent("Eligible episodes", value: "\(status.eligibleEpisodes)")
                    LabeledContent("Backfill", value: status.isBackfillInProgress ? "In progress" : "Up to date")
                } else {
                    ProgressView("Reading index status…")
                }

                Text("Transcript text and queries never leave this device. The index is disposable derived data; canonical transcripts stay in the library store.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    rebuild()
                } label: {
                    if isRebuilding {
                        Label("Rebuilding…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Rebuild Transcript Search Index", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRebuilding)

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Rebuilding runs in bounded SwiftData batches and can resume after the app is closed.")
            }
        }
        .navigationTitle("Transcript Search")
        .task {
            await loadStatus()
        }
    }

    private func loadStatus() async {
        status = try? await TranscriptSearchIndex.shared.status()
    }

    private func rebuild() {
        isRebuilding = true
        message = nil
        Task(priority: .utility) {
            let report = await TranscriptSearchBackfillCoordinator(modelContainer: modelContainer).rebuild()
            await MainActor.run {
                isRebuilding = false
                message = report.completed
                    ? "Transcript search is ready. Indexed \(report.indexedEpisodes) episodes in this pass."
                    : "Rebuild paused and will continue in the background."
            }
            await loadStatus()
        }
    }
}
