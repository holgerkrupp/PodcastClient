import SwiftUI

struct AutoDownloadEpisodeFilterEditor: View {
    let settings: PodcastSettings
    let onSave: () -> Void

    @State private var includeKeywords = ""
    @State private var excludeKeywords = ""
    @State private var minimumDuration = ""
    @State private var maximumDuration = ""
    @State private var maximumAgeDays = ""
    @State private var episodeTypes: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Episode Eligibility")
                .font(.headline)
#if os(iOS)
            TextField("Include keywords (comma-separated)", text: $includeKeywords)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Exclude keywords (comma-separated)", text: $excludeKeywords)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#else
            TextField("Include keywords (comma-separated)", text: $includeKeywords)
                .autocorrectionDisabled()
            TextField("Exclude keywords (comma-separated)", text: $excludeKeywords)
                .autocorrectionDisabled()
#endif
            TextField("Minimum duration in seconds", text: $minimumDuration)
            TextField("Maximum duration in seconds", text: $maximumDuration)
            TextField("Only episodes from the last N days", text: $maximumAgeDays)

            ForEach(["full", "trailer", "bonus"], id: \.self) { type in
                Toggle("\(type.capitalized) episodes", isOn: Binding(
                    get: { episodeTypes.contains(type) },
                    set: { enabled in
                        if enabled { episodeTypes.insert(type) } else { episodeTypes.remove(type) }
                    }
                ))
            }

            Button("Save Episode Filters", action: save)
                .accessibilityHint("Applies these filters to automatic downloads")

            Text(filterSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Unknown duration, publication date, or episode type passes that check. Manual downloads always work. Playlist auto-downloads inherit these rules; matching rules never change queue membership or remove files already downloaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { load() }
    }

    private func load() {
        let filter = settings.autoDownloadFilter
        includeKeywords = filter.includedKeywords.joined(separator: ", ")
        excludeKeywords = filter.excludedKeywords.joined(separator: ", ")
        minimumDuration = filter.minimumDurationSeconds.map { String(Int($0)) } ?? ""
        maximumDuration = filter.maximumDurationSeconds.map { String(Int($0)) } ?? ""
        maximumAgeDays = filter.maximumPublicationAgeDays.map(String.init) ?? ""
        episodeTypes = filter.episodeTypes
    }

    private func save() {
        let minimum = Double(minimumDuration).flatMap { $0 >= 0 ? $0 : nil }
        let maximum = Double(maximumDuration).flatMap { $0 >= 0 ? $0 : nil }
        if let minimum, let maximum, minimum > maximum { return }
        let age = Int(maximumAgeDays).flatMap { $0 > 0 ? $0 : nil }
        settings.autoDownloadFilter = AutoDownloadEpisodeFilter(
            includedKeywords: keywords(from: includeKeywords),
            excludedKeywords: keywords(from: excludeKeywords),
            minimumDurationSeconds: minimum,
            maximumDurationSeconds: maximum,
            maximumPublicationAgeDays: age,
            episodeTypes: episodeTypes
        )
        onSave()
    }

    private func keywords(from text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private var filterSummary: String {
        var activeRules: [String] = []
        if includeKeywords.isEmpty == false { activeRules.append("include: \(includeKeywords)") }
        if excludeKeywords.isEmpty == false { activeRules.append("exclude: \(excludeKeywords)") }
        if minimumDuration.isEmpty == false { activeRules.append("at least \(minimumDuration)s") }
        if maximumDuration.isEmpty == false { activeRules.append("at most \(maximumDuration)s") }
        if maximumAgeDays.isEmpty == false { activeRules.append("published within \(maximumAgeDays) days") }
        if episodeTypes.isEmpty == false { activeRules.append("type: \(episodeTypes.sorted().joined(separator: ", "))") }
        return activeRules.isEmpty ? "No extra eligibility filters are active." : "Automatic downloads use: \(activeRules.joined(separator: " · "))."
    }
}
