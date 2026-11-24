import SwiftUI

/// The small, shared audio profile used by the player settings sheet and the
/// podcast settings screen. It intentionally contains only controls backed by
/// the current playback processor.
struct AudioSpeedSettingsSnapshot: Equatable, Sendable {
    var playbackSpeed: Float
    var reduceSilenceGapsEnabled: Bool
    var silenceGapReductionLevel: SilenceGapReductionLevel
    var voiceEnhancementEnabled: Bool
    var equalizerPreset: EqualizerPreset

    init(settings: PodcastSettings) {
        playbackSpeed = settings.playbackSpeed ?? 1.0
        reduceSilenceGapsEnabled = settings.reduceSilenceGapsEnabled
        silenceGapReductionLevel = settings.silenceGapReductionLevel
        voiceEnhancementEnabled = settings.voiceEnhancementEnabled
        equalizerPreset = settings.equalizerPreset
    }

    func applying(to settings: PodcastSettings) {
        settings.playbackSpeed = playbackSpeed
        settings.reduceSilenceGapsEnabled = reduceSilenceGapsEnabled
        settings.silenceGapReductionLevel = silenceGapReductionLevel
        settings.voiceEnhancementEnabled = voiceEnhancementEnabled
        settings.equalizerPreset = equalizerPreset
    }

    func differs(from settings: PodcastSettings) -> Bool {
        self != Self(settings: settings)
    }
}

enum AudioSpeedSettingsScope: Equatable, Sendable {
    case appDefaults
    case podcastInherited
    case podcastOverride
    case currentPlayback

    var title: String {
        switch self {
        case .appDefaults: "App Defaults"
        case .podcastInherited: "This Podcast · Inherited"
        case .podcastOverride: "This Podcast · Override"
        case .currentPlayback: "Current Playback"
        }
    }

    var detail: String {
        switch self {
        case .appDefaults:
            "Used by podcasts that follow the app defaults."
        case .podcastInherited:
            "Following the current App Defaults."
        case .podcastOverride:
            "Applies only to this podcast; App Defaults stay unchanged."
        case .currentPlayback:
            "Applies to the episode playing now. Future episodes keep their saved settings."
        }
    }

    var isPodcastOverride: Bool {
        self == .podcastOverride
    }
}

/// A Form section rather than a nested Form so the same controls can be used
/// in the full podcast settings screen and in the player's compact settings
/// destination.
struct AudioSpeedSettingsSection: View {
    @Bindable private var settings: PodcastSettings

    let inheritedSettings: PodcastSettings?
    let scope: AudioSpeedSettingsScope
    let isEditable: Bool
    let onChange: () -> Void
    let onResetToDefault: (() -> Void)?
    let onEnableOverride: (() -> Void)?

    init(
        settings: PodcastSettings,
        inheritedSettings: PodcastSettings? = nil,
        scope: AudioSpeedSettingsScope,
        isEditable: Bool = true,
        onChange: @escaping () -> Void,
        onResetToDefault: (() -> Void)? = nil,
        onEnableOverride: (() -> Void)? = nil
    ) {
        _settings = Bindable(settings)
        self.inheritedSettings = inheritedSettings
        self.scope = scope
        self.isEditable = isEditable
        self.onChange = onChange
        self.onResetToDefault = onResetToDefault
        self.onEnableOverride = onEnableOverride
    }

    private var matchesInheritedAudioProfile: Bool {
        guard let inheritedSettings else { return false }
        return AudioSpeedSettingsSnapshot(settings: settings)
            == AudioSpeedSettingsSnapshot(settings: inheritedSettings)
    }

    var body: some View {
        Section {
            scopeRow

            LabeledContent {
                HStack(spacing: 8) {
                    Text((settings.playbackSpeed ?? 1.0).formatted(.number.precision(.fractionLength(0...1))) + "x")
                        .monospacedDigit()

                    Stepper(
                        "",
                        value: Binding(
                            get: { settings.playbackSpeed ?? 1.0 },
                            set: {
                                settings.playbackSpeed = $0
                                onChange()
                            }
                        ),
                        in: 0.5...3.0,
                        step: 0.1
                    )
                    .labelsHidden()
                }
            } label: {
                AudioSpeedControlLabel(
                    title: "Playback speed",
                    detail: "Used when a new playback item starts."
                )
            }
            .disabled(isEditable == false)

            Toggle(
                isOn: Binding(
                    get: { settings.reduceSilenceGapsEnabled },
                    set: {
                        settings.reduceSilenceGapsEnabled = $0
                        onChange()
                    }
                )
            ) {
                AudioSpeedControlLabel(
                    title: "Shorten pauses",
                    detail: "Reduce sustained quiet sections during playback."
                )
            }
            .disabled(isEditable == false)

            if settings.reduceSilenceGapsEnabled {
                Picker(
                    selection: Binding(
                        get: { settings.silenceGapReductionLevel },
                        set: {
                            settings.silenceGapReductionLevel = $0
                            onChange()
                        }
                    )
                ) {
                    ForEach(SilenceGapReductionLevel.allCases, id: \.self) { level in
                        Text(level.settingsLabel).tag(level)
                    }
                } label: {
                    AudioSpeedControlLabel(
                        title: "Pause reduction",
                        detail: "Gentle keeps more pauses; stronger levels shorten more."
                    )
                }
                .pickerStyle(.segmented)
                .disabled(isEditable == false)
            }

            Toggle(
                isOn: Binding(
                    get: { settings.voiceEnhancementEnabled },
                    set: {
                        settings.voiceEnhancementEnabled = $0
                        onChange()
                    }
                )
            ) {
                AudioSpeedControlLabel(
                    title: "Enhance voices",
                    detail: "Balance speech, reduce rumble, and control loud peaks."
                )
            }
            .disabled(isEditable == false)

            Picker(
                selection: Binding(
                    get: { settings.equalizerPreset },
                    set: {
                        settings.equalizerPreset = $0
                        onChange()
                    }
                )
            ) {
                ForEach(EqualizerPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            } label: {
                AudioSpeedControlLabel(
                    title: "EQ preset",
                    detail: "Flat bypasses equalization; other presets make gentle tonal changes."
                )
            }
            .pickerStyle(.menu)
            .disabled(isEditable == false)

            if scope.isPodcastOverride, let onResetToDefault {
                Button {
                    onResetToDefault()
                } label: {
                    Label("Reset Audio & Speed to App Defaults", systemImage: "arrow.counterclockwise")
                }
                .disabled(matchesInheritedAudioProfile)
            }

            if scope == .podcastInherited, let onEnableOverride {
                Button {
                    onEnableOverride()
                } label: {
                    Label("Use This Podcast's Settings", systemImage: "slider.horizontal.3")
                }
            }
        } header: {
            Text("Audio & Speed")
        } footer: {
            if isEditable {
                Text("Changes affect playback settings only. Queued episodes and downloaded files are not rewritten.")
            } else {
                Text("This podcast follows App Defaults. Enable podcast-specific settings to change this profile for the show.")
            }
        }
    }

    private var scopeRow: some View {
        HStack(spacing: 10) {
            Label(scope.title, systemImage: scope.isPodcastOverride ? "music.note.list" : "slider.horizontal.3")
                .font(.headline)

            Spacer(minLength: 8)

            if scope.isPodcastOverride {
                Text(matchesInheritedAudioProfile ? "Matches App Defaults" : "Custom")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(scope.detail)
    }
}

private struct AudioSpeedControlLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
    }
}
