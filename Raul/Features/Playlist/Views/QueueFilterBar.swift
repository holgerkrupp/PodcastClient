import SwiftUI

/// Temporary, scene-local filters for an ordered playlist projection.
/// Filtering never changes playlist membership, order, or playback context.
struct QueueFilterBar: View {
    let projection: QueueProjection
    @Binding var filterState: QueueFilterState
    @State private var showingCustomDuration = false
    @State private var customDurationText = ""

    private var filteredProjection: QueueProjection {
        projection.filtered(using: filterState)
    }

    private var podcastTitles: [String] {
        Array(Set(projection.entries.map(\.podcastTitle).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var categories: [String] {
        Array(Set(projection.entries.flatMap(\.categories)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterButton(
                        "All",
                        systemImage: "line.3.horizontal.decrease.circle",
                        isSelected: filterState.isFiltering == false
                    ) {
                        filterState.clear()
                    }

                    filterButton(
                        "In Progress",
                        systemImage: "play.circle",
                        isSelected: filterState.inProgress
                    ) {
                        filterState.inProgress.toggle()
                    }

                    filterButton(
                        "Short",
                        systemImage: "timer",
                        isSelected: filterState.isShortSelected
                    ) {
                        if filterState.isShortSelected {
                            filterState.maximumDurationMinutes = nil
                        } else {
                            filterState.maximumDurationMinutes = QueueFilterState.defaultShortDurationMinutes
                            filterState.minimumDurationMinutes = nil
                        }
                    }

                    filterButton(
                        "Downloaded",
                        systemImage: "arrow.down.circle",
                        isSelected: filterState.downloadedOnly
                    ) {
                        filterState.downloadedOnly.toggle()
                    }

                    moreFiltersMenu
                }
                .padding(.horizontal)
            }

            Text(
                QueueProjectionFormatting.countAndDuration(
                    count: filteredProjection.count,
                    duration: filteredProjection.knownRemainingDuration,
                    hasUnknownDuration: filteredProjection.hasUnknownDuration
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .accessibilityLabel(summaryAccessibilityLabel)
        }
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .sheet(isPresented: $showingCustomDuration) {
            customDurationSheet
        }
    }

    private var summaryAccessibilityLabel: String {
        let count = filteredProjection.count
        if let duration = QueueProjectionFormatting.duration(filteredProjection.knownRemainingDuration) {
            return "\(count) episodes, \(duration) remaining"
        }
        return "\(count) episodes"
    }

    private var moreFiltersMenu: some View {
        Menu {
            durationMenu

            if podcastTitles.isEmpty == false {
                Menu("Podcast") {
                    Button {
                        filterState.podcastTitle = nil
                    } label: {
                        filterChoiceLabel("All podcasts", isSelected: filterState.podcastTitle == nil)
                    }
                    ForEach(podcastTitles, id: \.self) { title in
                        Button {
                            filterState.podcastTitle = title
                        } label: {
                            filterChoiceLabel(title, isSelected: filterState.podcastTitle == title)
                        }
                    }
                }
            }

            if categories.isEmpty == false {
                Menu("Category") {
                    Button {
                        filterState.category = nil
                    } label: {
                        filterChoiceLabel("All categories", isSelected: filterState.category == nil)
                    }
                    ForEach(categories, id: \.self) { category in
                        Button {
                            filterState.category = category
                        } label: {
                            filterChoiceLabel(category, isSelected: filterState.category == category)
                        }
                    }
                }
            }

            if filterState.isFiltering {
                Divider()
                Button("Clear Filters", role: .destructive) {
                    filterState.clear()
                }
            }
        } label: {
            Label {
                if filterState.activeFilterCount > 0 {
                    Text("More (\(filterState.activeFilterCount))")
                } else {
                    Text("More Filters")
                }
            } icon: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(filterState.activeFilterCount > 0
            ? "More filters, \(filterState.activeFilterCount) active"
            : "More filters")
    }

    @ViewBuilder
    private var durationMenu: some View {
        Menu("Duration") {
            durationChoice("Any duration", minimum: nil, maximum: nil)
            durationChoice("Under 15 minutes", minimum: nil, maximum: 15)
            durationChoice("Under 30 minutes", minimum: nil, maximum: 30)
            durationChoice("Under 60 minutes", minimum: nil, maximum: 60)
            durationChoice("15–30 minutes", minimum: 15, maximum: 30)
            Divider()
            Button("Custom maximum…") {
                customDurationText = filterState.maximumDurationMinutes.map(Self.formatMinutes) ?? ""
                showingCustomDuration = true
            }
        }
    }

    private var customDurationSheet: some View {
        NavigationStack {
            Form {
                TextField("Maximum minutes", text: $customDurationText)
                Text("Episodes without a known duration are excluded from duration filters.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Custom Duration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCustomDuration = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let value = Double(customDurationText.replacingOccurrences(of: ",", with: "."))
                        if let value, value > 0, value.isFinite {
                            filterState.minimumDurationMinutes = nil
                            filterState.maximumDurationMinutes = value
                        }
                        showingCustomDuration = false
                    }
                    .disabled(Double(customDurationText.replacingOccurrences(of: ",", with: ".")) ?? 0 <= 0)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private static func formatMinutes(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private func durationChoice(
        _ title: String,
        minimum: Double?,
        maximum: Double?
    ) -> some View {
        Button {
            filterState.minimumDurationMinutes = minimum
            filterState.maximumDurationMinutes = maximum
        } label: {
            filterChoiceLabel(
                title,
                isSelected: filterState.minimumDurationMinutes == minimum
                    && filterState.maximumDurationMinutes == maximum
            )
        }
    }

    private func filterButton(
        _ title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isSelected ? .accentColor : .secondary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func filterChoiceLabel(_ title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            if isSelected {
                Spacer()
                Image(systemName: "checkmark")
            }
        }
    }
}
