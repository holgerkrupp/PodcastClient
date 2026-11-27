//
//  PlayerShellIslands.swift
//  Raul
//
//  Narrow observation islands for the full player (#520). Each view here reads
//  only the observable state it renders, so a playback tick, a live transcript
//  cue, a sleep-timer countdown or a chapter-skip suggestion invalidates that
//  island instead of the whole PlayerControllView hierarchy.
//

import SwiftUI
import SwiftData
import TipKit
import os

// MARK: - Interaction signposts

/// User interactions measured from tap to first visible response (#520, #493).
enum PlayerInteraction: String, Sendable {
    case transcriptShow = "transcript-show"
    case transcriptHide = "transcript-hide"
    case contentTab = "content-tab"
    case fullTranscript = "full-transcript"
    case playPause = "play-pause"
    case speedSheet = "speed-sheet"
    case sleepSheet = "sleep-sheet"
    case settingsSheet = "settings-sheet"
}

extension PlayerOpeningPerformance {
    @MainActor private static var interactionIDs: [PlayerInteraction: OSSignpostID] = [:]

    /// Begins a "Player interaction" interval and gives the user priority over
    /// optional background work through `SystemPressureGate`. Constant time:
    /// call it directly from a button action.
    @MainActor
    static func beginInteraction(_ interaction: PlayerInteraction) {
        SystemPressureGate.shared.noteUserInteraction()
        if let previous = interactionIDs[interaction] {
            os_signpost(.end, log: log, name: "Player interaction", signpostID: previous,
                        "%{public}s superseded", interaction.rawValue)
        }
        let id = OSSignpostID(log: log)
        interactionIDs[interaction] = id
        os_signpost(.begin, log: log, name: "Player interaction", signpostID: id,
                    "%{public}s", interaction.rawValue)
    }

    /// Ends the interval when the requested surface became visible.
    @MainActor
    static func interactionVisible(_ interaction: PlayerInteraction) {
        guard let id = interactionIDs.removeValue(forKey: interaction) else { return }
        os_signpost(.end, log: log, name: "Player interaction", signpostID: id,
                    "%{public}s visible", interaction.rawValue)
    }

    /// Records an interaction that has no measured surface, such as a repeated
    /// seek, so optional work keeps deferring while the user is active.
    @MainActor
    static func noteInteraction() {
        SystemPressureGate.shared.noteUserInteraction()
    }
}

// MARK: - Presentation snapshot

/// Value facts the player shell needs for its buttons. Derived from prepared
/// inputs only: the off-main `PlayerContentAvailabilityModelActor` result
/// (cached by episode URL and invalidated on reference/chapter notifications)
/// and the in-memory downloaded-file inventory. Building it never touches the
/// file system or a SwiftData relationship.
struct PlayerPresentationSnapshot: Equatable, Sendable {
    let episodeURL: URL?
    let hasLocalMedia: Bool
    let hasTranscript: Bool

    /// The inline transcript toggle appears when there is something to show or
    /// a local file live captions could be generated from.
    var showsTranscriptToggle: Bool { hasTranscript || hasLocalMedia }

    static func make(
        episodeURL: URL?,
        isSideLoaded: Bool,
        localFile: URL?,
        downloadedFiles: Set<URL>,
        availability: PlayerContentAvailability?,
        isLiveTranscriptActive: Bool
    ) -> PlayerPresentationSnapshot {
        PlayerPresentationSnapshot(
            episodeURL: episodeURL,
            hasLocalMedia: hasLocalMedia(
                isSideLoaded: isSideLoaded,
                localFile: localFile,
                downloadedFiles: downloadedFiles
            ),
            hasTranscript: isLiveTranscriptActive
                || availabilityHasTranscript(availability, episodeURL: episodeURL)
        )
    }

    static func hasLocalMedia(
        isSideLoaded: Bool,
        localFile: URL?,
        downloadedFiles: Set<URL>
    ) -> Bool {
        guard let localFile else { return false }
        // Side-loaded media is the imported file itself and lives outside the
        // monitored download folder.
        if isSideLoaded { return localFile.isFileURL }
        return downloadedFiles.contains(localFile.standardizedFileURL)
    }

    /// A missing or stale availability result is "unknown", reported as no
    /// transcript until the background query answers for this episode.
    static func availabilityHasTranscript(
        _ availability: PlayerContentAvailability?,
        episodeURL: URL?
    ) -> Bool {
        guard let availability, let episodeURL, availability.episodeURL == episodeURL else {
            return false
        }
        return availability.hasTranscript || availability.hasSavedLiveTranscript
    }
}

// MARK: - Media

/// Artwork/video identity. Chapter artwork changes rebuild only this view.
struct PlayerMediaSurface: View {
    let episodeURL: URL?
    private var player: Player { .shared }

    var body: some View {
        PlayerMediaView(
            player: player.videoPlayer,
            isVideo: player.currentPlaybackIsVideo,
            artworkImage: player.currentArtworkImage
        )
        .id("\(episodeURL?.absoluteString ?? "")-\(player.currentPlaybackIsVideo)")
    }
}

