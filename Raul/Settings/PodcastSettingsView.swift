import SwiftUI
import SwiftData
import UIKit
import BasicLogger

struct PodcastSettingsView: View {
    static let defaultSettingsFilter = #Predicate<PodcastSettings> { $0.title == "de.holgerkrupp.podbay.queue" }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SideloadingConfiguration.enabledKey) private var sideloadingEnabled = false

    let podcastID: PersistentIdentifier?
    let embedInNavigationStack: Bool

    @State private var useCustomSettings: Bool
    @State private var isApplyingSideloadingChange = false
    @State private var sideloadingAlertMessage: String?
    @State private var showSideloadingAlert = false
    @State private var hasPendingAutoDownloadReconciliation = false

    @Query(filter: defaultSettingsFilter) private var defaultSettings: [PodcastSettings]
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]
    @Query(sort: [SortDescriptor(\Playlist.sortIndex, order: .forward), SortDescriptor(\Playlist.title, order: .forward)]) private var playlists: [Playlist]

    init(podcastID: PersistentIdentifier?, modelContainer: ModelContainer, embedInNavigationStack: Bool = false) {
        self.podcastID = podcastID
        self.embedInNavigationStack = embedInNavigationStack
        _ = modelContainer
        self._useCustomSettings = State(initialValue: false)
    }

    init(podcast: Podcast?, modelContainer: ModelContainer, embedInNavigationStack: Bool = false) {
        self.podcastID = podcast?.persistentModelID
        self.embedInNavigationStack = embedInNavigationStack
        _ = modelContainer
        self._useCustomSettings = State(initialValue: podcast?.settings?.isEnabled == true)
    }

    private var podcast: Podcast? {
        guard let podcastID else { return nil }
        return context.model(for: podcastID) as? Podcast
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

    private var manualPlaylists: [Playlist] {
        Playlist.manualVisibleSorted(playlists)
    }

    private var viewIdentity: String {
        if let podcastID {
            return "podcast-settings-\(String(describing: podcastID))"
        }
        return "global-settings"
    }

    var body: some View {
        Group {
            if embedInNavigationStack {
                NavigationStack {
                    settingsList
                        .id(viewIdentity)
                }
            } else {
                settingsList
                    .id(viewIdentity)
            }
        }
        .onDisappear {
            applyAutomaticDownloadPolicyIfNeededOnClose()
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
                        sideloadingSection
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
            .toolbar {
                if embedInNavigationStack {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Dismiss settings")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .tint(.accent)
            .task {
                _ = ensureStandardSettings(in: context)
                _ = Playlist.ensureDefaultQueue(in: context)
                useCustomSettings = podcast?.settings?.isEnabled == true
            }
            .alert("Unable to Enable Sideloading", isPresented: $showSideloadingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(sideloadingAlertMessage ?? "Please try again.")
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
                        saveAndNotify(autoDownloadPolicyChanged: true)
                    }
                )
            ) {
                ForEach(Playlist.Position.settingsOptions, id: \.self) { position in
                    Text(position.settingsLabel).tag(position)
                }
            }

            Picker(
                "Default playlist for auto-add",
                selection: playlistSelectionBinding(for: settings)
            ) {
                if manualPlaylists.isEmpty {
                    Text(Playlist.defaultQueueDisplayName).tag("")
                }
                ForEach(manualPlaylists) { playlist in
                    Text(playlist.displayTitle).tag(playlist.id.uuidString)
                }
            }
            .disabled(settings.playnextPosition == .none)

            Text("Inbox keeps new episodes out of Up Next. Top and Bottom place them directly into your selected playlist.")
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

            Stepper(
                value: Binding(
                    get: { settings.archiveFileRetentionDaysClamped },
                    set: {
                        settings.archiveFileRetentionDays = $0
                        saveAndNotify()
                    }
                ),
                in: 0...180,
                step: 1
            ) {
                LabeledContent("Archive file retention") {
                    Text(settings.archiveRetentionSummary)
                }
            }

            Text("When an episode is archived, its downloaded file is kept for this duration before automatic cleanup can remove it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            NavigationLink {
                ChapterRuleSettingsDetailView(
                    settingsID: settings.persistentModelID,
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
            .simultaneousGesture(TapGesture().onEnded {
                CrashBreadcrumbs.shared.record("open_transcription_settings")
            })
        }
    }

    @ViewBuilder
    private func podcastCustomizationSection(settings: PodcastSettings) -> some View {
        Section("Playback") {


            Text("Inbox keeps new episodes out of Up Next. Top and Bottom place them directly into your selected playlist.")
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

            Stepper(
                value: Binding(
                    get: { settings.archiveFileRetentionDaysClamped },
                    set: {
                        settings.archiveFileRetentionDays = $0
                        saveAndNotify()
                    }
                ),
                in: 0...180,
                step: 1
            ) {
                LabeledContent("Archive file retention") {
                    Text(settings.archiveRetentionSummary)
                }
            }

            Text("When an episode is archived, its downloaded file is kept for this duration before automatic cleanup can remove it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Queue & Downloads") {
            Picker(
                "New episodes go to",
                selection: Binding(
                    get: { settings.playnextPosition },
                    set: {
                        settings.playnextPosition = $0
                        saveAndNotify(autoDownloadPolicyChanged: true)
                    }
                )
            ) {
                ForEach(Playlist.Position.settingsOptions, id: \.self) { position in
                    Text(position.settingsLabel).tag(position)
                }
            }

            Picker(
                "Default playlist for auto-add",
                selection: playlistSelectionBinding(for: settings)
            ) {
                if manualPlaylists.isEmpty {
                    Text(Playlist.defaultQueueDisplayName).tag("")
                }
                ForEach(manualPlaylists) { playlist in
                    Text(playlist.displayTitle).tag(playlist.id.uuidString)
                }
            }
            .disabled(settings.playnextPosition == .none)
            
            Toggle(
                "Auto-download unplayed episodes",
                isOn: Binding(
                    get: { settings.autoDownload },
                    set: {
                        settings.autoDownload = $0
                        if $0 {
                            if settings.autoDownloadEpisodeCount < 1 {
                                settings.autoDownloadEpisodeCount = 1
                            }
                            if settings.autoDownloadIncludesArchivedEpisodes == false {
                                settings.autoDownloadIncludesArchivedEpisodes = true
                            }
                            if settings.playnextPosition == .none {
                                settings.playnextPosition = .end
                            }
                            if settings.defaultPlaylistID == nil {
                                settings.defaultPlaylistID = resolvedPlaylistID(for: settings)
                            }
                        }
                        saveAndNotify(autoDownloadPolicyChanged: true)
                    }
                )
            )

            if settings.autoDownload {
                Stepper(
                    value: Binding(
                        get: { max(settings.autoDownloadEpisodeCount, 1) },
                        set: {
                            settings.autoDownloadEpisodeCount = max($0, 1)
                            saveAndNotify(autoDownloadPolicyChanged: true)
                        }
                    ),
                    in: 1...50,
                    step: 1
                ) {
                    LabeledContent("Keep available") {
                        Text("\(max(settings.autoDownloadEpisodeCount, 1))")
                            .monospacedDigit()
                    }
                }

                Picker(
                    "Selection",
                    selection: Binding(
                        get: { settings.autoDownloadSelection },
                        set: {
                            settings.autoDownloadSelection = $0
                            saveAndNotify(autoDownloadPolicyChanged: true)
                        }
                    )
                ) {
                    ForEach(AutoDownloadSelection.allCases, id: \.self) { selection in
                        Text(selection.settingsLabel).tag(selection)
                    }
                }

                Picker(
                    "Network",
                    selection: Binding(
                        get: { settings.autoDownloadNetworkMode },
                        set: {
                            settings.autoDownloadNetworkMode = $0
                            saveAndNotify(autoDownloadPolicyChanged: true)
                        }
                    )
                ) {
                    ForEach(AutoDownloadNetworkMode.allCases, id: \.self) { mode in
                        Text(mode.settingsLabel).tag(mode)
                    }
                }

                Toggle(
                    "Include back catalog episodes",
                    isOn: Binding(
                        get: { settings.autoDownloadIncludesArchivedEpisodes },
                        set: {
                            settings.autoDownloadIncludesArchivedEpisodes = $0
                            saveAndNotify(autoDownloadPolicyChanged: true)
                        }
                    )
                )
            }

            Text("Keeps only the selected oldest or newest unplayed episodes for this podcast downloaded on device. Optionally includes back catalog episodes from initial imports.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Podcast Sections") {
            NavigationLink {
                ChapterRuleSettingsDetailView(
                    settingsID: settings.persistentModelID,
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

    private var sideloadingSection: some View {
        Section("Sideloading") {
            Toggle(isOn: Binding(
                get: { sideloadingEnabled },
                set: { newValue in
                    handleSideloadingToggleChange(newValue)
                }
            )) {
                Label("Enable Sideloading", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(isApplyingSideloadingChange)

            Text("When enabled, the app watches the iCloud Drive > Up Next root and imports audio files from there when you open the iCloud Drive view. Turning it off stops discovery, but keeps existing sideloaded items in the database.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Supported formats include MP3, AAC, M4A, M4B, WAV, CAF, AIFF, and any other audio type AVFoundation can open.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isApplyingSideloadingChange {
                ProgressView("Setting up the iCloud folder...")
            }
        }
    }

    private var globalSettingsShortcutSection: some View {
        Section("Global Settings") {
            NavigationLink {
                GlobalPodcastSettingsScreen()
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

    private func playlistSelectionBinding(for settings: PodcastSettings) -> Binding<String> {
        Binding(
            get: {
                if let playlistID = resolvedPlaylistID(for: settings) {
                    return playlistID.uuidString
                }

                return manualPlaylists.first?.id.uuidString ?? ""
            },
            set: { newValue in
                settings.defaultPlaylistID = newValue.isEmpty ? nil : UUID(uuidString: newValue)
                saveAndNotify(autoDownloadPolicyChanged: true)
            }
        )
    }

    private func resolvedPlaylistID(for settings: PodcastSettings) -> UUID? {
        if let playlistID = settings.defaultPlaylistID,
           manualPlaylists.contains(where: { $0.id == playlistID }) {
            return playlistID
        }

        if let defaultPlaylist = manualPlaylists.first(where: { $0.title == Playlist.defaultQueueTitle }) {
            return defaultPlaylist.id
        }

        return manualPlaylists.first?.id
    }

    private func handleSideloadingToggleChange(_ newValue: Bool) {
        guard newValue != sideloadingEnabled else { return }
        guard isApplyingSideloadingChange == false else { return }

        isApplyingSideloadingChange = true
        sideloadingEnabled = newValue

        Task {
            do {
                try await SideloadingCoordinator.shared.syncEnabledState(newValue)
                await MainActor.run {
                    isApplyingSideloadingChange = false
                }
            } catch {
                await MainActor.run {
                    sideloadingEnabled = false
                    sideloadingAlertMessage = error.localizedDescription
                    showSideloadingAlert = true
                    isApplyingSideloadingChange = false
                }
            }
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
        markAutoDownloadPolicyReconciliationPending(trigger: "scope-toggle")
    }

    private func saveAndNotify() {
        saveAndNotify(autoDownloadPolicyChanged: false)
    }

    private func saveAndNotify(autoDownloadPolicyChanged: Bool) {
        context.saveIfNeeded()
        if let podcastFeed = podcast?.feed {
            BasicLogger.shared.log("[AutoDL] trigger/settings-changed scope=podcast feed=\(podcastFeed.absoluteString)")
        } else {
            BasicLogger.shared.log("[AutoDL] trigger/settings-changed scope=global")
        }
        postSettingsDidChange()
        if autoDownloadPolicyChanged {
            markAutoDownloadPolicyReconciliationPending(trigger: "settings-change")
        }
    }

    private func postSettingsDidChange() {
        NotificationCenter.default.post(name: .podcastSettingsDidChange, object: nil)
    }

    private func markAutoDownloadPolicyReconciliationPending(trigger: String) {
        hasPendingAutoDownloadReconciliation = true
        if let podcastFeed = podcast?.feed {
            BasicLogger.shared.log("[AutoDL] trigger/\(trigger) scope=podcast feed=\(podcastFeed.absoluteString) action=mark-pending-reconciliation")
        } else {
            BasicLogger.shared.log("[AutoDL] trigger/\(trigger) scope=global action=mark-pending-reconciliation")
        }
    }

    private func applyAutomaticDownloadPolicyIfNeededOnClose() {
        guard hasPendingAutoDownloadReconciliation else {
            if let podcastFeed = podcast?.feed {
                BasicLogger.shared.log("[AutoDL] trigger/settings-closed scope=podcast feed=\(podcastFeed.absoluteString) action=no-pending-reconciliation")
            } else {
                BasicLogger.shared.log("[AutoDL] trigger/settings-closed scope=global action=no-pending-reconciliation")
            }
            return
        }

        hasPendingAutoDownloadReconciliation = false

        if let podcastFeed = podcast?.feed {
            BasicLogger.shared.log("[AutoDL] trigger/settings-closed apply-policy scope=podcast feed=\(podcastFeed.absoluteString)")
            Task {
                await EpisodeActor(modelContainer: context.container).applyAutomaticDownloadPolicy(for: podcastFeed)
            }
            return
        }

        Task {
            let settingsActor = PodcastSettingsModelActor(modelContainer: context.container)
            let feeds = await settingsActor.podcastFeedsRequiringAutoDownloadReconciliation()
            guard feeds.isEmpty == false else { return }
            await MainActor.run {
                BasicLogger.shared.log("[AutoDL] trigger/settings-closed apply-policy scope=global feeds=\(feeds.count)")
            }
            let episodeActor = EpisodeActor(modelContainer: context.container)
            for feed in feeds {
                await MainActor.run {
                    BasicLogger.shared.log("[AutoDL] trigger/settings-closed apply-policy feed=\(feed.absoluteString)")
                }
                await episodeActor.applyAutomaticDownloadPolicy(for: feed)
            }
        }
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

struct SettingsHelpView: View {
    var body: some View {
        List {
            Section("Up Next Basics") {
                Text("Up Next is your single playback queue. Episodes in this list are what the player uses for \"what comes next.\"")
                Text("Inbox is your triage area for fresh episodes. Move important ones into Up Next or archive what you do not want to keep visible.")
                Text("When an episode finishes, continuous playback can automatically start the next item from Up Next.")
            }

            Section("Queue Behavior") {
                Text("New episodes can be placed at the front, end, or not added automatically, depending on your settings.")
                Text("The currently playing episode is kept pinned at the top while playback is active.")
                Text("You can reorder Up Next manually, move an episode to the end, or remove episodes from the queue.")
            }

            Section("Chapter Skip Keywords") {
                Text("Chapter rules let you skip recurring segments like intro, ads, or outro.")
                Text("Rules are checked against chapter titles and can use operators like contains, starts with, or ends with.")
                Text("Use global rules for all podcasts, or enable custom settings for one podcast when it needs its own behavior.")
            }

            Section("Siri & Shortcuts Intents") {
                Text("Available actions now include: Resume Playback, Pause Playback, Bookmark This, Skip Forward, Skip Backward, Play Up Next, Play Next Up Next Episode, Move Current To End, and Remove Current From Up Next.")
                Text("In Apple Shortcuts, search for Up Next to add these actions to personal automations.")
                Text("For best results, keep a few Siri phrases short and specific, like \"Play Up Next\" or \"Bookmark this in Up Next.\"")
            }

            Section("Accessibility") {
                Text("VoiceOver and Voice Control use the same control names you see in the player, queue, and transcript views.")
                Text("For captions, open Transcript from an episode or the player. When a feed has no transcript, you can generate one on-device.")
                Text("Reduced Motion, Larger Text, and Differentiate Without Color are supported. If you use high contrast settings, the app increases secondary text contrast in now-playing interfaces.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Using Up Next")
        .navigationBarTitleDisplayMode(.inline)
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

private struct ChapterRuleSettingsDetailView: View {
    @Environment(\.modelContext) private var context

    let settingsID: PersistentIdentifier

    let isEditable: Bool
    let source: SettingsSource
    let readOnlyMessage: String?
    let onChange: () -> Void

    private var settings: PodcastSettings? {
        context.model(for: settingsID) as? PodcastSettings
    }

    var body: some View {
        if let settings {
            ChapterRuleSettingsLoadedView(
                settings: settings,
                isEditable: isEditable,
                source: source,
                readOnlyMessage: readOnlyMessage,
                onChange: onChange
            )
        } else {
            List {
                Section {
                    Text("These chapter rules could not be loaded.")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Chapter Rules")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ChapterRuleSettingsLoadedView: View {
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
                            PodcastSpecificSettingsScreen(podcastID: podcast.persistentModelID)
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
        guard let podcastFeed = podcast.feed else { return }
        Task {
            await EpisodeActor(modelContainer: context.container).applyAutomaticDownloadPolicy(for: podcastFeed)
        }
    }
}

@MainActor
private func ensureStandardSettings(in context: ModelContext) -> PodcastSettings {
    let defaultPlaylist = Playlist.ensureDefaultQueue(in: context)
    let defaultSettingsTitle = "de.holgerkrupp.podbay.queue"
    var descriptor = FetchDescriptor<PodcastSettings>(
        predicate: #Predicate { $0.title == defaultSettingsTitle }
    )
    descriptor.fetchLimit = 1

    if let result = try? context.fetch(descriptor).first {
        if result.defaultPlaylistID == nil {
            result.defaultPlaylistID = defaultPlaylist.id
            context.saveIfNeeded()
        }
        return result
    }

    let settings = PodcastSettings()
    settings.title = defaultSettingsTitle
    settings.defaultPlaylistID = defaultPlaylist.id
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
        settings.autoDownload = globalSettings.autoDownload
        settings.autoDownloadEpisodeCount = globalSettings.autoDownloadEpisodeCount
        settings.autoDownloadSelection = globalSettings.autoDownloadSelection
        settings.autoDownloadNetworkMode = globalSettings.autoDownloadNetworkMode
        settings.autoDownloadIncludesArchivedEpisodes = globalSettings.autoDownloadIncludesArchivedEpisodes
        settings.defaultPlaylistID = globalSettings.defaultPlaylistID
        settings.archiveFileRetentionDays = globalSettings.archiveFileRetentionDays
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

private struct GlobalPodcastSettingsScreen: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        PodcastSettingsView(podcastID: nil, modelContainer: context.container)
    }
}

private struct PodcastSpecificSettingsScreen: View {
    @Environment(\.modelContext) private var context

    let podcastID: PersistentIdentifier

    var body: some View {
        PodcastSettingsView(podcastID: podcastID, modelContainer: context.container)
    }
}

private extension PodcastSettings {
    var queueAndPlaybackSummary: String {
        "\(playnextPosition.settingsLabel) • \(playbackSpeed.formattedPlaybackSpeed) • \(archiveRetentionSummary) • \(autoDownloadSummary)"
    }

    var autoDownloadSummary: String {
        guard autoDownload else { return "Auto-download off" }

        let count = max(autoDownloadEpisodeCount, 1)
        let episodeLabel = count == 1 ? "episode" : "episodes"
        let backCatalogSuffix = autoDownloadIncludesArchivedEpisodes ? ", incl. back catalog" : ", inbox/history only"
        return "\(autoDownloadSelection.settingsLabel), \(count) \(episodeLabel), \(autoDownloadNetworkMode.settingsLabel)\(backCatalogSuffix)"
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

    var archiveFileRetentionDaysClamped: Int {
        max(archiveFileRetentionDays, 0)
    }

    var archiveRetentionSummary: String {
        if archiveFileRetentionDaysClamped == 1 {
            return "1 day"
        }
        return "\(archiveFileRetentionDaysClamped) days"
    }
}

private extension AutoDownloadSelection {
    var settingsLabel: String {
        switch self {
        case .newestUnplayed:
            "Newest unplayed"
        case .oldestUnplayed:
            "Oldest unplayed"
        }
    }
}

private extension AutoDownloadNetworkMode {
    var settingsLabel: String {
        switch self {
        case .wifiAndCellular:
            "Wi-Fi + Cellular"
        case .wifiOnly:
            "Wi-Fi only"
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
            "Top of Playlist"
        case .end:
            "Bottom of Playlist"
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
