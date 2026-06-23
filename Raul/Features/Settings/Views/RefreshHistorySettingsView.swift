#if DEBUG
import SwiftUI

struct RefreshHistorySettingsView: View {
    @State private var refreshHistory: [RefreshHistoryEntry] = []

    var body: some View {
        List {
            Section {
                if refreshHistory.isEmpty {
                    ContentUnavailableView(
                        "No Refresh History",
                        systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                        description: Text("Refreshes will appear here after podcast checks run on this device.")
                    )
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
                    Text("Recent Refreshes")
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
        }
        .navigationTitle("Refresh History")
        .task {
            await loadRefreshHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshHistoryDidChange)) { _ in
            Task {
                await loadRefreshHistory()
            }
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
#endif
