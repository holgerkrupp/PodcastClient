#if DEBUG
import SwiftUI

/// The store-split migration trace, on its own screen.
///
/// It owns its loading so the surrounding settings view does not have to
/// remember to refresh it after every action, and so a log that has grown to its
/// 300-entry cap does not bury the controls above it.
struct StoreSplitMigrationLogView: View {
    @ObservedObject private var modelContainerManager = ModelContainerManager.shared
    @State private var entries: [StoreSplitMigrationLogEntry] = []

    var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No migration activity",
                        systemImage: "clock.badge.questionmark",
                        description: Text(
                            "Nothing has been recorded yet. An empty log after a night on the charger means iOS never ran the background task — not that the migration found no work."
                        )
                    )
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        StoreSplitMigrationLogRow(entry: entry)
                    }
                } footer: {
                    Text("Newest first, capped at the most recent entries. Recorded in the App Group so the background pass leaves a trace even though it runs in its own launch of the app.")
                }
            }
        }
        .navigationTitle("Migration Log")
        .platformInlineNavigationTitle()
        .toolbar {
            // Declared first so it sits furthest from the trailing edge: it is
            // destructive and this log is often the only record of what the
            // background pass did overnight.
            Button(role: .destructive) {
                StoreSplitMigrationDebugLog.clear()
                entries = []
            } label: {
                Label("Clear Log", systemImage: "trash")
            }
            .disabled(entries.isEmpty)

            Button {
                reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .refreshable {
            reload()
        }
        .task {
            reload()
        }
        // Slices publish their progress through the manager, so this picks up new
        // entries while the screen is open without polling.
        .onChange(of: modelContainerManager.migrationProgressSummary) { _, _ in
            reload()
        }
        .onChange(of: modelContainerManager.lastSplitStoreReconcileSummary) { _, _ in
            reload()
        }
    }

    private func reload() {
        entries = StoreSplitMigrationDebugLog.entries
    }
}

private struct StoreSplitMigrationLogRow: View {
    let entry: StoreSplitMigrationLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.event)
                .font(.callout)
            Text(entry.date.formatted(date: .abbreviated, time: .standard))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let details = entry.details {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