// MARK: - Chapter row

/// The chapter row: transcript toggle (left), chapter controls or the
/// generation action (centre), playback settings (right), plus Skip Ad.
struct PlayerChapterControlSlot: View {
    @Environment(\.modelContext) private var modelContext

    let episode: Episode
    @Binding var showTranscripts: Bool
    let showsInlineTranscript: Bool
    let showsTranscriptOverHero: Bool
    let contentAvailability: PlayerContentAvailability?
    var hidesTranscriptGeneration = false
    let onOpenPlaybackSettings: () -> Void

    private var player: Player { .shared }

    var body: some View {
        let hasPlaybackChapters = PlayerChapterRowPolicy.hasSelectablePlaybackChapters(
            for: episode.url,
            activeEpisodeURL: player.currentEpisodeURL,
            chapterCount: player.chapters?.count,
            firstStart: player.chapters?.first?.start
        )
        let hasChapterSelectionUI = PlayerChapterRowPolicy.hasChapterSelectionUI(
            availability: contentAvailability,
            episodeURL: episode.url,
            hasPlaybackChapters: hasPlaybackChapters
        )

        ZStack {
            if hasChapterSelectionUI {
                PlayerChapterView(hasChapterSelectionUI: hasChapterSelectionUI)
                    .padding(.horizontal, 16)
            } else {
                PlayerChapterRowGenerationSlot(
                    episodeURL: episode.url,
                    availability: contentAvailability,
                    hasPlaybackChapters: hasPlaybackChapters,
                    hidesChapterGeneration: showsInlineTranscript && showTranscripts,
                    hidesTranscriptGeneration: hidesTranscriptGeneration,
                    modelContainer: modelContext.container
                )
            }

            PlayerSkipAdvertisementButton()

            HStack(spacing: 0) {
                PlayerTranscriptToggleSlot(
                    episode: episode,
                    showTranscripts: $showTranscripts,
                    showsInlineTranscript: showsInlineTranscript,
                    showsTranscriptOverHero: showsTranscriptOverHero,
                    contentAvailability: contentAvailability
                )

                Spacer(minLength: 0)
                playbackSettingsButton
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .zIndex(3)
    }

    private var playbackSettingsButton: some View {
        Button {
            PlayerOpeningPerformance.beginInteraction(.settingsSheet)
            onOpenPlaybackSettings()
        } label: {
            Label("Playback Settings", systemImage: "gear")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .accessibilityLabel("Playback Settings")
        .accessibilityHint("Opens settings related to playback")
        .help("Adjust playback options for this podcast")
        .accessibilityInputLabels([Text("Playback settings"), Text("Player settings")])
    }
}

/// Generation progress updates invalidate only this slot.
private struct PlayerChapterRowGenerationSlot: View {
    let episodeURL: URL?
    let availability: PlayerContentAvailability?
    let hasPlaybackChapters: Bool
    let hidesChapterGeneration: Bool
    let hidesTranscriptGeneration: Bool
    let modelContainer: ModelContainer

    private var aiGeneration: EpisodeAIGenerationCoordinator { .shared }

    var body: some View {
        if let action = generationAction, shouldShow(action) {
            EpisodeAIGenerationControl(
                action: action,
                state: episodeURL.flatMap { aiGeneration.state(for: $0) },
                start: { action in
                    guard let episodeURL else { return }
                    aiGeneration.start(action: action, episodeURL: episodeURL, modelContainer: modelContainer)
                },
                cancel: {
                    guard let episodeURL else { return }
                    Task { await aiGeneration.cancel(episodeURL: episodeURL) }
                }
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var generationAction: EpisodeAIGenerationAction? {
        // Until the background availability check resolves, no absence is confirmed.
        guard let availability, availability.episodeURL == episodeURL else { return nil }
        return PlayerChapterRowPolicy.generationAction(
            availability: availability,
            hasPlaybackChapters: hasPlaybackChapters,
            aiAvailable: AppleIntelligenceAvailability.isAvailable
        )
    }

    private func shouldShow(_ action: EpisodeAIGenerationAction) -> Bool {
        if action == .generateChapters { return !hidesChapterGeneration }
        return !hidesTranscriptGeneration
    }
}

/// Detected-advertisement state depends on the playback position, so only
/// this button follows playback ticks.
private struct PlayerSkipAdvertisementButton: View {
    private var player: Player { .shared }

    var body: some View {
        if player.canSkipCurrentAdvertisement {
            Button {
                Task { await player.skipCurrentAdvertisement() }
            } label: {
                Label("Skip Ad", systemImage: "forward.end.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.glass(.clear))
            .accessibilityLabel("Skip advertisement")
            .accessibilityHint("Seeks to the end of the detected advertisement")
        }
    }
}

/// Owns the only live-transcript observation the shell needs (`isActive`,
/// which reads phase and episode URL, never cues) plus the download inventory.
private struct PlayerTranscriptToggleSlot: View {
    let episode: Episode
    @Binding var showTranscripts: Bool
    let showsInlineTranscript: Bool
    let showsTranscriptOverHero: Bool
    let contentAvailability: PlayerContentAvailability?

    var body: some View {
        if showsInlineTranscript, snapshot.showsTranscriptToggle {
            transcriptVisibilityButton
        } else {
            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }

    private var snapshot: PlayerPresentationSnapshot {
        PlayerPresentationSnapshot.make(
            episodeURL: episode.url,
            isSideLoaded: episode.source == .sideLoaded,
            localFile: episode.localFile,
            downloadedFiles: DownloadedFilesManager.shared.downloadedFiles,
            availability: contentAvailability,
            isLiveTranscriptActive: LiveTranscriptController.shared.isActive(for: episode)
        )
    }

    private var transcriptVisibilityButton: some View {
        Button {
            // Phase A only: flip local presentation state. The overlay host
            // prepares its content asynchronously after it is on screen.
            PlayerOpeningPerformance.beginInteraction(showTranscripts ? .transcriptHide : .transcriptShow)
            showTranscripts.toggle()
        } label: {
            if showTranscripts {
                Image("custom.quote.bubble.slash")
            } else {
                Image(systemName: "quote.bubble")
            }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .accessibilityLabel(showTranscripts ? "Hide inline transcript" : "Show inline transcript")
        .accessibilityHint(accessibilityHint)
        .help(showTranscripts ? "Hide the transcript" : "Show the transcript")
        .accessibilityInputLabels([Text(showTranscripts ? "Hide captions" : "Show captions"), Text("Transcript")])
    }

    private var accessibilityHint: String {
        if showsTranscriptOverHero {
            return showTranscripts
                ? "Removes the transcript panel from the artwork"
                : "Shows the transcript panel over the artwork"
        }
        return showTranscripts
            ? "Removes the transcript panel below the artwork"
            : "Shows the transcript panel below the artwork"
    }
}

// MARK: - Chapter-skip suggestion

/// Recognition history changes on every manual chapter skip; only this tip
/// observes it.
struct ChapterSkipSuggestionIsland: View {
    let episode: Episode
    let onCreateRule: (Podcast, ChapterSkipRuleSuggestion) -> Void

    private var recognition: ChapterSkipRecognition { .shared }

    var body: some View {
        if let suggestion = recognition.suggestion(for: episode.podcast?.feed),
           let podcast = episode.podcast {
            let tip = ChapterSkipSuggestionTip(suggestion: suggestion)
            TipView(tip, arrowEdge: .none) { action in
                if action.id == "create-rule" {
                    onCreateRule(podcast, suggestion)
                } else if action.id == "not-now" {
                    recognition.dismiss(suggestion)
                    tip.invalidate(reason: .tipClosed)
                }
            }
            .padding(.horizontal)
            .task(id: tip.id) {
                for await status in tip.statusUpdates {
                    guard case .invalidated(let reason) = status else { continue }
                    if reason == .tipClosed || reason == .displayCountExceeded {
                        recognition.dismiss(suggestion)
                    }
                    break
                }
            }
        }
    }
}

// MARK: - Skip protection

struct PlayerSkipProtectionUndoIsland: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var player: Player { .shared }

    var body: some View {
        if let undo = player.skipProtectionUndo {
            Button {
                Task {
                    await player.undoSkipProtection(undoID: undo.id)
                }
            } label: {
                Label("Undo skip", systemImage: "arrow.uturn.backward.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Returns to \(undo.episodeTitle) at the previous playback position")
            .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Targeted episode revisions

/// Bumps a local revision when `Episode.refresh` announces a change for this
/// episode, so only the view that applies it re-reads the episode — instead of
/// the whole player reading `episode.refresh` at its root (#520).
struct EpisodeReferenceRevisionModifier: ViewModifier {
    let episodeURL: URL?
    var includesChapterData = false
    @Binding var revision: Int

    func body(content: Content) -> some View {
        content
            .onReceive(
                // Background actors toggle `Episode.refresh`, so this can post off-main.
                NotificationCenter.default.publisher(for: .episodeReferencesDidChange)
                    .receive(on: DispatchQueue.main)
            ) { notification in
                guard PlayerReferenceNotificationPolicy.matches(
                    changedURL: notification.userInfo?[EpisodeReferenceNotificationKey.episodeURL] as? URL,
                    episodeURL: episodeURL
                ) else { return }
                revision &+= 1
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .playerChapterDataDidChange)
                    .receive(on: DispatchQueue.main)
            ) { _ in
                guard includesChapterData else { return }
                revision &+= 1
            }
    }
}

enum PlayerReferenceNotificationPolicy {
    /// Notifications without an episode URL are broad and apply to every view.
    static func matches(changedURL: URL?, episodeURL: URL?) -> Bool {
        guard let changedURL else { return true }
        return changedURL == episodeURL
    }
}
