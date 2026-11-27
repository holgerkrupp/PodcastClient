import SwiftUI
import SwiftData

struct TranscriptSearchNavigation: Hashable, Sendable {
    let episodeID: String
    let timestamp: TimeInterval
    let query: String
}

private struct TranscriptDisplayRow: Identifiable, Sendable {
    let segment: TranscriptSegment
    let id: UUID
    let speaker: String?
    let showsSpeaker: Bool
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
}

struct TranscriptListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Bindable private var synchronizationStore = TranscriptSynchronizationStore.shared
    let preparedSnapshot: TranscriptPreparedSnapshot
    /// Captured once with the transcript snapshot; row rendering must not scan
    /// SwiftData models for transcript-global metadata.
    let usesPublisherAlignment: Bool
    let episode: Episode?
    let searchNavigation: TranscriptSearchNavigation?
    let canFollowPlayback: Bool

    @Bindable private var player = Player.shared
    @State private var searchText: String
    @State private var followPlayback: Bool
    @State private var displayRows: [TranscriptDisplayRow]
    @State private var speakerColorMap: [String: Color]
    @State private var isPreparingRows: Bool
    @State private var selectedSearchRowID: UUID?
    @State private var tracker = TranscriptPlaybackTracker()
    @State private var passageSelectionMode = false
    @State private var selectionActive = false
    @State private var frozenActive: TranscriptPlaybackTracker.Active?
    @State private var pendingRowsUpdate = false
    @State private var timingUpgrade = PublisherTimingUpgradeLoader()

    init(
        preparedSnapshot: TranscriptPreparedSnapshot,
        episode: Episode? = nil,
        searchText: String = "",
        startFollowingPlayback: Bool = false,
        searchNavigation: TranscriptSearchNavigation? = nil,
        canFollowPlayback: Bool = true
    ) {
        let initialSearchText = searchNavigation?.query.isEmpty == false
            ? searchNavigation!.query
            : searchText
        self.preparedSnapshot = preparedSnapshot
        self.usesPublisherAlignment = preparedSnapshot.sourceMetadata.usesPublisherAlignment
        self.episode = episode
        self.searchNavigation = searchNavigation
        self.canFollowPlayback = canFollowPlayback && preparedSnapshot.presentation.timingQuality != .unavailable
        _searchText = State(initialValue: initialSearchText)
        _followPlayback = State(initialValue: startFollowingPlayback)
        _displayRows = State(initialValue: [])
        _speakerColorMap = State(initialValue: [:])
        _isPreparingRows = State(initialValue: true)
    }

    init(
        transcriptLines: [TranscriptLineAndTime],
        episode: Episode? = nil,
        searchText: String = "",
        startFollowingPlayback: Bool = false,
        searchNavigation: TranscriptSearchNavigation? = nil,
        canFollowPlayback: Bool = true
    ) {
        let sources = transcriptLines.map {
            TranscriptSegmentSource(
                id: $0.id,
                speaker: $0.speaker,
                text: $0.text,
                startTime: $0.startTime,
                endTime: $0.endTime,
                sourceRawValue: $0.sourceRawValue,
                timedSpans: $0.timedSpans
            )
        }
        self.init(
            preparedSnapshot: TranscriptPreparedSnapshot.make(from: sources),
            episode: episode,
            searchText: searchText,
            startFollowingPlayback: startFollowingPlayback,
            searchNavigation: searchNavigation,
            canFollowPlayback: canFollowPlayback
        )
    }

    private static let speakerColors: [Color] = [
        .blue,
        .green,
        .orange,
        .purple,
        .red,
        .teal
    ]

    private var viewedEpisode: Episode? {
        episode
    }

    private var viewedEpisodeURL: URL? {
        viewedEpisode?.url
    }

    private var isShowingCurrentEpisode: Bool {
        guard canFollowPlayback, let viewedEpisodeURL else { return false }
        return player.currentEpisodeURL == viewedEpisodeURL
    }

    private var activeDisplayRowID: UUID? {
        (selectionActive ? frozenActive : tracker.active)?.segmentID
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search transcript…", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    passageSelectionMode.toggle()
                    if passageSelectionMode {
                        frozenActive = tracker.active
                        selectionActive = true
                        followPlayback = false
                    } else {
                        selectionActive = false
                        if pendingRowsUpdate {
                            pendingRowsUpdate = false
                            rebuildDisplayRows()
                        }
                    }
                } label: {
                    Label(passageSelectionMode ? "Done Copying" : "Select Passage", systemImage: "text.cursor")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass(.clear))
                .accessibilityHint("Select and copy words across multiple transcript lines without changing playback")

                if (isShowingCurrentEpisode || selectionActive) && !passageSelectionMode {
                    Button {
                        let wasSelecting = selectionActive
                        selectionActive = false
                        if pendingRowsUpdate {
                            pendingRowsUpdate = false
                            rebuildDisplayRows()
                        }
                        if isShowingCurrentEpisode {
                            followPlayback = wasSelecting ? true : !followPlayback
                        }
                    } label: {
                        Label(selectionActive && !isShowingCurrentEpisode ? "Done Selecting" : (followPlayback ? "Following" : "Follow"), systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(followPlayback ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.glass(.clear))
                    .help(followPlayback ? "Stop following playback" : "Keep the current transcript line centered")
                    .accessibilityLabel(selectionActive && !isShowingCurrentEpisode ? "Done selecting" : (followPlayback ? "Following playback" : "Follow playback"))
                    .accessibilityHint(isShowingCurrentEpisode ? "Keeps captions centered around the current playback time" : "Resumes transcript updates")
                    .accessibilityInputLabels([Text("Follow captions"), Text("Follow playback")])
                }
            }
            .padding()

            ScrollViewReader { proxy in
                ScrollView {
                    if passageSelectionMode {
                        Text(displayRows.map(\.text).joined(separator: "\n"))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else if isPreparingRows {
                        ProgressView("Loading transcript…")
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if displayRows.isEmpty {
                        ContentUnavailableView("No Matching Transcript", systemImage: "magnifyingglass")
                            .padding(.top, 60)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(displayRows) { row in
                                transcriptRow(row)
                                    .id(row.id)
                                    .padding(.horizontal)
                            }
                        }
                        .padding(.bottom)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            guard followPlayback else { return }
                            followPlayback = false
                        }
                )
                .onAppear {
                    if canFollowPlayback {
                        tracker.start(segments: displayRows.map(\.segment), episodeURL: viewedEpisodeURL, useAlignment: usesPublisherAlignment)
                        tracker.updateEnhancedWords(timingUpgrade.words.words)
                    }
                    scrollToInitialLocation(with: proxy)
                    configureTimingUpgrade()
                }
                .task(id: preparedSnapshot) {
                    await prepareDisplayRows()
                }
        .onAppear {
            PlayerOpeningPerformance.event("Transcript surface visible")
        }
        .publisherTimingDemand(episodeURL: usesPublisherAlignment ? viewedEpisodeURL : nil)
                .onDisappear {
                    tracker.stop()
                    timingUpgrade.configure(nil, playhead: 0)
                }
                .onChange(of: player.playPosition) {
                    tracker.refresh()
                    timingUpgrade.playheadMoved(to: player.playPosition)
                }
                .onChange(of: player.currentEpisodeURL) {
                    tracker.refresh()
                    configureTimingUpgrade()
                }
                .onChange(of: canFollowPlayback) {
                    if canFollowPlayback {
                        tracker.start(segments: displayRows.map(\.segment), episodeURL: viewedEpisodeURL, useAlignment: usesPublisherAlignment)
                    } else { tracker.stop() }
                    configureTimingUpgrade()
                }
                // Verified word timing upgrades only the highlight: rows,
                // scroll position, search, selection and Follow stay as they are.
                .onChange(of: timingUpgrade.words) {
                    tracker.updateEnhancedWords(timingUpgrade.words.words)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: .publisherTranscriptTimingDidChange)
                        .receive(on: DispatchQueue.main)
                ) { notification in
                    timingUpgrade.timingDidChange(
                        episodeURL: notification.userInfo?[PublisherTimingEvidenceLoader.episodeURLKey] as? URL
                    )
                }
                .onChange(of: searchText) {
                    if selectionActive { pendingRowsUpdate = true } else { rebuildDisplayRows() }
                }
                .onChange(of: preparedSnapshot) { oldSnapshot, newSnapshot in
                    if selectionActive {
                        pendingRowsUpdate = true
                    } else if !newSnapshot.continuesDocumentLayout(of: oldSnapshot) {
                        isPreparingRows = true
                    }
                    // Timing-only upgrades and appended or revised live cues keep
                    // the rows on screen; the task below swaps in the new rows
                    // without a loading state, scroll reset or Follow recenter
                    // (#487).
                    configureTimingUpgrade()
                }
                .onChange(of: isPreparingRows) {
                    guard isPreparingRows == false else { return }
                    scrollToInitialLocation(with: proxy)
                }
                .onChange(of: activeDisplayRowID) {
                    scrollToActiveRow(with: proxy, animated: false)
                }
                .onChange(of: followPlayback) {
                    scrollToActiveRow(with: proxy, animated: true)
                }
                .onChange(of: selectedSearchRowID) {
                    guard let selectedSearchRowID else { return }
                    proxy.scrollTo(selectedSearchRowID, anchor: .center)
                }
            }
        }
        .toolbar {
            if searchText.isEmpty == false, displayRows.isEmpty == false {
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button {
                        moveSearchMatch(by: -1)
                    } label: {
                        Label("Previous match", systemImage: "chevron.up")
                    }
                    .accessibilityLabel("Previous transcript match")

                    Button {
                        moveSearchMatch(by: 1)
                    } label: {
                        Label("Next match", systemImage: "chevron.down")
                    }
                    .accessibilityLabel("Next transcript match")
                }
            }
        }
    }

    private func transcriptRow(_ row: TranscriptDisplayRow) -> some View {
        let isActive = row.id == activeDisplayRowID
        let isFocusedSearchMatch = row.id == selectedSearchRowID
        let canSeek = !usesPublisherAlignment || !synchronizationStore.isActive
            || synchronizationStore.audioTime(forTranscriptTime: row.startTime, episodeURL: viewedEpisodeURL) != nil
        let caption = row.segment.highlightedText(selectionActive ? frozenActive : tracker.active)
        let displayedCaption = !searchText.isEmpty && TranscriptSearchText.matches(row.text, query: searchText)
            ? caption.underline() : caption

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    Task {
                        await playTranscript(at: row.startTime)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: playbackIcon(isActive: isActive))
                            .font(.caption2.weight(.bold))
                        Text(formatTime(row.startTime))
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canFollowPlayback || !canSeek)
                .accessibilityLabel("Play from \(formatTime(row.startTime))")
                .accessibilityHint(canFollowPlayback && canSeek ? "Starts playback from this passage" : "Playback is unavailable for this passage")
                .accessibilityInputLabels([Text("Play from \(formatTime(row.startTime))"), Text("Play caption")])

                if row.showsSpeaker, let speaker = row.speaker {
                    Text("\(speaker):")
                        .font(.headline)
                        .foregroundColor(differentiateWithoutColor ? .primary : (speakerColorMap[speaker] ?? .accent))
                }

                if isActive && differentiateWithoutColor {
                    Label("Current", systemImage: "speaker.wave.2.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

#if canImport(UIKit)
            SelectableTranscriptText(
                segment: row.segment,
                active: selectionActive ? frozenActive : tracker.active,
                underlineForSearch: !searchText.isEmpty && TranscriptSearchText.matches(row.text, query: searchText),
                onSelectionChange: { selecting in
                    if selecting && !selectionActive {
                        frozenActive = tracker.active
                        selectionActive = true
                        followPlayback = false
                    } else if !selecting && selectionActive {
                        selectionActive = false
                        if pendingRowsUpdate {
                            pendingRowsUpdate = false
                            rebuildDisplayRows()
                        }
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
#else
            displayedCaption
                .font(.body)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.25).onEnded { _ in
                    frozenActive = tracker.active
                    selectionActive = true
                    followPlayback = false
                })
#endif
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(differentiateWithoutColor ? 0.08 : 0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isActive
                        ? Color.accentColor.opacity(differentiateWithoutColor ? 0.8 : 0.45)
                        : isFocusedSearchMatch
                            ? Color.accentColor.opacity(0.75)
                        : Color.secondary.opacity(differentiateWithoutColor ? 0.35 : 0.15),
                    lineWidth: (differentiateWithoutColor && isActive) || isFocusedSearchMatch ? 2 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Caption \(formatTime(row.startTime))")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityValue(row.speaker == nil ? row.text : "\(row.speaker!), \(row.text)")
    }

    private func playbackIcon(isActive: Bool) -> String {
        if isActive && player.isPlaying && isShowingCurrentEpisode {
            return "speaker.wave.2.fill"
        }
        return "play.fill"
    }

    private func scrollToActiveRow(with proxy: ScrollViewProxy, animated: Bool = true) {
        guard followPlayback, !selectionActive, let activeDisplayRowID else { return }

        if animated && !reduceMotion {
            withAnimation(.snappy(duration: 0.18, extraBounce: 0.0)) {
                proxy.scrollTo(activeDisplayRowID, anchor: .center)
            }
        } else {
            proxy.scrollTo(activeDisplayRowID, anchor: .center)
        }
    }

    private func scrollToInitialLocation(with proxy: ScrollViewProxy) {
        if let searchNavigation,
           let row = displayRows.first(where: { row in
               row.startTime <= searchNavigation.timestamp
                   && (row.endTime ?? .greatestFiniteMagnitude) > searchNavigation.timestamp
           }) ?? displayRows.min(by: {
               abs($0.startTime - searchNavigation.timestamp) < abs($1.startTime - searchNavigation.timestamp)
           }) {
            proxy.scrollTo(row.id, anchor: .center)
            return
        }
        scrollToActiveRow(with: proxy, animated: false)
    }

    @MainActor
    private func playTranscript(at time: TimeInterval) async {
        guard let audioTime = (usesPublisherAlignment ? synchronizationStore.audioTime(
            forTranscriptTime: time,
            episodeURL: viewedEpisodeURL
        ) : time) else { return }
        guard let viewedEpisodeURL else {
            await player.jumpTo(time: audioTime)
            if player.isPlaying == false {
                player.play()
            }
            return
        }

        if player.currentEpisodeURL == viewedEpisodeURL {
            await player.jumpTo(time: audioTime)
            if player.isPlaying == false {
                player.play()
            }
        } else {
            await player.playEpisode(viewedEpisodeURL, playDirectly: true, startingAt: audioTime)
        }
    }

    /// Publisher transcripts of the episode playing from a downloaded file get
    /// verified word timing; anything else keeps its existing cue timing.
    private func configureTimingUpgrade() {
        guard canFollowPlayback, isShowingCurrentEpisode, let viewedEpisode,
              let document = preparedSnapshot.presentation.document, document.source == .publisher else {
            timingUpgrade.configure(nil, playhead: player.playPosition)
            return
        }
        timingUpgrade.configure(PublisherTimingUpgradeLoader.Source.make(
            episodeURL: viewedEpisodeURL,
            episodeID: viewedEpisode.stableEpisodeIdentity.key,
            localMediaURL: viewedEpisode.localFile,
            document: document,
            options: .full
        ), playhead: player.playPosition)
    }

    private func formatTime(_ timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func rebuildDisplayRows() {
        let rows = Self.makeDisplayRows(from: preparedSnapshot.segments, matching: searchText)
        displayRows = rows
        isPreparingRows = false
        tracker.update(segments: rows.map(\.segment), episodeURL: viewedEpisodeURL, useAlignment: usesPublisherAlignment)
        speakerColorMap = Self.makeSpeakerColorMap(from: rows)
        if let selectedSearchRowID, !rows.contains(where: { $0.id == selectedSearchRowID }) {
            self.selectedSearchRowID = nil
        }
    }

    private func prepareDisplayRows() async {
        let segments = preparedSnapshot.segments
        let query = searchText
        let rows = await Task.detached(priority: .userInitiated) {
            Self.makeDisplayRows(from: segments, matching: query)
        }.value
        guard Task.isCancelled == false else { return }
        if selectionActive {
            pendingRowsUpdate = true
            return
        }
        guard query == searchText else { return }
        displayRows = rows
        speakerColorMap = Self.makeSpeakerColorMap(from: rows)
        isPreparingRows = false
        if rows.isEmpty == false {
            PlayerOpeningPerformance.event("Transcript first row ready")
        }
        tracker.update(segments: rows.map(\.segment), episodeURL: viewedEpisodeURL, useAlignment: usesPublisherAlignment)
    }

    private func moveSearchMatch(by offset: Int) {
        guard displayRows.isEmpty == false else { return }
        let currentIndex = selectedSearchRowID.flatMap { id in
            displayRows.firstIndex { $0.id == id }
        } ?? (offset > 0 ? -1 : displayRows.count)
        let nextIndex = (currentIndex + offset + displayRows.count) % displayRows.count
        selectedSearchRowID = displayRows[nextIndex].id
    }

    nonisolated private static func makeDisplayRows(from segments: [TranscriptSegment], matching searchText: String) -> [TranscriptDisplayRow] {
        let filteredSegments: [TranscriptSegment]
        if searchText.isEmpty {
            filteredSegments = segments
        } else {
            filteredSegments = segments.filter { segment in
                TranscriptSearchText.matches(segment.text, query: searchText) ||
                (segment.speaker.map { TranscriptSearchText.matches($0, query: searchText) } ?? false)
            }
        }

        var rows: [TranscriptDisplayRow] = []
        rows.reserveCapacity(filteredSegments.count)

        var previousSpeaker: String?
        for segment in filteredSegments {
            rows.append(
                TranscriptDisplayRow(
                    segment: segment,
                    id: segment.id,
                    speaker: segment.speaker,
                    showsSpeaker: segment.speaker != previousSpeaker,
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
            )

            previousSpeaker = segment.speaker
        }

        return rows
    }

    private static func makeSpeakerColorMap(from rows: [TranscriptDisplayRow]) -> [String: Color] {
        var colorMap: [String: Color] = [:]
        let speakers = Array(Set(rows.compactMap(\.speaker))).sorted(by: <)

        for (index, speaker) in speakers.enumerated() {
            colorMap[speaker] = speakerColors[index % speakerColors.count]
        }

        return colorMap
    }

}

/// Loads and presents transcript values progressively so switching the player
/// to Transcript can render a useful state before SwiftData or segmentation
/// work completes.
struct TranscriptPane: View {
    @Environment(\.modelContext) private var modelContext

    let episode: Episode
    let availability: PlayerContentAvailability?
    let startFollowingPlayback: Bool

    private enum Content {
        case loading, failed, missing
        case document(TranscriptPreparedSnapshot)
    }

    @State private var content: Content = .loading
    @State private var loadedEpisodeURL: URL?
    @State private var retryCount = 0

    private struct LoadID: Equatable {
        let episodeURL: URL?
        let refresh: Bool
        let availability: PlayerContentAvailability?
        let retryCount: Int
    }

    private var loadID: LoadID {
        LoadID(
            episodeURL: episode.url,
            refresh: episode.refresh,
            availability: availability,
            retryCount: retryCount
        )
    }

    var body: some View {
        Group {
            switch content {
            case .document(let snapshot):
                TranscriptListView(
                    preparedSnapshot: snapshot,
                    episode: episode,
                    startFollowingPlayback: startFollowingPlayback
                )
            case .loading:
                ProgressView("Loading transcript…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .accessibilityLabel("Loading transcript")
            case .failed:
                ContentUnavailableView {
                    Label("Transcript Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("The transcript could not be loaded. Playback remains available.")
                } actions: {
                    Button("Retry") { retryCount += 1 }
                }
            case .missing:
                PartialTranscriptPane(episode: episode, startFollowingPlayback: startFollowingPlayback)
                    .id(episode.url)
            }
        }
        .task(id: loadID) {
            await loadTranscript()
        }
    }

    @MainActor
    private func loadTranscript() async {
        // `episode.refresh` also toggles for unrelated or timing-only changes
        // (for example transcript gap chapters after a verified alignment).
        // Keep the shown document mounted while re-checking the same episode so
        // the list keeps its scroll position, search and Follow state (#487).
        let keepsShownDocument: Bool
        if case .document = content, loadedEpisodeURL == episode.url {
            keepsShownDocument = true
        } else {
            keepsShownDocument = false
            content = .loading
        }
        guard let episodeURL = episode.url else {
            content = .failed
            return
        }

        do {
            let worker = PlayerTranscriptModelActor(modelContainer: modelContext.container)
            let snapshot = try await worker.preparedSnapshot(for: episodeURL)
            guard !Task.isCancelled else { return }
            loadedEpisodeURL = episodeURL
            if let snapshot, !snapshot.segments.isEmpty {
                content = .document(snapshot)
            } else {
                content = .missing
            }
        } catch is CancellationError {
            return
        } catch {
            guard Task.isCancelled == false else { return }
            // A failed re-check must not remove a transcript that is already readable.
            if !keepsShownDocument { content = .failed }
        }
    }

}

/// Only mounted after the stored transcript lookup confirms there is no document.
private struct PartialTranscriptPane: View {
    let episode: Episode
    let startFollowingPlayback: Bool
    @Environment(\.modelContext) private var modelContext
    @Bindable private var liveTranscript = LiveTranscriptController.shared
    @State private var partial: TranscriptPreparedSnapshot?
    @State private var preparation = Preparation()

    /// Main-actor bookkeeping for incremental preparation. Mutations must not
    /// re-render, so this is a plain reference held in `@State`.
    @MainActor
    private final class Preparation {
        var generation = TranscriptPreparationGeneration()
        var accumulator = PartialTranscriptSnapshotAccumulator()
        /// The single preparation allowed to run; later runs start from its result.
        var inFlight: Task<PartialTranscriptSnapshotAccumulator, Never>?
    }

    /// Reloads when a live cue is finalized, when the tentative cues are revised
    /// (same count included) and when recognition starts or stops. Cheap: it
    /// hashes only the last finalized cue and the few tentative cues.
    private struct LoadKey: Equatable {
        let isLive: Bool
        let cueCount: Int
        let revision: Int
    }

    private var loadKey: LoadKey {
        var hasher = Hasher()
        hasher.combine(liveTranscript.cues.last)
        hasher.combine(liveTranscript.tentativeCues)
        return LoadKey(
            isLive: liveTranscript.isActive(for: episode),
            cueCount: liveTranscript.cues.count,
            revision: hasher.finalize()
        )
    }

    var body: some View {
        Group {
            if let partial, !partial.segments.isEmpty {
                VStack(spacing: 12) {
                    TranscriptGenerationActionsView(episode: episode)
                    LiveTranscriptCoverageView(episode: episode)
                    TranscriptListView(
                        preparedSnapshot: partial,
                        episode: episode,
                        startFollowingPlayback: startFollowingPlayback,
                        canFollowPlayback: liveTranscript.isActive(for: episode)
                    )
                }
            } else {
                TranscriptEmptyStateView(episode: episode)
            }
        }
        .task(id: loadKey) {
            await loadPartial()
        }
    }

    @MainActor
    private func loadPartial() async {
        guard let episodeURL = episode.url else { return }
        let token = preparation.generation.begin()
        // Wait for the running preparation instead of starting a second one;
        // superseded runs drop out here without doing any work.
        let base = await preparation.inFlight?.value ?? preparation.accumulator
        guard !Task.isCancelled, preparation.generation.isCurrent(token) else { return }

        // Same sources as the inline overlay (#484/#520): running recognition
        // hands over value cues merged in linear time, and a saved partial
        // transcript is decoded on a model actor. Nothing here reads
        // `liveTranscriptData` or decodes JSON on the main actor.
        let sources: [TranscriptSegmentSource]
        if let live = liveTranscript.liveCaptionSources(episodeURL: episodeURL) {
            sources = live
        } else {
            let store = LiveTranscriptStoreActor(modelContainer: modelContext.container)
            sources = await store.partialSources(
                episodeURL: episodeURL,
                pending: liveTranscript.pendingCues(episodeURL: episodeURL)
            )
        }
        guard !Task.isCancelled, preparation.generation.isCurrent(token) else { return }

        let work = Task.detached(priority: .userInitiated) {
            var accumulator = base
            accumulator.update(with: sources)
            return accumulator
        }
        preparation.inFlight = work
        let updated = await work.value
        // Keep the newest regrouping as the base even if its result is stale;
        // the accumulator diffs against its own sources, so any base is valid.
        preparation.accumulator = updated
        if preparation.inFlight == work { preparation.inFlight = nil }
        guard !Task.isCancelled, preparation.generation.isCurrent(token),
              let snapshot = updated.snapshot else { return }
        partial = snapshot
    }
}

// MARK: - Verified publisher word timing (#492)

/// Loads verified publisher word timing for a window around the playhead and
/// publishes it as audio-clock spans keyed by displayed segment ID, so a
/// transcript surface can upgrade its highlighting in place. Only `words` is
/// observed; rows, segments and snapshots are never touched.
///
/// One load runs at a time. Requests that arrive while it runs coalesce into a
/// single follow-up load, and a result is dropped when the source changed
/// (other episode, transcript revision or media) since the load began.
@MainActor
@Observable
final class PublisherTimingUpgradeLoader {
    /// Everything a load needs, captured on the main actor.
    struct Source: Sendable, Equatable {
        let episodeURL: URL
        /// The stable identity the synchronization keys its cache with.
        let episodeID: String
        let localMediaURL: URL
        /// The canonical publisher document; its lines are in display order.
        let document: TranscriptDocumentSnapshot
        let options: TranscriptSegmentBuilder.Options

        /// Cheap: the timing revision already identifies the document lines.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.episodeURL == rhs.episodeURL && lhs.episodeID == rhs.episodeID
                && lhs.localMediaURL == rhs.localMediaURL && lhs.options == rhs.options
                && lhs.document.timingRevision == rhs.document.timingRevision
                && lhs.document.lines.count == rhs.document.lines.count
        }

        /// Nil unless `document` is a publisher transcript of `episodeURL` and the
        /// media is a downloaded file; other transcripts keep their cue timing.
        static func make(
            episodeURL: URL?,
            episodeID: String?,
            localMediaURL: URL?,
            document: TranscriptDocumentSnapshot?,
            options: TranscriptSegmentBuilder.Options
        ) -> Self? {
            guard let episodeURL, let episodeID, !episodeID.isEmpty,
                  let document, document.source == .publisher,
                  document.timingRevision?.isEmpty == false,
                  let localMediaURL, localMediaURL.isFileURL,
                  FileManager.default.fileExists(atPath: localMediaURL.path) else { return nil }
            return Self(episodeURL: episodeURL, episodeID: episodeID, localMediaURL: localMediaURL,
                        document: document, options: options)
        }
    }

    struct Token: Equatable, Sendable {
        let episodeURL: URL
        let generation: Int
    }

    typealias Load = @Sendable (Source, Range<TimeInterval>) async -> [UUID: [TranscriptTimedSpan]]?

    nonisolated static let lookBehind: TimeInterval = 30
    nonisolated static let lookAhead: TimeInterval = 150
    /// Reload this long before the playhead reaches the end of the loaded window.
    nonisolated static let reloadMargin: TimeInterval = 30

    private(set) var words = TranscriptEnhancedWords.empty

    @ObservationIgnored private(set) var source: Source?
    @ObservationIgnored private(set) var loadedWindow: Range<TimeInterval>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var pendingReload = false
    @ObservationIgnored private var latestPlayhead: TimeInterval = 0
    @ObservationIgnored private let load: Load

    init(load: @escaping Load = { await PublisherTimingUpgradeLoader.loadEvidence($0, window: $1) }) {
        self.load = load
    }

    nonisolated static func window(around playhead: TimeInterval) -> Range<TimeInterval> {
        let time = playhead.isFinite ? max(0, playhead) : 0
        return max(0, time - lookBehind)..<(time + lookAhead)
    }

    /// Whether the playhead left (or is about to leave) the loaded window.
    nonisolated static func needsReload(loadedWindow: Range<TimeInterval>?, playhead: TimeInterval) -> Bool {
        guard playhead.isFinite else { return false }
        guard let loadedWindow else { return true }
        let end = max(loadedWindow.lowerBound, loadedWindow.upperBound - reloadMargin)
        return playhead < loadedWindow.lowerBound || playhead > end
    }

    var currentToken: Token? {
        source.map { Token(episodeURL: $0.episodeURL, generation: generation) }
    }

    func isCurrent(_ token: Token) -> Bool { token == currentToken }

    /// Switches to `source` (nil stops). The same source is a no-op; a different
    /// one drops the running load and clears the published words.
    func configure(_ source: Source?, playhead: TimeInterval) {
        latestPlayhead = playhead
        guard source != self.source else { return }
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        pendingReload = false
        loadedWindow = nil
        self.source = source
        if !words.words.isEmpty { publish([:]) }
        if source != nil { startLoad(after: nil) }
    }

    /// Cheap enough for every playback tick.
    func playheadMoved(to playhead: TimeInterval) {
        latestPlayhead = playhead
        guard source != nil, inFlight == nil,
              Self.needsReload(loadedWindow: loadedWindow, playhead: playhead) else { return }
        startLoad(after: .milliseconds(250))
    }

    /// New mappings were cached for `episodeURL`; bursts coalesce into one load.
    func timingDidChange(episodeURL: URL?) {
        guard let source, episodeURL == nil || episodeURL == source.episodeURL else { return }
        startLoad(after: .milliseconds(500))
    }

    private func startLoad(after delay: Duration?) {
        guard let source, let token = currentToken else { return }
        guard inFlight == nil else {
            pendingReload = true
            return
        }
        let load = self.load
        inFlight = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
            } else {
                await Task.yield()
            }
            guard let self, !Task.isCancelled, self.isCurrent(token) else { return }
            let window = Self.window(around: self.latestPlayhead)
            // Recorded before the result so ticks do not start a second load.
            self.loadedWindow = window
            let result = await load(source, window)
            guard !Task.isCancelled else { return }
            self.receive(result, for: token)
        }
    }

    /// Applies a finished load. Results for a superseded source are dropped.
    func receive(_ result: [UUID: [TranscriptTimedSpan]]?, for token: Token) {
        guard isCurrent(token) else { return }
        inFlight = nil
        let newWords = result ?? [:]
        if newWords != words.words { publish(newWords) }
        if pendingReload || Self.needsReload(loadedWindow: loadedWindow, playhead: latestPlayhead) {
            pendingReload = false
            startLoad(after: .milliseconds(250))
        }
    }

    private func publish(_ newWords: [UUID: [TranscriptTimedSpan]]) {
        words = TranscriptEnhancedWords(revision: words.revision + 1, words: newWords)
    }

    /// Reads cached publisher timing and rebases it onto the source's segments, off the main actor.
    nonisolated static func loadEvidence(
        _ source: Source,
        window: Range<TimeInterval>
    ) async -> [UUID: [TranscriptTimedSpan]]? {
        let work = Task.detached(priority: .utility) { () -> [UUID: [TranscriptTimedSpan]]? in
            // Prepared snapshots carry no episode identity; resolve the same
            // lines under the identity the synchronization cache uses.
            let document = source.document.episodeID == source.episodeID
                ? source.document
                : TranscriptDocumentSnapshot.resolve(episodeID: source.episodeID,
                                                     storedLines: source.document.lines)
            guard let document, !Task.isCancelled,
                  let evidence = await PublisherTimingEvidenceLoader.load(
                    document: document, episodeURL: source.episodeURL,
                    localMediaURL: source.localMediaURL, audioWindow: window),
                  !Task.isCancelled else { return nil }
            return TranscriptSegmentBuilder.rebasedWords(
                lines: document.lines, wordsByLine: evidence.wordsByLine, options: source.options)
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

#Preview {
    let sampleTranscriptLines: [TranscriptLineAndTime] = [
        TranscriptLineAndTime(
            speaker: "Daniel",
            text: "Dave, how do you feel about cold opens? I don't care. I'm going to open coldly.",
            startTime: 9.0,
            endTime: 15.0
        ),
        TranscriptLineAndTime(
            speaker: "Dave",
            text: "I support this energy.",
            startTime: 16.0,
            endTime: 20.0
        )
    ]

    TranscriptListView(transcriptLines: sampleTranscriptLines)
}
