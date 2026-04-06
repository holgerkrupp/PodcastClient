import SwiftUI
import SwiftData
import UIKit

struct PodcastSettingsView: View {
    static let defaultSettingsFilter = #Predicate<PodcastSettings> { $0.title == "de.holgerkrupp.podbay.queue" }

    @Environment(\.modelContext) private var context

    let podcast: Podcast?
    let embedInNavigationStack: Bool

    @State private var useCustomSettings: Bool

    @Query(filter: defaultSettingsFilter) private var defaultSettings: [PodcastSettings]
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]

    init(podcast: Podcast?, modelContainer: ModelContainer, embedInNavigationStack: Bool = false) {
        self.podcast = podcast
        self.embedInNavigationStack = embedInNavigationStack
        _ = modelContainer
        self._useCustomSettings = State(initialValue: podcast?.settings?.isEnabled == true)
    }

    private var globalSettings: PodcastSettings? {
        defaultSettings.first
    }

    private var activeCustomSettings: PodcastSettings? {
        guard let podcast, podcast.settings?.isEnabled == true else { return nil }
        return podcast.settings
    }

    private var effectiveSettings: PodcastSettings? {
        activeCustomSettings ?? globalSettings
    }

    private var resolvedSettingsSource: SettingsSource {
        if podcast == nil {
            return .global
        }
        return activeCustomSettings == nil ? .global : .podcast
    }

    private var isPodcastCustomSettingsActive: Bool {
        podcast != nil && activeCustomSettings != nil
    }

    private var podcastsUsingCustomSettings: [Podcast] {
        podcasts.filter { $0.settings?.isEnabled == true }
    }

    private var podcastsUsingGlobalSettings: [Podcast] {
        podcasts.filter { $0.settings?.isEnabled != true }
    }

    var body: some View {
        if embedInNavigationStack {
            NavigationStack {
                settingsList
            }
        } else {
            settingsList
        }
    }

    private var settingsList: some View {
            List {
                contextSection

                if podcast != nil {
                    scopeSection
                }

                if let effectiveSettings, let globalSettings {
                    /*
                    appliedBehaviorSection(effectiveSettings: effectiveSettings, globalSettings: globalSettings)
                    */

                    if podcast == nil {
                        globalDefaultsSection(settings: effectiveSettings)
                        appControlsSection(settings: globalSettings)
                        transcriptionSection(settings: globalSettings)
                        podcastManagementSection
                        integrationsSection
                        maintenanceSection
                        helpSection
#if DEBUG
                        debugSection
#endif
                        aboutSection
                    } else {
                        if isPodcastCustomSettingsActive {
                            podcastCustomizationSection(settings: effectiveSettings)
                        }
                        globalSettingsShortcutSection
                    }
                } else {
                    Section {
                        ProgressView("Loading settings…")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(podcast == nil ? "Settings" : "Podcast Settings")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .tint(.accent)
            .task {
                _ = ensureStandardSettings(in: context)
                useCustomSettings = podcast?.settings?.isEnabled == true
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

                        Text(isPodcastCustomSettingsActive ? "Using podcast-specific settings" : "Following global defaults")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    SettingsSourceBadge(source: resolvedSettingsSource)
                }

                Text("This screen focuses on what is unique to this podcast. App-wide controls stay grouped under Global Settings.")
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
            Toggle(
                "Use podcast-specific settings",
                isOn: Binding(
                    get: { useCustomSettings },
                    set: { newValue in
                        handleCustomSettingsToggle(newValue)
                    }
                )
            )
            .disabled(podcast?.feed == nil)

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
                source: resolvedSettingsSource
            )

            SettingsBehaviorRow(
                title: "Playback speed",
                value: effectiveSettings.playbackSpeed.formattedPlaybackSpeed,
                detail: "Loaded when playback starts. Changing speed in the player saves back to this active scope.",
                source: resolvedSettingsSource
            )

            SettingsBehaviorRow(
                title: "Chapter skip rules",
                value: effectiveSettings.autoSkipKeywords.settingsSummary,
                detail: "Applied when chapter data is loaded for an episode. Existing manual chapter choices are not reset automatically.",
                source: resolvedSettingsSource
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
    private func globalDefaultsSection(settings: PodcastSettings) -> some View {
        Section("Playback & Queue") {
            Picker(
                "New episodes go to",
                selection: Binding(
                    get: { settings.playnextPosition },
                    set: {
                        settings.playnextPosition = $0
                        saveAndNotify()
                    }
                )
            ) {
                ForEach(Playlist.Position.settingsOptions, id: \.self) { position in
                    Text(position.settingsLabel).tag(position)
                }
            }

            Text("Inbox keeps new episodes out of Up Next. Top and Bottom place them directly into the queue.")
                .font(.caption)
                .foregroundStyle(.secondary)

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

            NavigationLink {
                ChapterRuleSettingsDetailView(
                    settings: settings,
                    isEditable: true,
                    source: .global,
                    readOnlyMessage: nil,
                    onChange: saveAndNotify
                )
            } label: {
                SettingsNavigationRow(
                    title: "Chapter Skip Rules",
                    summary: settings.autoSkipKeywords.settingsSummary,
                    detail: "Manage the app-wide rules that automatically skip matching chapters.",
                    systemImage: "text.line.first.and.arrowtriangle.forward"
                )
            }
        }
    }

    @ViewBuilder
    private func appControlsSection(settings: PodcastSettings) -> some View {
        Section("Player Controls") {
            Toggle(
                "Continuous playback",
                isOn: Binding(
                    get: { settings.getContinuousPlay },
                    set: {
                        settings.getContinuousPlay = $0
                        saveAndNotify()
                    }
                )
            )

            Text("When enabled, the next queue item starts automatically after an episode finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(
                "Now Playing slider",
                isOn: Binding(
                    get: { settings.enableInAppSlider },
                    set: {
                        settings.enableInAppSlider = $0
                        saveAndNotify()
                    }
                )
            )

            Toggle(
                "Lock screen slider",
                isOn: Binding(
                    get: { settings.enableLockscreenSlider },
                    set: {
                        settings.enableLockscreenSlider = $0
                        saveAndNotify()
                    }
                )
            )

            Text("These control whether playback scrubbing is available inside the app and through system playback controls.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func transcriptionSection(settings: PodcastSettings) -> some View {
        Section("Transcriptions") {
            NavigationLink {
                DeferredView {
                    TranscriptionSettingsView()
                }
            } label: {
                SettingsNavigationRow(
                    title: "On-Device Transcriptions",
                    summary: settings.transcriptionSummary,
                    detail: "Manage automatic on-device transcription, installed speech models, and recent transcription history.",
                    systemImage: "waveform.and.mic"
                )
            }
        }
    }

    @ViewBuilder
    private func podcastCustomizationSection(settings: PodcastSettings) -> some View {
        Section("Podcast Sections") {
            NavigationLink {
                QueuePlaybackSettingsDetailView(
                    settings: settings,
                    isEditable: isPodcastCustomSettingsActive,
                    source: resolvedSettingsSource,
                    readOnlyMessage: isPodcastCustomSettingsActive ? nil : "These values currently come from the global defaults. Switch this podcast to Custom to edit them just for this show.",
                    onChange: saveAndNotify
                )
            } label: {
                SettingsNavigationRow(
                    title: "Queue & Playback",
                    summary: settings.queueAndPlaybackSummary,
                    detail: isPodcastCustomSettingsActive
                        ? "Podcast-specific placement and default speed."
                        : "Showing the global defaults currently applied to this podcast.",
                    systemImage: "speedometer",
                    source: resolvedSettingsSource
                )
            }

            NavigationLink {
                ChapterRuleSettingsDetailView(
                    settings: settings,
                    isEditable: isPodcastCustomSettingsActive,
                    source: resolvedSettingsSource,
                    readOnlyMessage: isPodcastCustomSettingsActive ? nil : "These chapter rules currently come from the global defaults. Switch this podcast to Custom to edit them just for this show.",
                    onChange: saveAndNotify
                )
            } label: {
                SettingsNavigationRow(
                    title: "Chapter Skip Rules",
                    summary: settings.autoSkipKeywords.settingsSummary,
                    detail: isPodcastCustomSettingsActive
                        ? "Manage the chapter rules for this podcast."
                        : "Showing the global chapter rules currently applied to this podcast.",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    source: resolvedSettingsSource
                )
            }
        }
    }

    private var globalSettingsShortcutSection: some View {
        Section("Global Settings") {
            NavigationLink {
                PodcastSettingsView(podcast: nil, modelContainer: context.container)
            } label: {
                SettingsNavigationRow(
                    title: "Open Global Settings",
                    summary: "App controls, transcriptions, notifications, storage, and podcast override management.",
                    detail: "Use the global settings screen for anything that should affect the whole app instead of just this one podcast.",
                    systemImage: "globe"
                )
            }
        }
    }

    private var podcastManagementSection: some View {
        Section("Podcasts") {
            NavigationLink {
                PodcastOverridesManagementView(modelContainer: context.container)
            } label: {
                SettingsNavigationRow(
                    title: "Podcast Overrides",
                    summary: "\(podcastsUsingCustomSettings.count) custom, \(podcastsUsingGlobalSettings.count) following global defaults",
                    detail: "See which podcasts have their own settings and enable custom settings for more shows.",
                    systemImage: "music.note.list"
                )
            }
        }
    }

    private var integrationsSection: some View {
        Section("Integrations") {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                SettingsNavigationRow(
                    title: "Notifications",
                    summary: "Open iOS Settings",
                    detail: "Jump straight to the system Settings app to manage notification permissions and delivery.",
                    systemImage: "bell.badge"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var maintenanceSection: some View {
        Section("Maintenance") {
            NavigationLink {
                StorageManagementView(modelContainer: context.container)
            } label: {
                SettingsNavigationRow(
                    title: "Storage Management",
                    summary: "Downloaded files and local cache",
                    detail: "Review what is stored on device and clean up space when needed.",
                    systemImage: "externaldrive"
                )
            }
        }
    }

    private var helpSection: some View {
        Section("Help") {
            NavigationLink {
                SettingsHelpView()
            } label: {
                SettingsNavigationRow(
                    title: "Using Up Next",
                    summary: "Queue model, inbox workflow, chapter skip keywords, and Siri/Shortcuts intents",
                    detail: "Open a complete guide for how playback flow works and how to automate it.",
                    systemImage: "questionmark.circle"
                )
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

    private var aboutSection: some View {
        Section {
            CreatedByView()
                .frame(maxWidth: .infinity)
        }
    }

    private func handleCustomSettingsToggle(_ newValue: Bool) {
        guard let podcast else { return }
        useCustomSettings = newValue

        if newValue {
            enableCustomSettings(for: podcast, in: context)
        } else {
            disableCustomSettings(for: podcast, in: context)
        }
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

private struct SettingsNavigationRow: View {
    let title: String
    let summary: String
    let detail: String
    let systemImage: String
    var source: SettingsSource? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.accent)
                .frame(width: 24, height: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .foregroundStyle(.primary)

                    if let source {
                        SettingsSourceBadge(source: source)
                    }
                }

                Text(summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 2)
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

private struct SettingsReadOnlyNotice: View {
    let message: String
    let source: SettingsSource

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(source.tint)
                Text(source == .global ? "Following Global Defaults" : "Using Podcast Defaults")
                    .font(.subheadline.weight(.semibold))
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct QueuePlaybackSettingsDetailView: View {
    @Bindable var settings: PodcastSettings

    let isEditable: Bool
    let source: SettingsSource
    let readOnlyMessage: String?
    let onChange: () -> Void

    var body: some View {
        List {
            if let readOnlyMessage, isEditable == false {
                Section {
                    SettingsReadOnlyNotice(message: readOnlyMessage, source: source)
                }
            }

            Section("Queue") {
                if isEditable {
                    Picker(
                        "New episodes go to",
                        selection: Binding(
                            get: { settings.playnextPosition },
                            set: {
                                settings.playnextPosition = $0
                                onChange()
                            }
                        )
                    ) {
                        ForEach(Playlist.Position.settingsOptions, id: \.self) { position in
                            Text(position.settingsLabel).tag(position)
                        }
                    }
                } else {
                    LabeledContent("New episodes go to") {
                        Text(settings.playnextPosition.settingsLabel)
                    }
                }

                Text("Inbox keeps new episodes out of Up Next. Top and Bottom place them directly into the queue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Playback") {
                if isEditable {
                    Stepper(
                        value: Binding(
                            get: { settings.playbackSpeed ?? 1.0 },
                            set: {
                                settings.playbackSpeed = $0
                                onChange()
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
                } else {
                    LabeledContent("Default speed") {
                        Text(settings.playbackSpeed.formattedPlaybackSpeed)
                            .monospacedDigit()
                    }
                }

                Text("This speed is used when playback starts. The player speed control also writes back here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Queue & Playback")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ChapterRuleSettingsDetailView: View {
    @Bindable var settings: PodcastSettings

    let isEditable: Bool
    let source: SettingsSource
    let readOnlyMessage: String?
    let onChange: () -> Void

    var body: some View {
        List {
            if let readOnlyMessage, isEditable == false {
                Section {
                    SettingsReadOnlyNotice(message: readOnlyMessage, source: source)
                }
            }

            Section("How It Works") {
                ChapterRuleOverview(source: source)
            }

            Section {
                if settings.autoSkipKeywords.isEmpty {
                    ChapterRuleEmptyState(isEditable: isEditable)
                        .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                } else if isEditable {
                    editableRuleCards
                } else {
                    readOnlyRuleCards
                }
            } header: {
                HStack {
                    Text("Rules")
                    Spacer()
                    Text(settings.autoSkipKeywords.settingsSummary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                }
            } footer: {
                Text("Rules compare against chapter titles and mark matching chapters to be skipped.")
            }

            if isEditable {
                Section {
                    Button {
                        settings.autoSkipKeywords.append(skipKey())
                        onChange()
                    } label: {
                        Label("Add Rule", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chapter Rules")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var editableRuleCards: some View {
        ForEach(Array(settings.autoSkipKeywords.enumerated()), id: \.offset) { index, rule in
            ChapterRuleEditorCard(
                ruleNumber: index + 1,
                rule: rule,
                keyword: Binding(
                    get: { rule.keyWord ?? "" },
                    set: {
                        settings.autoSkipKeywords[index].keyWord = $0
                        onChange()
                    }
                ),
                keyOperator: Binding(
                    get: { rule.keyOperator },
                    set: {
                        settings.autoSkipKeywords[index].keyOperator = $0
                        onChange()
                    }
                ),
                onRemove: {
                    settings.autoSkipKeywords.remove(at: index)
                    onChange()
                }
            )
            .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var readOnlyRuleCards: some View {
        ForEach(Array(settings.autoSkipKeywords.enumerated()), id: \.offset) { index, rule in
            ChapterRuleReadOnlyCard(ruleNumber: index + 1, rule: rule, source: source)
                .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
        }
    }
}

private struct ChapterRuleOverview: View {
    let source: SettingsSource

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .foregroundStyle(source.tint)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic Chapter Filtering")
                        .font(.subheadline.weight(.semibold))

                    Text("Matching chapter titles will be marked to skip as soon as chapter data is loaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Use rules for repeated segments like ads, intros, and credits. Each rule checks the chapter title with a match style such as contains or starts with.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct ChapterRuleEmptyState: View {
    let isEditable: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text(isEditable ? "No rules yet" : "No rules applied")
                    .font(.subheadline.weight(.semibold))

                Text(
                    isEditable
                    ? "Add a rule to skip recurring chapters like ads, intros, or credits."
                    : "This settings scope does not currently skip any chapters automatically."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

private struct ChapterRuleEditorCard: View {
    let ruleNumber: Int
    let rule: skipKey
    let keyword: Binding<String>
    let keyOperator: Binding<Operator>
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Label("Rule \(ruleNumber)", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if rule.hasKeyword == false {
                    Text("Needs keyword")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.14))
                        .clipShape(Capsule())
                }

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove rule \(ruleNumber)")
                .accessibilityHint("Deletes this chapter skip rule")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Match style")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Match style", selection: keyOperator) {
                    ForEach(Operator.allCases, id: \.self) { op in
                        Text(op.settingsLabel).tag(op)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Keyword or phrase")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("e.g. ad break, intro, credits", text: keyword, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            }

            Text(rule.previewDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct ChapterRuleReadOnlyCard: View {
    let ruleNumber: Int
    let rule: skipKey
    let source: SettingsSource

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Rule \(ruleNumber)", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(source.tint)

                Spacer()
                SettingsSourceBadge(source: source)
            }

            Text(rule.previewDescription)
                .font(.body)
                .foregroundStyle(.primary)

            if rule.hasKeyword == false {
                Text("This rule has no keyword yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct AppControlsSettingsDetailView: View {
    @Bindable var settings: PodcastSettings

    let onChange: () -> Void

    var body: some View {
        List {
            Section("Playback Continuation") {
                Toggle(
                    "Continuous playback",
                    isOn: Binding(
                        get: { settings.getContinuousPlay },
                        set: {
                            settings.getContinuousPlay = $0
                            onChange()
                        }
                    )
                )

                Text("When enabled, the next queue item starts automatically after an episode finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Player Controls") {
                Toggle(
                    "Now Playing slider",
                    isOn: Binding(
                        get: { settings.enableInAppSlider },
                        set: {
                            settings.enableInAppSlider = $0
                            onChange()
                        }
                    )
                )

                Toggle(
                    "Lock screen slider",
                    isOn: Binding(
                        get: { settings.enableLockscreenSlider },
                        set: {
                            settings.enableLockscreenSlider = $0
                            onChange()
                        }
                    )
                )

                Text("These control whether playback scrubbing is available inside the app and through system playback controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("App Controls")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PodcastOverridesManagementView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \Podcast.title) private var podcasts: [Podcast]

    init(modelContainer: ModelContainer) {
        _ = modelContainer
    }

    private var podcastsUsingCustomSettings: [Podcast] {
        podcasts.filter { $0.settings?.isEnabled == true }
    }

    private var podcastsUsingGlobalSettings: [Podcast] {
        podcasts.filter { $0.settings?.isEnabled != true }
    }

    var body: some View {
        List {
            Section("Custom Settings") {
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

            Section("Using Global Defaults") {
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
                                enableCustomSettingsFromList(for: podcast)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(podcast.feed == nil)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Podcast Overrides")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func enableCustomSettingsFromList(for podcast: Podcast) {
        enableCustomSettings(for: podcast, in: context)
    }
}

@MainActor
private func ensureStandardSettings(in context: ModelContext) -> PodcastSettings {
    let defaultSettingsTitle = "de.holgerkrupp.podbay.queue"
    var descriptor = FetchDescriptor<PodcastSettings>(
        predicate: #Predicate { $0.title == defaultSettingsTitle }
    )
    descriptor.fetchLimit = 1

    if let result = try? context.fetch(descriptor).first {
        return result
    }

    let settings = PodcastSettings()
    settings.title = defaultSettingsTitle
    context.insert(settings)
    context.saveIfNeeded()
    return settings
}

@MainActor
private func enableCustomSettings(for podcast: Podcast, in context: ModelContext) {
    let globalSettings = ensureStandardSettings(in: context)

    if let settings = podcast.settings {
        settings.isEnabled = true
        settings.podcast = podcast
    } else {
        let settings = PodcastSettings(podcast: podcast)
        settings.isEnabled = true
        settings.playbackSpeed = globalSettings.playbackSpeed
        settings.playnextPosition = globalSettings.playnextPosition
        settings.autoSkipKeywords = globalSettings.autoSkipKeywords
        context.insert(settings)
        podcast.settings = settings
    }

    context.saveIfNeeded()
    NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
}

@MainActor
private func disableCustomSettings(for podcast: Podcast, in context: ModelContext) {
    podcast.settings?.isEnabled = false
    context.saveIfNeeded()
    NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
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

private struct DeferredView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

private extension PodcastSettings {
    var queueAndPlaybackSummary: String {
        "\(playnextPosition.settingsLabel) • \(playbackSpeed.formattedPlaybackSpeed)"
    }

    var appControlsSummary: String {
        let playback = getContinuousPlay ? "Continuous play on" : "Continuous play off"
        let sliders = enableInAppSlider || enableLockscreenSlider ? "scrubbing available" : "scrubbing off"
        return "\(playback) • \(sliders)"
    }

    var transcriptionSummary: String {
        guard enableAutomaticOnDeviceTranscriptions else {
            return "Automatic local fallback off"
        }

        if limitAutomaticOnDeviceTranscriptionsToCharging {
            return "Automatic fallback only while charging"
        }

        return "Automatic local fallback on"
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

    var matchPreviewLabel: String {
        switch self {
        case .Is:
            "is exactly"
        case .Contains:
            "contains"
        case .StartsWith:
            "starts with"
        case .EndsWith:
            "ends with"
        }
    }
}

private extension skipKey {
    var trimmedKeyword: String {
        keyWord?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var hasKeyword: Bool {
        trimmedKeyword.isEmpty == false
    }

    var previewDescription: String {
        let visibleKeyword = hasKeyword ? "\"\(trimmedKeyword)\"" : "a keyword"
        return "Skip chapters when the title \(keyOperator.matchPreviewLabel) \(visibleKeyword)."
    }

    var ruleDescription: String {
        let visibleKeyword = hasKeyword ? trimmedKeyword : "Empty keyword"
        return "\(keyOperator.settingsLabel): \(visibleKeyword)"
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
