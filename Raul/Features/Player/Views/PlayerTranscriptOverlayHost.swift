//
//  PlayerTranscriptOverlayHost.swift
//  Raul
//
//  Inline transcript overlay shown over/below the player artwork. It owns all
//  transcript observation so live-cue updates invalidate only this view, not
//  the whole PlayerControllView (#520).
//
//  The overlay is display-only (#477): generation, download, retry and cancel
//  controls live in the full Transcript view, reached through the
//  "Open full transcript" button in the bottom-right corner.
//
//  Showing it is two-phase (#495, #520): the first frame paints the surface and
//  a lightweight status with zero transcript work. The prepared transcript
//  snapshot or the live value cues arrive asynchronously and update only this
//  host. Hiding unmounts it and never waits for Speech, cancellation or saves.
//

import SwiftUI
import SwiftData
import os

struct PlayerTranscriptOverlayHost: View {
    let episode: Episode
    /// Called with `true` when the full transcript should open following
    /// playback, `false` when it opens at the top.
    let onOpenFullTranscript: (_ followPlayback: Bool) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var presenter = InlineTranscriptPresenter()
    @Bindable private var player = Player.shared

    init(episode: Episode, onOpenFullTranscript: @escaping (_ followPlayback: Bool) -> Void) {
        self.episode = episode
        self.onOpenFullTranscript = onOpenFullTranscript
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                openFullTranscriptButton
            }
            .onAppear {
                PlayerOpeningPerformance.event("Transcript overlay surface visible")
                SystemPressureGate.shared.noteUserInteraction()
            }
            .task(id: episode.url) {
                presenter.show(episodeURL: episode.url, container: modelContext.container)
            }
            .onDisappear { presenter.stop() }
            .onReceive(
                NotificationCenter.default.publisher(for: .episodeReferencesDidChange)
                    .receive(on: DispatchQueue.main)
            ) { notification in
                presenter.referencesChanged(
                    episodeURL: notification.userInfo?[EpisodeReferenceNotificationKey.episodeURL] as? URL
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        switch presenter.state {
        case .caption(let snapshot):
            TranscriptView(
                snapshot: snapshot,
                currentTime: $player.playPosition,
                onOpenFullTranscript: { onOpenFullTranscript(true) },
                reservesBottomTrailingAccessory: true
            )
            .onAppear { presenter.noteContentVisible() }
        case .preparing:
            statusView {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading transcript…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case .status(.liveStarting):
            statusView {
                Label("Transcribing as you listen", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
            }
            .onAppear { presenter.noteContentVisible() }
        case .status(.noTranscript):
            statusView {
                VStack(alignment: .leading, spacing: 4) {
                    Label("No Transcript", systemImage: "quote.bubble")
                        .font(.subheadline.weight(.semibold))
                    Text("Open the full transcript to create one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .onAppear { presenter.noteContentVisible() }
        }
    }

    private func statusView<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            // Keep the text clear of the bottom-right Open full transcript button.
            .padding(.trailing, 44)
    }

    private var openFullTranscriptButton: some View {
        Button {
            onOpenFullTranscript(false)
        } label: {
            Image("custom.quote.bubble.rectangle.portrait")
        }
        .buttonStyle(.glass(.clear))
        .frame(width: 44, height: 44)
        .padding(6)
        .accessibilityLabel("Open full transcript")
        .accessibilityHint("Opens the full transcript in a sheet")
        .help("Read the whole episode as text")
        .accessibilityInputLabels([Text("Open captions"), Text("Open transcript")])
    }
}

// MARK: - Overlay state

enum InlineTranscriptStatus: Equatable, Sendable {
    /// No stored transcript and no saved or running live transcription.
    case noTranscript
    /// Live recognition is running for this episode but has no cue yet.
    case liveStarting
}

/// The only value the overlay host observes. Captions are prepared values;
/// no SwiftData transcript model is read to paint the overlay.
enum InlineTranscriptState: Equatable, Sendable {
    case preparing
    case caption(InlineCaptionSnapshot)
    case status(InlineTranscriptStatus)

    /// Derives the overlay state from the chosen content source.
    ///
    /// - Parameters:
    ///   - kind: The content source, or nil when there is none.
    ///   - usesPublisherAlignment: Prepared-snapshot provenance; only meaningful
    ///     for a stored document.
    static func make(
        kind: InlineCaptionSnapshot.Kind?,
        episodeURL: URL,
        revision: Int,
        accumulator: InlineSegmentAccumulator,
        usesPublisherAlignment: Bool
    ) -> Self {
        guard let kind else { return .status(.noTranscript) }
        guard !accumulator.segments.isEmpty else {
            return .status(kind == .live ? .liveStarting : .noTranscript)
        }
        return .caption(InlineCaptionSnapshot(
            episodeURL: episodeURL,
            kind: kind,
            revision: revision,
            segments: accumulator.segments,
            speakers: accumulator.speakers,
            usesPublisherAlignment: kind == .document && usesPublisherAlignment,
            // A saved partial transcript is readable but cannot follow audio
            // that has not been analyzed yet.
            canFollowPlayback: kind != .savedPartial
        ))
    }
}

// MARK: - Presenter

/// Loads and incrementally updates the inline overlay's caption state.
///
/// Priority matches the previous `displayLines(for:)` contract: a stored
/// transcript (cached ``TranscriptPreparedSnapshot``) wins, then running live
/// recognition (value cues straight from ``LiveTranscriptController``), then a
/// saved partial live transcript (decoded on a model actor).
@MainActor
@Observable
final class InlineTranscriptPresenter {
    private(set) var state: InlineTranscriptState = .preparing

    @ObservationIgnored private let live: LiveTranscriptController
    @ObservationIgnored private var episodeURL: URL?
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var kind: InlineCaptionSnapshot.Kind?
    @ObservationIgnored private var accumulator = InlineSegmentAccumulator()
    @ObservationIgnored private var publisherAlignment = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var contentSignpost: OSSignpostID?

    init(live: LiveTranscriptController = .shared) {
        self.live = live
    }

    /// Phase A is the caller's frame: state is `.preparing` and nothing else
    /// runs synchronously. Phase B (loading) starts after a yield.
    func show(episodeURL: URL?, container: ModelContainer) {
        stop()
        self.episodeURL = episodeURL
        self.container = container
        guard episodeURL != nil else {
            state = .status(.noTranscript)
            return
        }
        state = .preparing
        let signpost = OSSignpostID(log: PlayerOpeningPerformance.log)
        contentSignpost = signpost
        os_signpost(.begin, log: PlayerOpeningPerformance.log, name: "Transcript overlay content", signpostID: signpost)
        observeLive(session: session)
        reload(after: nil)
    }

    func stop() {
        session += 1
        loadTask?.cancel()
        loadTask = nil
        kind = nil
        hasLoaded = false
        accumulator = InlineSegmentAccumulator()
        publisherAlignment = false
        episodeURL = nil
        if let contentSignpost {
            os_signpost(.end, log: PlayerOpeningPerformance.log, name: "Transcript overlay content",
                        signpostID: contentSignpost, "outcome=%{public}s", "hidden")
            self.contentSignpost = nil
        }
    }

    /// Ends the show → first caption/status interval once SwiftUI mounted it.
    func noteContentVisible() {
        guard let contentSignpost else { return }
        self.contentSignpost = nil
        let outcome: String
        let segments: Int
        switch state {
        case .caption(let snapshot):
            switch snapshot.kind {
            case .document: outcome = snapshot.usesPublisherAlignment ? "publisher" : "document"
            case .live: outcome = "live"
            case .savedPartial: outcome = "partial"
            }
            segments = snapshot.segments.count
        case .status(.liveStarting): outcome = "liveStarting"; segments = 0
        case .status(.noTranscript): outcome = "missing"; segments = 0
        case .preparing: outcome = "preparing"; segments = 0
        }
        let bucket = segments == 0 ? "0" : segments < 100 ? "<100" : segments < 1000 ? "<1000" : ">=1000"
        os_signpost(.end, log: PlayerOpeningPerformance.log, name: "Transcript overlay content",
                    signpostID: contentSignpost, "outcome=%{public}s segments=%{public}s", outcome, bucket)
    }

    /// A stored transcript may have been added or replaced. Live captions are
    /// already in memory, and periodic live saves also post this notification.
    func referencesChanged(episodeURL changedURL: URL?) {
        guard let episodeURL, hasLoaded, kind != .live else { return }
        guard changedURL == nil || changedURL == episodeURL else { return }
        // Debounced so the player's own cache invalidation for the same
        // notification runs first and bursts of reference updates coalesce.
        reload(after: .milliseconds(500))
    }

    // MARK: Loading

    private func reload(after delay: Duration?) {
        loadTask?.cancel()
        let session = session
        loadTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
            } else {
                // Let the overlay surface commit before any transcript work.
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            await self?.load(session: session)
        }
    }

    private func load(session: Int) async {
        guard session == self.session, let episodeURL, let container else { return }

        if let sources = live.liveCaptionSources(episodeURL: episodeURL) {
            applyLive(sources)
            return
        }

        let previousDocument = kind == .document ? accumulator : nil
        let document = await Self.prepareDocument(
            episodeURL: episodeURL, container: container, previous: previousDocument
        )
        guard !Task.isCancelled, session == self.session else { return }
        if let document {
            let isNewKind = kind != .document
            kind = .document
            accumulator = document.accumulator
            publisherAlignment = document.usesPublisherAlignment
            if isNewKind || document.changed || !hasLoaded { publish() }
            return
        }

        if let sources = live.liveCaptionSources(episodeURL: episodeURL) {
            applyLive(sources)
            return
        }

        let previousPartial = kind == .live || kind == .savedPartial ? accumulator : nil
        let partial = await Self.preparePartial(
            episodeURL: episodeURL,
            container: container,
            pending: live.pendingCues(episodeURL: episodeURL),
            previous: previousPartial
        )
        guard !Task.isCancelled, session == self.session else { return }
        // Live recognition may have started while the saved state loaded.
        if let sources = live.liveCaptionSources(episodeURL: episodeURL) {
            applyLive(sources)
            return
        }
        if let partial, !partial.segments.isEmpty {
            kind = .savedPartial
            accumulator = partial
        } else {
            kind = nil
            accumulator = InlineSegmentAccumulator()
        }
        publisherAlignment = false
        publish()
    }

    private struct PreparedDocument: Sendable {
        let accumulator: InlineSegmentAccumulator
        let changed: Bool
        let usesPublisherAlignment: Bool
    }

    /// Reuses the player's cached prepared snapshot (#484/#487) and groups the
    /// compact segments off the main actor.
    nonisolated private static func prepareDocument(
        episodeURL: URL,
        container: ModelContainer,
        previous: InlineSegmentAccumulator?
    ) async -> PreparedDocument? {
        await Task.detached(priority: .userInitiated) {
            let worker = PlayerTranscriptModelActor(modelContainer: container)
            guard let snapshot = try? await worker.preparedSnapshot(for: episodeURL),
                  let lines = snapshot.presentation.document?.lines, !lines.isEmpty else { return nil }
            var accumulator = previous ?? InlineSegmentAccumulator()
            let update = accumulator.update(with: lines)
            return PreparedDocument(
                accumulator: accumulator,
                changed: update.changed,
                usesPublisherAlignment: snapshot.sourceMetadata.usesPublisherAlignment
            )
        }.value
    }

    nonisolated private static func preparePartial(
        episodeURL: URL,
        container: ModelContainer,
        pending: [LiveTranscriptState.Cue],
        previous: InlineSegmentAccumulator?
    ) async -> InlineSegmentAccumulator? {
        await Task.detached(priority: .userInitiated) {
            let store = LiveTranscriptStoreActor(modelContainer: container)
            let sources = await store.partialSources(episodeURL: episodeURL, pending: pending)
            guard !sources.isEmpty else { return nil }
            var accumulator = previous ?? InlineSegmentAccumulator()
            accumulator.update(with: sources)
            return accumulator
        }.value
    }

    // MARK: Live

    private func observeLive(session: Int) {
        withObservationTracking {
            _ = live.phase
            _ = live.episodeURL
            _ = live.cues
            _ = live.tentativeCues
        } onChange: { [weak self] in
            // Fires before the mutation lands; read the new values next turn.
            // Several cue changes in one turn coalesce into one update.
            Task { @MainActor [weak self] in self?.liveDidChange(session: session) }
        }
    }

    private func liveDidChange(session: Int) {
        guard session == self.session, let episodeURL else { return }
        observeLive(session: session)
        guard hasLoaded || kind == .live else {
            // The initial load is still running and re-checks live state itself,
            // unless recognition already started for this episode.
            if let sources = live.liveCaptionSources(episodeURL: episodeURL) { applyLive(sources) }
            return
        }
        switch kind {
        case .document:
            // A stored transcript wins; live recognition stops itself once one exists.
            return
        case .live:
            if let sources = live.liveCaptionSources(episodeURL: episodeURL) {
                applyLive(sources)
            } else {
                // Recognition stopped: show the saved partial transcript or a
                // stored transcript that replaced it.
                reload(after: nil)
            }
        case .savedPartial, nil:
            if let sources = live.liveCaptionSources(episodeURL: episodeURL) { applyLive(sources) }
        }
    }

    /// Regroups only the changed trailing sources (see ``InlineSegmentAccumulator``).
    private func applyLive(_ sources: [TranscriptSegmentSource]) {
        let wasLive = kind == .live && hasLoaded
        if kind != .live && kind != .savedPartial { accumulator = InlineSegmentAccumulator() }
        kind = .live
        publisherAlignment = false
        let update = accumulator.update(with: sources)
        if update.changed || !wasLive { publish() }
    }

    private func publish() {
        guard let episodeURL else { return }
        hasLoaded = true
        revision += 1
        state = InlineTranscriptState.make(
            kind: kind,
            episodeURL: episodeURL,
            revision: revision,
            accumulator: accumulator,
            usesPublisherAlignment: publisherAlignment
        )
    }
}
