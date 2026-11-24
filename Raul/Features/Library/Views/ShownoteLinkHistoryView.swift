import SwiftUI

struct ShownoteLinkHistoryView: View {
    @State private var entries: [ShownoteLinkHistoryEntry] = []
    @State private var isEnabled = false
    @State private var retention: ShownoteLinkHistoryRetention = .off
    @State private var searchText = ""
    @State private var isShowingClearConfirmation = false

    private var filteredEntries: [ShownoteLinkHistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return entries }
        return entries.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
    }

    private var groupedEntries: [ShownoteLinkHistoryGroup] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filteredEntries) {
            calendar.startOfDay(for: $0.openedAt)
        }
        return groups.keys.sorted(by: >).map { date in
            ShownoteLinkHistoryGroup(
                date: date,
                title: sectionTitle(for: date, calendar: calendar),
                entries: groups[date] ?? []
            )
        }
    }

    var body: some View {
        List {
            Section("Privacy") {
                Toggle("Save Recent Links", isOn: enabledBinding)

                Picker("Keep links for", selection: retentionBinding) {
                    ForEach(ShownoteLinkHistoryRetention.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .disabled(isEnabled == false)

                Text("Links are stored only on this device. Up Next records an entry only when you explicitly open an HTTP or HTTPS link from episode show notes; it does not record browsing outside Up Next or preview requests.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if groupedEntries.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Recent Links" : "No Matching Links",
                    systemImage: "link",
                    description: Text(
                        isEnabled
                            ? "Links you open from episode show notes will appear here."
                            : "Turn on Save Recent Links to keep a local history."
                    )
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(groupedEntries) { group in
                    Section(group.title) {
                        ForEach(group.entries) { entry in
                            historyRow(entry)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task {
                                            await ShownoteLinkHistoryStore.shared.remove(id: entry.id)
                                            await reload()
                                        }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle("Recent Links")
        .searchable(text: $searchText, prompt: "Title, domain, or episode")
        .toolbar {
            if entries.isEmpty == false {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Clear All", systemImage: "trash") {
                        isShowingClearConfirmation = true
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear Recent Links?",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                Task {
                    await ShownoteLinkHistoryStore.shared.clear()
                    await reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local show-note link history from this device.")
        }
        .task {
            await reload()
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                isEnabled = newValue
                Task {
                    await ShownoteLinkHistoryStore.shared.setEnabled(newValue)
                    await reload()
                }
            }
        )
    }

    private var retentionBinding: Binding<ShownoteLinkHistoryRetention> {
        Binding(
            get: { retention },
            set: { newValue in
                retention = newValue
                Task {
                    await ShownoteLinkHistoryStore.shared.setRetention(newValue)
                    await reload()
                }
            }
        )
    }

    @ViewBuilder
    private func historyRow(_ entry: ShownoteLinkHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                ShownoteLinkHistorySystemOpener.open(entry.destination) {
                    guard let sourceURL = entry.sourceEpisodeURL else { return }
                    Task {
                        await ShownoteLinkHistoryStore.shared.record(
                            destination: entry.destination,
                            title: entry.title,
                            source: ShownoteLinkHistorySource(
                                episodeURL: sourceURL,
                                episodeTitle: entry.sourceEpisodeTitle
                            )
                        )
                        await reload()
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(entry.domain + (entry.safePath ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(entry.openedAt, format: .dateTime.month().day().year().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(entry.title)")
            .accessibilityHint("Opens the saved show-note link")

            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(entry.sourceEpisodeTitle.isEmpty ? "Episode no longer in the library" : entry.sourceEpisodeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let episodeURL = entry.sourceEpisodeURL {
                    NavigationLink(value: AppRoute.episode(episodeURL)) {
                        Text("Show Episode")
                            .font(.caption.weight(.semibold))
                    }
                    .accessibilityHint("Opens the source episode in your library")
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func reload() async {
        let configuration = await ShownoteLinkHistoryStore.shared.configuration()
        let currentEntries = await ShownoteLinkHistoryStore.shared.entries()
        isEnabled = configuration.isEnabled
        retention = configuration.retention
        entries = currentEntries
    }

    private func sectionTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct ShownoteLinkHistoryGroup: Identifiable {
    let date: Date
    let title: String
    let entries: [ShownoteLinkHistoryEntry]

    var id: Date { date }
}
