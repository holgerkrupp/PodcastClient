#if DEBUG
import SwiftUI
import SwiftData

struct RefreshHistorySettingsView: View {
    @State private var refreshHistory: [RefreshHistoryEntry] = []

    var body: some View {
        List {
            /*
            Section {
                NavigationLink {
                    PredictedRefreshQueueSettingsView()
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(.accent)
                            .frame(width: 24, height: 24)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Next Predicted Refreshes")
                                .foregroundStyle(.primary)

                            Text("Next \(BackgroundTaskConfiguration.predictedReleaseRefreshPodcastLimit) podcasts")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            Text("Sorted by refresh priority, then predicted release time, with the submitted background task marked.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
*/
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

 struct PredictedRefreshQueueSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var candidates: [SubscriptionManager.PredictedReleaseRefreshTarget] = []
    @State private var scheduledRefresh: PredictedReleaseRefreshSchedule?
    @State private var loadedAt = Date()
    @State private var isLoading = true

    private let candidateLimit = BackgroundTaskConfiguration.predictedReleaseRefreshPodcastLimit

    var body: some View {
        List {
            Section {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading predictions...")
                            .foregroundStyle(.secondary)
                    }
                } else if candidates.isEmpty {
                    ContentUnavailableView(
                        "No Predicted Refreshes",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Predictions appear after subscribed podcasts have enough episode history.")
                    )
                } else {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        PredictedRefreshCandidateRow(
                            rank: index + 1,
                            candidate: candidate,
                            isScheduled: isScheduled(candidate),
                            now: loadedAt
                        )
                    }
                }
            } header: {
                Text("Next \(candidateLimit) Podcasts")
            } footer: {
                if let scheduledRefresh {
                    Text("The scheduled marker reflects the last predicted-release background task successfully submitted for \(scheduledRefresh.title), earliest \(scheduledRefresh.earliestBeginDate, format: .dateTime.month().day().hour().minute()).")
                } else {
                    Text("No predicted-release background task is currently recorded for this debug build.")
                }
            }
        }
        .navigationTitle("Next Refreshes")
        .task {
            await loadQueue()
        }
        .refreshable {
            await loadQueue()
        }
        .onReceive(NotificationCenter.default.publisher(for: .predictedReleaseRefreshScheduleDidChange)) { _ in
            Task {
                await loadSchedule()
            }
        }
    }

    @MainActor
    private func loadQueue() async {
        isLoading = true
        let now = Date()
        let manager = SubscriptionManager(modelContainer: modelContext.container)
        candidates = await manager.predictedReleaseRefreshCandidates(
            after: now,
            limit: candidateLimit
        )
        scheduledRefresh = await PredictedReleaseRefreshScheduleStore.shared.schedule()
        loadedAt = now
        isLoading = false
    }

    @MainActor
    private func loadSchedule() async {
        scheduledRefresh = await PredictedReleaseRefreshScheduleStore.shared.schedule()
    }

    private func isScheduled(_ candidate: SubscriptionManager.PredictedReleaseRefreshTarget) -> Bool {
        guard let scheduledRefresh else { return false }
        return scheduledRefresh.feedURL == candidate.feed.absoluteString
            && abs(scheduledRefresh.releaseDate.timeIntervalSince(candidate.releaseDate)) < 1
    }
}

private struct PredictedRefreshCandidateRow: View {
    let rank: Int
    let candidate: SubscriptionManager.PredictedReleaseRefreshTarget
    let isScheduled: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(rank)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(candidate.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                if isScheduled {
                    Label("Scheduled", systemImage: "calendar.badge.clock")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Scheduled background refresh")
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(candidate.releaseDate, format: .dateTime.weekday(.abbreviated).month().day().hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(releaseDateColor)
            }

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Window \(candidate.refreshStart, format: .dateTime.hour().minute())-\(candidate.refreshEnd, format: .dateTime.hour().minute())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text("Score \(candidate.score)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Text(lastCheckText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(candidate.feed.absoluteString)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var releaseDateColor: Color {
        candidate.releaseDate <= now ? .orange : .primary
    }

    private var lastCheckText: String {
        guard let lastCheck = candidate.lastCheck else {
            return "Never checked"
        }

        return "Checked \(lastCheck.formatted(.relative(presentation: .named)))"
    }
}
#endif
