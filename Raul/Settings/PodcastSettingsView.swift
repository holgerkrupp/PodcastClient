import SwiftUI
import SwiftData

struct PodcastSettingsView: View {
    static let defaultSettingsFilter = #Predicate<PodcastSettings> { $0.title == "de.holgerkrupp.podbay.queue" }

    @Environment(\.modelContext) private var context

    let podcast: Podcast?

    @State private var useCustomSettings: Bool
    @State private var actor: PodcastSettingsModelActor

    @Query(filter: defaultSettingsFilter) private var defaultSettings: [PodcastSettings]
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]

    init(podcast: Podcast?, modelContainer: ModelContainer) {
        self.podcast = podcast
        self._useCustomSettings = State(initialValue: podcast?.settings?.isEnabled == true)
        self._actor = State(initialValue: PodcastSettingsModelActor(modelContainer: modelContainer))
    }

    private var globalSettings: PodcastSettings? {
        defaultSettings.first
    }

    private var activeCustomSettings: PodcastSettings? {
        guard let podcast, podcast.settings?.isEnabled == true else { return nil }
        return podcast.settings
    }

    private var editableSettings: PodcastSettings? {
        if podcast == nil {
            return globalSettings
        }
        return activeCustomSettings
    }

    private var effectiveSettings: PodcastSettings? {
        activeCustomSettings ?? globalSettings
    }

    private var editableSettingsSource: SettingsSource {
        if podcast == nil {
            return .global
        }
        return useCustomSettings ? .podcast : .global
    }

    private var podcastsUsingCustomSettings: [Podcast] {
        podcasts.filter { $0.settings?.isEnabled == true }
    }

    private var podcastsUsingGlobalSettings: [Podcast] {
        podcasts.filter { $0.settings?.isEnabled != true }
    }

    var body: some View {
        NavigationStack {
            List {
                contextSection

                if podcast != nil {
                    scopeSection
                }

                if let effectiveSettings, let globalSettings {
                    appliedBehaviorSection(effectiveSettings: effectiveSettings, globalSettings: globalSettings)
                } else {
                    Section {
                        ProgressView("Loading settings…")
                    }
                }

                if let editableSettings {
                    editableSections(settings: editableSettings)
                } else if podcast != nil {
                    inheritanceSection
                }

                if let globalSettings {
                    appWideSection(settings: globalSettings)
                }

                if podcast == nil {
                    globalPodcastSections
                }

                integrationsSection
                maintenanceSection
#if DEBUG
                debugSection
#endif

                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(podcast == nil ? "Settings" : "Podcast Settings")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .tint(.accent)
            .task {
                await actor.ensureStandardSettingsExists()
                useCustomSettings = podcast?.settings?.isEnabled == true
            }
        }
    }

    private var contextSection: some View {
        Section {
            if let podcast {
                HStack(spacing: 14) {
                    CoverImageView(podcast: podcast)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(podcast.title)
                            .font(.headline)
                            .lineLimit(2)

                        Text(useCustomSettings ? "Using podcast-specific settings" : "Following global defaults")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    SettingsSourceBadge(source: editableSettingsSource)
                }

                Text("This screen shows which settings currently affect this podcast, and which controls stay global for the whole app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Global Defaults", systemImage: "slider.horizontal.3")
                        .font(.headline)

                    Text("These values apply across the app unless a podcast is switched to custom settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var scopeSection: some View {
        Section("Scope") {
            Picker("Settings Mode", selection: $useCustomSettings) {
                Text("Global").tag(false)
                Text("Custom").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(podcast?.feed == nil)
            .onChange(of: useCustomSettings) { _, newValue in
                handleCustomSettingsToggle(newValue)
            }

            Text(useCustomSettings
                 ? "Custom mode creates a podcast-owned copy of queue placement, playback speed, and chapter rules. Later global edits no longer flow into this podcast until you switch back to Global."
                 : "Global mode keeps this podcast on the shared defaults. Switch to Custom only when this show should behave differently.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func appliedBehaviorSection(effectiveSettings: PodcastSettings, globalSettings: PodcastSettings) -> some View {
        Section("Applied Right Now") {
            SettingsBehaviorRow(
                title: "Queue placement for new episodes",
                value: effectiveSettings.playnextPosition.settingsLabel,
                detail: "Used when new episodes are processed after refresh.",
                source: editableSettingsSource
            )

            SettingsBehaviorRow(
                title: "Playback speed",
                value: effectiveSettings.playbackSpeed.formattedPlaybackSpeed,
                detail: "Loaded when playback starts. Changing speed in the player saves back to this active scope.",
                source: editableSettingsSource
            )

            SettingsBehaviorRow(
                title: "Chapter skip rules",
                value: effectiveSettings.autoSkipKeywords.settingsSummary,
                detail: "Applied when chapter data is loaded for an episode. Existing manual chapter choices are not reset automatically.",
                source: editableSettingsSource
            )

            SettingsBehaviorRow(
                title: "Continuous playback",
                value: globalSettings.getContinuousPlay.enabledLabel,
                detail: "Checked when an episode finishes to decide whether the next queue item should start.",
                source: .global
            )

            SettingsBehaviorRow(
                title: "In-app scrubbing",
                value: globalSettings.enableInAppSlider.enabledLabel,
                detail: "Controls whether the Now Playing progress slider can be dragged inside the app.",
                source: .global
            )

            SettingsBehaviorRow(
                title: "Lock screen scrubbing",
                value: globalSettings.enableLockscreenSlider.enabledLabel,
                detail: "Controls the system playback-position command used by the lock screen and remote controls.",
                source: .global
            )
        }
    }

    @ViewBuilder
    private func editableSections(settings: PodcastSettings) -> some View {
        Section("Queue") {
            Picker("New episodes go to", selection: binding(for: \.playnextPosition, in: settings)) {
                ForEach(Playlist.Position.settingsOptions, id: \.self) { position in
                    Text(position.settingsLabel).tag(position)
                }
            }

            Text("Inbox keeps new episodes out of Up Next. Top and Bottom place them directly into the queue.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Playback") {
            Stepper(
                value: Binding(
                    get: { settings.playbackSpeed ?? 1.0 },
                    set: {
                        settings.playbackSpeed = $0
                        saveAndNotify()
                    }
                ),
                in: 0.5...3.0,
                step: 0.1
            ) {
                LabeledContent("Default speed") {
                    Text(settings.playbackSpeed.formattedPlaybackSpeed)
                        .monospacedDigit()
                }
            }

            Text("This speed is used when playback starts. The player speed control also writes back here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Chapter Skip Rules") {
            if settings.autoSkipKeywords.isEmpty {
                Text("No chapter rules yet. Add a rule to automatically skip matching chapter titles.")
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(settings.autoSkipKeywords.enumerated()), id: \.offset) { index, rule in
                VStack(alignment: .leading, spacing: 12) {
                    TextField(
                        "Keyword or phrase",
                        text: Binding(
                            get: { rule.keyWord ?? "" },
                            set: {
                                settings.autoSkipKeywords[index].keyWord = $0
                                saveAndNotify()
                            }
                        )
                    )

                    HStack {
                        Picker(
                            "Match",
                            selection: Binding(
                                get: { rule.keyOperator },
                                set: {
                                    settings.autoSkipKeywords[index].keyOperator = $0
                                    saveAndNotify()
                                }
                            )
                        ) {
                            ForEach(Operator.allCases, id: \.self) { op in
                                Text(op.settingsLabel).tag(op)
                            }
                        }
                        .pickerStyle(.menu)

                        Spacer()

                        Button("Remove", role: .destructive) {
                            settings.autoSkipKeywords.remove(at: index)
                            saveAndNotify()
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Button {
                settings.autoSkipKeywords.append(skipKey())
                saveAndNotify()
            } label: {
                Label("Add Rule", systemImage: "plus")
            }

            Text("Rules compare against chapter titles and mark matching chapters to be skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var inheritanceSection: some View {
        Section("Podcast Overrides") {
            ContentUnavailableView(
                "Using Global Defaults",
                systemImage: "arrow.triangle.branch",
                description: Text("Enable Custom to give this podcast its own queue placement, playback speed, and chapter rules.")
            )
        }
    }

    @ViewBuilder
    private func appWideSection(settings: PodcastSettings) -> some View {
        Section("App-Wide Controls") {
            Toggle("Continuous playback", isOn: binding(for: \.getContinuousPlay, in: settings))
            Toggle("Now Playing slider", isOn: binding(for: \.enableInAppSlider, in: settings))
            Toggle("Lock screen slider", isOn: binding(for: \.enableLockscreenSlider, in: settings))

            NavigationLink {
                TranscriptionSettingsView()
            } label: {
                Label("Transcriptions", systemImage: "waveform.and.mic")
            }

            Text("These settings are global only. They affect every podcast and cannot be customized per show.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var integrationsSection: some View {
        Section("Notifications") {
            NotificationSettingsView()
        }
    }

    @ViewBuilder
    private var globalPodcastSections: some View {
        Section("Podcasts With Custom Settings") {
            if podcastsUsingCustomSettings.isEmpty {
                Text("No podcasts are using custom settings yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(podcastsUsingCustomSettings) { podcast in
                    NavigationLink {
                        PodcastSettingsView(podcast: podcast, modelContainer: context.container)
                    } label: {
                        PodcastSettingsPodcastRow(
                            podcast: podcast,
                            detail: "Open podcast-specific settings"
                        )
                    }
                }
            }
        }

        Section("Enable Custom Settings") {
            if podcastsUsingGlobalSettings.isEmpty {
                Text("All podcasts already use custom settings.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(podcastsUsingGlobalSettings) { podcast in
                    HStack(spacing: 12) {
                        PodcastSettingsPodcastRow(
                            podcast: podcast,
                            detail: "Currently following global defaults"
                        )

                        Spacer()

                        Button("Use Custom") {
                            enableCustomSettings(for: podcast)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(podcast.feed == nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var debugSection: some View {
        Section("Debug") {
            Button("Remove Duplicate Podcasts") {
                Task {
                    await SubscriptionActor(modelContainer: context.container).cleanupDuplicates()
                }
            }
        }
    }
    
    private var maintenanceSection: some View {
        Section("Maintenance") {
            NavigationLink {
                StorageManagementView(modelContainer: context.container)
            } label: {
                Text("Storage Management")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            CreatedByView()
                .frame(maxWidth: .infinity)
        }
    }

    private func handleCustomSettingsToggle(_ newValue: Bool) {
        guard let feed = podcast?.feed else { return }

        Task {
            if newValue {
                await actor.enableCustomSettings(for: feed)
            } else {
                await actor.disableCustomSettings(for: feed)
            }

            await MainActor.run {
                useCustomSettings = podcast?.settings?.isEnabled == true
                postSettingsDidChange()
            }
        }
    }

    private func enableCustomSettings(for podcast: Podcast) {
        guard let feed = podcast.feed else { return }

        Task {
            await actor.enableCustomSettings(for: feed)

            await MainActor.run {
                postSettingsDidChange()
            }
        }
    }

    private func binding<Value>(for keyPath: ReferenceWritableKeyPath<PodcastSettings, Value>, in settings: PodcastSettings) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: {
                settings[keyPath: keyPath] = $0
                saveAndNotify()
            }
        )
    }

    private func saveAndNotify() {
        context.saveIfNeeded()
        postSettingsDidChange()
    }

    private func postSettingsDidChange() {
        NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
    }
}

private enum SettingsSource {
    case global
    case podcast

    var title: String {
        switch self {
        case .global:
            "Global"
        case .podcast:
            "Podcast"
        }
    }

    var tint: Color {
        switch self {
        case .global:
            .secondary
        case .podcast:
            .accentColor
        }
    }
}

private struct SettingsSourceBadge: View {
    let source: SettingsSource

    var body: some View {
        Text(source.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(source.tint)
            .background(source.tint.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct SettingsBehaviorRow: View {
    let title: String
    let value: String
    let detail: String
    let source: SettingsSource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Text(title)
                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.trailing)

                    SettingsSourceBadge(source: source)
                }
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct PodcastSettingsPodcastRow: View {
    let podcast: Podcast
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(podcast: podcast)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private extension Playlist.Position {
    static let settingsOptions: [Playlist.Position] = [.none, .front, .end]

    var settingsLabel: String {
        switch self {
        case .none:
            "Inbox"
        case .front:
            "Top of Up Next"
        case .end:
            "Bottom of Up Next"
        }
    }
}

private extension Operator {
    var settingsLabel: String {
        switch self {
        case .Is:
            "Is exactly"
        case .Contains:
            "Contains"
        case .StartsWith:
            "Starts with"
        case .EndsWith:
            "Ends with"
        }
    }
}

private extension Optional where Wrapped == Float {
    var formattedPlaybackSpeed: String {
        String(format: "%.1fx", self ?? 1.0)
    }
}

private extension Bool {
    var enabledLabel: String {
        self ? "On" : "Off"
    }
}

private extension Array where Element == skipKey {
    var settingsSummary: String {
        let validRuleCount = self.reduce(into: 0) { count, rule in
            let keyword = rule.keyWord?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if keyword.isEmpty == false {
                count += 1
            }
        }

        switch validRuleCount {
        case 0:
            return "No rules"
        case 1:
            return "1 rule"
        default:
            return "\(validRuleCount) rules"
        }
    }
}

#if DEBUG
struct PodcastSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            let podcastWithCustomSettings = Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!)
            PodcastSettingsView(podcast: podcastWithCustomSettings, modelContainer: ModelContainerManager.shared.container)
                .previewDisplayName("Podcast with Custom Settings")

            let podcastWithoutCustomSettings = Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!)
            PodcastSettingsView(podcast: podcastWithoutCustomSettings, modelContainer: ModelContainerManager.shared.container)
                .previewDisplayName("Podcast with Global Settings")
        }
    }
}
#endif
